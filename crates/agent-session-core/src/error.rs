use thiserror::Error;

#[derive(Debug, Error)]
pub enum SessionCoreError {
    /// The index file exists but its `PRAGMA user_version` is not the one this
    /// crate understands. The reader refuses to touch it — rebuilding is the
    /// index owner's job, never a reader's.
    #[error("session index schema version {found} is not supported (expected {expected})")]
    UnsupportedIndexSchema { found: i64, expected: i64 },

    #[error("session index not found at {0}")]
    IndexNotFound(String),

    #[error("session source must be a non-symlink regular file: {0}")]
    UnsafePath(String),

    #[error("session row {0} was not found in this index generation")]
    SessionNotFound(i64),

    #[error("session provider {0} is not supported by this crate version")]
    UnknownProvider(String),

    #[error("{field} filter has more than {max} distinct values")]
    FilterTooLarge { field: &'static str, max: usize },

    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),

    #[error(transparent)]
    Io(#[from] std::io::Error),

    /// The id contains something outside the provider's own id charset.
    /// Session ids come off disk, and resume output is pasted into a shell,
    /// so anything unexpected is refused rather than escaped.
    #[error("this session's identifier cannot be used in a command")]
    InvalidSessionId,

    /// The provider (or this variant of it) has no resume command.
    #[error("this session cannot be resumed from the command line")]
    ResumeUnavailable,
}
