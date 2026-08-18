import AgentSessionKit
import Foundation

/// Everything known about a session that is not a state or a counter.
///
/// An identity accretes: a tailer usually sees the transcript path and the
/// session id first, the cwd a line later, the model only once a turn has
/// billed tokens, and the pid only if a liveness probe matched a process.
/// Every field but ``key`` and ``sourcePath`` is therefore optional and
/// mutable, filled in by ``AgentEventKind/identityUpdated(_:)`` patches as
/// evidence arrives.
///
/// Nothing here is inferred. If a log does not record the model, `model`
/// stays `nil` — a wrong model on a row is worse than an empty one.
public struct SessionIdentity: Hashable, Codable, Sendable {
    /// The globally unique key for this session.
    public let key: SessionKey
    /// A harness-internal flavour: AntiGravity's `"cli"` / `"ide"`, Codex's
    /// originator, Claude Code's entrypoint variant.
    public var variant: String?
    /// The session that spawned this one, when one did.
    public var parent: SessionKey?
    /// The evidence behind ``parent``. `nil` exactly when `parent` is `nil`.
    public var parentLink: ParentLink?
    /// The working directory the harness was launched in.
    public var cwd: String?
    /// The enclosing git repository root. Left `nil` by adapters; a host's
    /// project resolver fills it in.
    public var gitRoot: String?
    /// The git worktree the session is operating in, when it differs from
    /// ``gitRoot``.
    public var worktreePath: String?
    /// The checked-out branch at the time of the last observation.
    public var gitBranch: String?
    /// The harness process, when a liveness probe matched one.
    public var pid: pid_t?
    /// The start time of ``pid``. Paired with the pid this is what makes a
    /// process identity stable: pids are recycled, (pid, start) is not.
    public var procStart: Date?
    /// The canonical on-disk origin — the transcript file or database this
    /// session is tailed from. Always known: it is how the session was found.
    public var sourcePath: String
    /// A human-facing title, when the harness records or derives one.
    public var title: String?
    /// The model in use, when a log actually recorded one.
    public var model: String?
    /// Where the session was started from: `"terminal"`, `"desktop"`,
    /// `"vscode"`, and so on.
    public var entrypoint: String?

    /// Creates an identity. Only ``key`` and ``sourcePath`` are required;
    /// every other field defaults to "not known yet".
    public init(
        key: SessionKey,
        sourcePath: String,
        variant: String? = nil,
        parent: SessionKey? = nil,
        parentLink: ParentLink? = nil,
        cwd: String? = nil,
        gitRoot: String? = nil,
        worktreePath: String? = nil,
        gitBranch: String? = nil,
        pid: pid_t? = nil,
        procStart: Date? = nil,
        title: String? = nil,
        model: String? = nil,
        entrypoint: String? = nil
    ) {
        self.key = key
        self.sourcePath = sourcePath
        self.variant = variant
        self.parent = parent
        self.parentLink = parentLink
        self.cwd = cwd
        self.gitRoot = gitRoot
        self.worktreePath = worktreePath
        self.gitBranch = gitBranch
        self.pid = pid
        self.procStart = procStart
        self.title = title
        self.model = model
        self.entrypoint = entrypoint
    }
}

/// A sparse update to a ``SessionIdentity``: only the fields that changed.
///
/// A patch is "only-non-nil-wins" by construction, which means it cannot
/// express *clearing* a field. That is deliberate. Every field here is
/// evidence a tailer observed, and observing nothing is not evidence that
/// the previous observation was wrong — a transcript line that omits the
/// model does not mean the model was unset.
public struct SessionIdentityPatch: Hashable, Codable, Sendable {
    /// New working directory, when observed.
    public var cwd: String?
    /// New git branch, when observed.
    public var gitBranch: String?
    /// New title, when observed or derived.
    public var title: String?
    /// New model, when a turn actually named one.
    public var model: String?
    /// The harness process id, once a probe matched one.
    public var pid: pid_t?
    /// The start time of ``pid``.
    public var procStart: Date?
    /// Where the session was started from.
    public var entrypoint: String?
    /// A harness-internal flavour.
    public var variant: String?

    /// Creates a patch. Every field defaults to `nil`, meaning "unchanged".
    public init(
        cwd: String? = nil,
        gitBranch: String? = nil,
        title: String? = nil,
        model: String? = nil,
        pid: pid_t? = nil,
        procStart: Date? = nil,
        entrypoint: String? = nil,
        variant: String? = nil
    ) {
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.title = title
        self.model = model
        self.pid = pid
        self.procStart = procStart
        self.entrypoint = entrypoint
        self.variant = variant
    }

    /// `true` when the patch carries no observation at all. Reducers use
    /// this to skip work; adapters should not emit one.
    public var isEmpty: Bool {
        cwd == nil && gitBranch == nil && title == nil && model == nil
            && pid == nil && procStart == nil && entrypoint == nil && variant == nil
    }

    /// Applies the non-`nil` fields of this patch to `identity`.
    public func applied(to identity: SessionIdentity) -> SessionIdentity {
        var merged = identity
        if let cwd { merged.cwd = cwd }
        if let gitBranch { merged.gitBranch = gitBranch }
        if let title { merged.title = title }
        if let model { merged.model = model }
        if let pid { merged.pid = pid }
        if let procStart { merged.procStart = procStart }
        if let entrypoint { merged.entrypoint = entrypoint }
        if let variant { merged.variant = variant }
        return merged
    }
}
