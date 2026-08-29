//! Cross-platform Rust lane of agent-session-kit.
//!
//! Scope (first slice): read-only access to the shared session index a host
//! app maintains (`session_index.sqlite3`, schema v5), lightweight filesystem
//! discovery for Codex and Claude Code sessions, tolerant JSONL transcript
//! parsing for those two harnesses, and resume-command construction that
//! mirrors the Swift `SessionResumeCommandBuilder` exactly.
//!
//! Everything takes explicit paths — like the Swift package, this crate never
//! invents a location under someone else's home directory, opens no sockets,
//! and spawns no processes. It also never writes: index mutation stays with
//! the index owner (today the Swift implementation).

pub mod discovery;
pub mod error;
pub mod index;
pub mod jsonl;
pub mod provider;
pub mod resume;
pub mod transcript;

pub use error::SessionCoreError;
pub use provider::SessionProvider;

/// Crate version, mirroring `AgentSessionKitInfo.version`'s role on the Swift
/// side. Kept in sync with `Cargo.toml` by `cargo` itself.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
