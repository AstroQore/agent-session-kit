import Foundation

/// How far into a source a tailer has read — enough to resume without
/// re-reading, and enough to notice that resuming would be wrong.
///
/// The cases differ because the stores do. A JSONL transcript resumes from a
/// byte offset, but only if it is the *same* file: a harness that rotates or
/// rewrites its log leaves the offset pointing into unrelated bytes, so the
/// inode travels with it and a mismatch means "re-seed, do not resume". A
/// SQLite store resumes from a row id. Cursor's store is content-addressed
/// and resumes from the head blob it last saw.
///
/// A cursor is `Codable` because a host persists it: relaunching should not
/// mean re-reading every transcript on the machine.
public enum SourceCursor: Hashable, Codable, Sendable {
    /// Position in a file, guarded by the inode it was taken in. A different
    /// inode at the same path is a different file, whatever it is called.
    case byteOffset(inode: UInt64, offset: Int64)
    /// The highest row id already consumed from a SQLite-backed store.
    case rowID(Int64)
    /// The content hash of the head record already consumed — Cursor's
    /// `latestRootBlobId` and anything else content-addressed.
    case blobHead(String)
    /// One cursor per path, for a source made of several files. Keys are the
    /// paths from ``SessionSource/allPaths``.
    case composite([String: SourceCursor])
}
