//! Whole-session deletion, fenced the way the Swift `SessionDeleter` is.
//!
//! This is the one place the crate removes anything, and it removes only a
//! session's own log files, only when a host asks for that session by name.
//! Every target is canonicalized and must resolve strictly below one of the
//! provider's roots under the given home; a target that is itself a symlink
//! is refused; and the session file is re-parsed immediately before removal
//! so a stale summary cannot delete a different session. Nothing here edits
//! the contents of a file, and nothing outside the provider roots is ever
//! touched.

use std::path::{Path, PathBuf};

use crate::discovery;
use crate::provider::SessionProvider;

/// What a host knows about the session it wants gone. `source_path` is the
/// file discovery or the index reported for it; `session_id` is the id that
/// file must still carry when re-parsed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionToDelete {
    pub provider: SessionProvider,
    pub session_id: String,
    pub source_path: PathBuf,
}

/// The paths one deletion removes, and the file whose re-parse must still
/// name the expected session before anything is removed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeletionPlan {
    pub provider: SessionProvider,
    pub paths_to_remove: Vec<PathBuf>,
    pub validation_source_path: PathBuf,
    pub expected_session_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DeleteError {
    #[error("this provider's sessions are read by another app and are never deleted here")]
    ProviderIsReadOnly,
    #[error("this implementation deletes only Codex and Claude Code sessions")]
    ProviderNotImplemented,
    #[error("the session's files do not resolve below one of the provider's roots")]
    PathEscapesProviderRoot,
    #[error("one of the session's files is a symbolic link")]
    SymlinkedTarget,
    #[error("the session file could not be read back before removal")]
    ValidationUnreadable,
    #[error("the session file no longer names the session that was asked for")]
    SessionIdMismatch,
    #[error("removing {0} failed")]
    RemovalFailed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeleteOutcome {
    Succeeded(SessionToDelete),
    Failed(SessionToDelete, DeleteError),
}

/// Whether this implementation knows how to delete the provider's sessions:
/// it has roots and a re-parse for Codex and Claude Code only. Grok and
/// Gemini are deletable in the Swift lane; here they are refused rather
/// than planned for and then failed.
pub fn implemented_here(provider: SessionProvider) -> bool {
    matches!(provider, SessionProvider::Codex | SessionProvider::Claude)
}

/// The provider roots deletion is fenced to, under `home`: the same
/// directories discovery reads, walked component by component with a
/// symlinked component refused — a link at `.codex` or `sessions` would
/// otherwise make somewhere outside the home an "authorized" root — and
/// then canonicalized so the fence and the targets compare on equal terms.
/// A root that does not exist is simply absent.
pub fn provider_roots(provider: SessionProvider, home: &Path) -> Vec<PathBuf> {
    let candidates: &[&[&str]] = match provider {
        SessionProvider::Codex => &[&[".codex", "sessions"], &[".codex", "archived_sessions"]],
        SessionProvider::Claude => &[&[".claude", "projects"], &[".config", "claude", "projects"]],
        _ => &[],
    };
    candidates
        .iter()
        .filter_map(|components| discovery::safe_root(home, components))
        .filter_map(|root| std::fs::canonicalize(root).ok())
        .collect()
}

/// What deleting this session removes. Codex: the rollout file. Claude: the
/// session file and, when present, the sidecar directory of the same stem
/// (sub-agent logs). Other providers are refused: their stores belong to
/// another app.
pub fn plan(session: &SessionToDelete) -> Result<DeletionPlan, DeleteError> {
    if !session.provider.supports_deletion() {
        return Err(DeleteError::ProviderIsReadOnly);
    }
    if !implemented_here(session.provider) {
        return Err(DeleteError::ProviderNotImplemented);
    }
    let mut paths = vec![session.source_path.clone()];
    if session.provider == SessionProvider::Claude {
        let sidecar = session.source_path.with_extension("");
        if std::fs::symlink_metadata(&sidecar).is_ok_and(|meta| meta.file_type().is_dir()) {
            paths.push(sidecar);
        }
    }
    Ok(DeletionPlan {
        provider: session.provider,
        paths_to_remove: paths,
        validation_source_path: session.source_path.clone(),
        expected_session_id: session.session_id.clone(),
    })
}

/// Delete each session, one at a time, reporting per session. A failure on
/// one never stops the others. The checks all run before the first
/// `remove`; a removal that fails part-way (a sidecar entry that cannot be
/// removed) leaves the session file itself in place, so a `Failed` outcome
/// still names a session that can be re-parsed and retried.
pub fn delete(home: &Path, sessions: &[SessionToDelete]) -> Vec<DeleteOutcome> {
    sessions
        .iter()
        .map(|session| match delete_one(home, session) {
            Ok(()) => DeleteOutcome::Succeeded(session.clone()),
            Err(error) => DeleteOutcome::Failed(session.clone(), error),
        })
        .collect()
}

fn delete_one(home: &Path, session: &SessionToDelete) -> Result<(), DeleteError> {
    let plan = plan(session)?;
    if plan.paths_to_remove.is_empty() {
        return Err(DeleteError::ValidationUnreadable);
    }
    let roots = provider_roots(session.provider, home);
    if roots.is_empty() {
        return Err(DeleteError::PathEscapesProviderRoot);
    }
    for target in plan
        .paths_to_remove
        .iter()
        .chain(std::iter::once(&plan.validation_source_path))
    {
        if is_symlink(target) {
            return Err(DeleteError::SymlinkedTarget);
        }
        if !is_contained(target, &roots) {
            return Err(DeleteError::PathEscapesProviderRoot);
        }
    }
    let reparsed = reparse_session_id(session.provider, &plan.validation_source_path)
        .ok_or(DeleteError::ValidationUnreadable)?;
    if !reparsed.eq_ignore_ascii_case(&plan.expected_session_id) {
        return Err(DeleteError::SessionIdMismatch);
    }
    // Sidecars first, the session file last: a failure part-way leaves the
    // file that names the session in place, so the outcome is honest and a
    // retry can still re-parse it.
    let mut ordered: Vec<&PathBuf> = plan.paths_to_remove.iter().collect();
    ordered.sort_by_key(|path| **path == plan.validation_source_path);
    for path in ordered {
        let Ok(meta) = std::fs::symlink_metadata(path) else {
            continue;
        };
        let result = if meta.file_type().is_dir() {
            remove_sidecar_without_following_links(path)
        } else {
            std::fs::remove_file(path)
        };
        if result.is_err() {
            let name = path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
            return Err(DeleteError::RemovalFailed(name));
        }
    }
    Ok(())
}

/// Strictly below one of `roots` after symlink resolution — the root itself
/// never qualifies, and a link pointing outside the provider's tree resolves
/// out of every root's prefix — and reached without passing through a
/// symlinked directory: every component between the root and the target is
/// checked with `symlink_metadata`, the way discovery walks the tree. A
/// link that resolves elsewhere inside the root would otherwise let
/// revalidation and removal follow a path discovery never took.
fn is_contained(path: &Path, roots: &[PathBuf]) -> bool {
    let Ok(resolved) = std::fs::canonicalize(path) else {
        return false;
    };
    let Some(root) = roots
        .iter()
        .find(|root| resolved != **root && resolved.starts_with(root))
    else {
        return false;
    };
    // The given path may be spelled through the un-canonicalized root; walk
    // the given spelling from its own prefix that maps onto the root.
    let Ok(relative) = resolved.strip_prefix(root) else {
        return false;
    };
    let mut cursor = root.clone();
    for component in relative.components() {
        cursor.push(component);
        match std::fs::symlink_metadata(&cursor) {
            Ok(meta) if !meta.file_type().is_symlink() => {}
            _ => return false,
        }
    }
    // And the path as given, component by component below the root's
    // spelling of it, so a link in the given spelling is refused too.
    let mut given = PathBuf::new();
    let mut below_root = false;
    for component in path.components() {
        given.push(component);
        if !below_root {
            if std::fs::canonicalize(&given).ok().as_deref() == Some(root.as_path()) {
                // The component that names the root must be the root itself,
                // not a link aliasing it: retargeting such a link between the
                // re-parse and the removal would move the target elsewhere.
                if is_symlink(&given) {
                    return false;
                }
                below_root = true;
            }
            continue;
        }
        if is_symlink(&given) {
            return false;
        }
    }
    true
}

fn is_symlink(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_symlink())
}

/// Remove a sidecar directory without ever following a symlink and without
/// reopening a path after checking it: a Claude sidecar is a flat directory
/// of `agent-*.jsonl` logs, so its entries are unlinked one by one —
/// `remove_file` on a symlink removes the link, never its target — and a
/// nested directory, which a sidecar never has, is refused rather than
/// walked. Nothing here descends, so a directory swapped for a link
/// between two calls has nothing to redirect.
fn remove_sidecar_without_following_links(dir: &Path) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        // The entry's own type, from the directory listing, not from a
        // second look-up of its pathname.
        if entry.file_type()?.is_dir() {
            return Err(std::io::Error::other(
                "a sidecar with a nested directory is left alone",
            ));
        }
        std::fs::remove_file(entry.path())?;
    }
    std::fs::remove_dir(dir)
}

/// The session id the file names right now, read the way discovery reads it.
fn reparse_session_id(provider: SessionProvider, path: &Path) -> Option<String> {
    match provider {
        SessionProvider::Codex => discovery::codex_session_id(path),
        SessionProvider::Claude => discovery::claude_session_id(path),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn home() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }

    fn write(path: &Path, lines: &[&str]) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut file = std::fs::File::create(path).unwrap();
        for line in lines {
            writeln!(file, "{line}").unwrap();
        }
    }

    const CODEX_ID: &str = "0199c4f8-77a1-7e52-b3d8-0a6f6f1e1d2c";
    const CLAUDE_ID: &str = "6d2f1c3a-9b4e-4c1d-8f2a-1b2c3d4e5f60";

    fn codex_session(home: &Path) -> SessionToDelete {
        let path = home
            .join(".codex/sessions/2026/09/03")
            .join(format!("rollout-2026-09-03T10-00-00-{CODEX_ID}.jsonl"));
        write(&path, &[&format!("{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{CODEX_ID}\",\"cwd\":\"/Users/example/app\"}}}}")]);
        SessionToDelete {
            provider: SessionProvider::Codex,
            session_id: CODEX_ID.to_string(),
            source_path: path,
        }
    }

    fn claude_session(home: &Path) -> SessionToDelete {
        let path = home
            .join(".claude/projects/-Users-example-app")
            .join(format!("{CLAUDE_ID}.jsonl"));
        write(&path, &[&format!("{{\"type\":\"user\",\"sessionId\":\"{CLAUDE_ID}\",\"cwd\":\"/Users/example/app\",\"message\":{{\"role\":\"user\",\"content\":\"hi\"}}}}")]);
        SessionToDelete {
            provider: SessionProvider::Claude,
            session_id: CLAUDE_ID.to_string(),
            source_path: path,
        }
    }

    #[test]
    fn deletes_a_codex_rollout_and_nothing_else() {
        let dir = home();
        let session = codex_session(dir.path());
        let neighbour = session.source_path.with_file_name(
            "rollout-2026-09-03T11-00-00-1199c4f8-77a1-7e52-b3d8-0a6f6f1e1d2d.jsonl",
        );
        write(&neighbour, &["{\"type\":\"session_meta\",\"payload\":{\"id\":\"1199c4f8-77a1-7e52-b3d8-0a6f6f1e1d2d\"}}"]);
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        assert_eq!(outcomes, vec![DeleteOutcome::Succeeded(session.clone())]);
        assert!(!session.source_path.exists());
        assert!(neighbour.exists());
    }

    #[test]
    fn deletes_a_claude_session_with_its_sidecar_directory() {
        let dir = home();
        let session = claude_session(dir.path());
        let sidecar = session.source_path.with_extension("");
        write(&sidecar.join("agent-1.jsonl"), &["{}"]);
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        assert!(matches!(outcomes[0], DeleteOutcome::Succeeded(_)));
        assert!(!session.source_path.exists());
        assert!(!sidecar.exists());
    }

    #[test]
    fn refuses_a_file_outside_the_provider_roots() {
        let dir = home();
        let mut session = codex_session(dir.path());
        let elsewhere = dir.path().join("elsewhere.jsonl");
        std::fs::copy(&session.source_path, &elsewhere).unwrap();
        session.source_path = elsewhere.clone();
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        assert!(matches!(
            outcomes[0],
            DeleteOutcome::Failed(_, DeleteError::PathEscapesProviderRoot)
        ));
        assert!(elsewhere.exists());
    }

    #[cfg(unix)]
    #[test]
    fn refuses_a_symlinked_target_and_leaves_its_target_alone() {
        let dir = home();
        let real = codex_session(dir.path());
        let link = real
            .source_path
            .with_file_name(format!("rollout-2026-09-03T12-00-00-{CODEX_ID}.jsonl"));
        std::os::unix::fs::symlink(&real.source_path, &link).unwrap();
        let via_link = SessionToDelete {
            source_path: link.clone(),
            ..real.clone()
        };
        let outcomes = delete(dir.path(), std::slice::from_ref(&via_link));
        assert!(matches!(
            outcomes[0],
            DeleteOutcome::Failed(_, DeleteError::SymlinkedTarget)
        ));
        assert!(real.source_path.exists());
        assert!(std::fs::symlink_metadata(&link).is_ok());
    }

    #[test]
    fn refuses_when_the_file_names_a_different_session() {
        let dir = home();
        let mut session = codex_session(dir.path());
        session.session_id = "ffffffff-0000-4000-8000-000000000000".to_string();
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        assert!(matches!(
            outcomes[0],
            DeleteOutcome::Failed(_, DeleteError::SessionIdMismatch)
        ));
        assert!(session.source_path.exists());
    }

    #[test]
    fn refuses_read_only_providers_before_looking_at_paths() {
        let dir = home();
        let session = SessionToDelete {
            provider: SessionProvider::Cursor,
            session_id: "x".into(),
            source_path: dir.path().join("x"),
        };
        assert_eq!(plan(&session), Err(DeleteError::ProviderIsReadOnly));
        assert!(matches!(
            delete(dir.path(), &[session])[0],
            DeleteOutcome::Failed(_, DeleteError::ProviderIsReadOnly)
        ));
    }

    #[test]
    fn refuses_providers_the_swift_lane_deletes_but_this_one_does_not() {
        let dir = home();
        let session = SessionToDelete {
            provider: SessionProvider::Gemini,
            session_id: "x".into(),
            source_path: dir.path().join("x"),
        };
        assert_eq!(plan(&session), Err(DeleteError::ProviderNotImplemented));
    }

    #[test]
    fn an_empty_claude_file_with_a_uuid_name_is_unreadable_not_deleted() {
        let dir = home();
        let session = claude_session(dir.path());
        std::fs::write(&session.source_path, "").unwrap();
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        assert!(matches!(
            outcomes[0],
            DeleteOutcome::Failed(_, DeleteError::ValidationUnreadable)
        ));
        assert!(session.source_path.exists());
    }

    #[test]
    fn a_codex_file_without_metadata_is_unreadable_whatever_its_name_says() {
        let dir = home();
        let session = codex_session(dir.path());
        write(
            &session.source_path,
            &["{\"type\":\"event_msg\",\"payload\":{\"text\":\"no meta here\"}}"],
        );
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        assert!(matches!(
            outcomes[0],
            DeleteOutcome::Failed(_, DeleteError::ValidationUnreadable)
        ));
        assert!(session.source_path.exists());
    }

    #[test]
    fn a_codex_file_whose_metadata_disagrees_with_its_name_is_refused() {
        let dir = home();
        let session = codex_session(dir.path());
        write(&session.source_path, &["{\"type\":\"session_meta\",\"payload\":{\"id\":\"ffffffff-0000-4000-8000-000000000000\"}}"]);
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        assert!(matches!(
            outcomes[0],
            DeleteOutcome::Failed(_, DeleteError::ValidationUnreadable)
        ));
        assert!(session.source_path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_root_component_authorizes_nothing() {
        let dir = home();
        let outside = tempfile::tempdir().unwrap();
        // `<home>/.codex` is a link to a directory outside the home.
        std::os::unix::fs::symlink(outside.path(), dir.path().join(".codex")).unwrap();
        let path = outside
            .path()
            .join("sessions/2026/09/03")
            .join(format!("rollout-2026-09-03T10-00-00-{CODEX_ID}.jsonl"));
        write(
            &path,
            &[&format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{CODEX_ID}\"}}}}"
            )],
        );
        assert!(provider_roots(SessionProvider::Codex, dir.path()).is_empty());
        let session = SessionToDelete {
            provider: SessionProvider::Codex,
            session_id: CODEX_ID.into(),
            source_path: path.clone(),
        };
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        assert!(matches!(
            outcomes[0],
            DeleteOutcome::Failed(_, DeleteError::PathEscapesProviderRoot)
        ));
        assert!(path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_directory_inside_the_root_is_refused() {
        let dir = home();
        let real = codex_session(dir.path());
        // `<root>/2026/09/link` → `<root>/2026/09/03`: inside the root, but a link.
        let link_dir = dir.path().join(".codex/sessions/2026/09/link");
        std::os::unix::fs::symlink(dir.path().join(".codex/sessions/2026/09/03"), &link_dir)
            .unwrap();
        let via_link = SessionToDelete {
            source_path: link_dir.join(real.source_path.file_name().unwrap()),
            ..real.clone()
        };
        let outcomes = delete(dir.path(), std::slice::from_ref(&via_link));
        assert!(
            matches!(
                outcomes[0],
                DeleteOutcome::Failed(_, DeleteError::PathEscapesProviderRoot)
            ),
            "{outcomes:?}"
        );
        assert!(real.source_path.exists());
    }

    #[test]
    fn revalidates_the_older_thread_id_form_and_a_tail_only_meta() {
        let dir = home();
        let session = codex_session(dir.path());
        write(
            &session.source_path,
            &[&format!(
                "{{\"type\":\"session_meta\",\"payload\":{{\"thread_id\":\"{CODEX_ID}\"}}}}"
            )],
        );
        assert!(matches!(
            delete(dir.path(), std::slice::from_ref(&session))[0],
            DeleteOutcome::Succeeded(_)
        ));
        let session = codex_session(dir.path());
        let mut lines: Vec<String> = (0..12)
            .map(|i| format!("{{\"type\":\"event_msg\",\"payload\":{{\"n\":{i}}}}}"))
            .collect();
        lines.push(format!(
            "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{CODEX_ID}\"}}}}"
        ));
        let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
        write(&session.source_path, &refs);
        assert!(matches!(
            delete(dir.path(), std::slice::from_ref(&session))[0],
            DeleteOutcome::Succeeded(_)
        ));
    }

    #[test]
    fn an_id_on_some_other_record_does_not_revalidate() {
        let dir = home();
        let session = codex_session(dir.path());
        write(
            &session.source_path,
            &[&format!(
                "{{\"type\":\"response_item\",\"payload\":{{\"id\":\"{CODEX_ID}\"}}}}"
            )],
        );
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        assert!(matches!(
            outcomes[0],
            DeleteOutcome::Failed(_, DeleteError::ValidationUnreadable)
        ));
        assert!(session.source_path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_aliasing_the_root_is_refused() {
        let dir = home();
        let real = codex_session(dir.path());
        let alias = dir.path().join("alias");
        std::os::unix::fs::symlink(dir.path().join(".codex/sessions"), &alias).unwrap();
        let via_alias = SessionToDelete {
            source_path: alias
                .join("2026/09/03")
                .join(real.source_path.file_name().unwrap()),
            ..real.clone()
        };
        let outcomes = delete(dir.path(), std::slice::from_ref(&via_alias));
        assert!(
            matches!(
                outcomes[0],
                DeleteOutcome::Failed(_, DeleteError::PathEscapesProviderRoot)
            ),
            "{outcomes:?}"
        );
        assert!(real.source_path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn a_sidecar_that_cannot_be_removed_leaves_the_session_file() {
        use std::os::unix::fs::PermissionsExt;
        let dir = home();
        let session = claude_session(dir.path());
        let sidecar = session.source_path.with_extension("");
        write(&sidecar.join("agent-1.jsonl"), &["{}"]);
        std::fs::set_permissions(&sidecar, std::fs::Permissions::from_mode(0o500)).unwrap();
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        std::fs::set_permissions(&sidecar, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(
            matches!(
                outcomes[0],
                DeleteOutcome::Failed(_, DeleteError::RemovalFailed(_))
            ),
            "{outcomes:?}"
        );
        assert!(
            session.source_path.exists(),
            "the session file is still there to retry from"
        );
    }

    #[test]
    fn a_sidecar_with_a_nested_directory_is_left_alone() {
        let dir = home();
        let session = claude_session(dir.path());
        let sidecar = session.source_path.with_extension("");
        write(&sidecar.join("nested/deep.jsonl"), &["{}"]);
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        assert!(
            matches!(
                outcomes[0],
                DeleteOutcome::Failed(_, DeleteError::RemovalFailed(_))
            ),
            "{outcomes:?}"
        );
        assert!(session.source_path.exists());
        assert!(sidecar.join("nested/deep.jsonl").exists());
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_inside_the_sidecar_is_unlinked_not_followed() {
        let dir = home();
        let outside = tempfile::tempdir().unwrap();
        let target = outside.path().join("keep.jsonl");
        std::fs::write(&target, "{}").unwrap();
        let session = claude_session(dir.path());
        let sidecar = session.source_path.with_extension("");
        std::fs::create_dir_all(&sidecar).unwrap();
        std::os::unix::fs::symlink(&target, sidecar.join("agent-link.jsonl")).unwrap();
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        assert!(
            matches!(outcomes[0], DeleteOutcome::Succeeded(_)),
            "{outcomes:?}"
        );
        assert!(
            target.exists(),
            "the link's target outside the root is untouched"
        );
        assert!(!sidecar.exists());
    }

    #[test]
    fn a_missing_file_is_unreadable_not_deleted() {
        let dir = home();
        let mut session = codex_session(dir.path());
        std::fs::remove_file(&session.source_path).unwrap();
        session.source_path = session.source_path.clone();
        let outcomes = delete(dir.path(), std::slice::from_ref(&session));
        assert!(matches!(
            outcomes[0],
            DeleteOutcome::Failed(
                _,
                DeleteError::PathEscapesProviderRoot | DeleteError::ValidationUnreadable
            )
        ));
    }
}
