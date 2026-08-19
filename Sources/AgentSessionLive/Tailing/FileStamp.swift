import Darwin
import Foundation

/// The three facts about a file that decide whether tailing it can resume.
///
/// Read through `stat(2)` rather than `FileManager.attributesOfItem`, because
/// this runs on every poll of every source: the dictionary version allocates
/// an `NSDictionary` and boxes each value, and a board with sixty live
/// sessions polls sixty times a second in the worst case.
///
/// `inode` is the load-bearing field. A byte offset is only meaningful
/// against the file it was taken in — a harness that rotates its log leaves
/// the offset pointing into unrelated bytes — so every cursor carries the
/// inode it was taken under and a mismatch means "re-seed, do not resume".
struct FileStamp: Hashable, Sendable {
    /// The inode number, as `st_ino`.
    var inode: UInt64
    /// The size in bytes, as `st_size`.
    var size: Int64
    /// Last modification, at whatever resolution the filesystem recorded.
    var modified: Date

    /// Stats `path`, following no symlink of its own accord — `stat(2)` does
    /// resolve links, which is what a tailer wants: a harness that writes
    /// through a symlinked directory is still writing to a real file, and
    /// the inode it returns is the real one.
    ///
    /// Returns `nil` for anything that cannot be stat'd, which for a tailer
    /// means "the file is not there right now" and never means "fail".
    static func read(path: String) -> FileStamp? {
        var buffer = stat()
        guard stat(path, &buffer) == 0 else { return nil }
        let seconds = TimeInterval(buffer.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(buffer.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileStamp(
            inode: UInt64(buffer.st_ino),
            size: Int64(buffer.st_size),
            modified: Date(timeIntervalSince1970: seconds + nanoseconds)
        )
    }

    /// The file's creation date (`st_birthtimespec`), or `nil` when it cannot
    /// be stat'd. Used to stamp a `sessionStarted` for a source discovered
    /// mid-life, where the transcript's birth is the closest thing on disk to
    /// when the session began.
    static func creationDate(atPath path: String) -> Date? {
        var buffer = stat()
        guard stat(path, &buffer) == 0 else { return nil }
        let seconds = TimeInterval(buffer.st_birthtimespec.tv_sec)
        let nanoseconds = TimeInterval(buffer.st_birthtimespec.tv_nsec) / 1_000_000_000
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds + nanoseconds)
    }
}
