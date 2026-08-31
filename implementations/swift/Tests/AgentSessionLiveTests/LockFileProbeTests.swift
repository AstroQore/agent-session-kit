import Darwin
import Foundation
import Testing
@testable import AgentSessionLive

private func symbol<T>(_ name: String, as type: T.Type) -> T {
    let handle = dlopen(nil, RTLD_NOW)
    return unsafeBitCast(dlsym(handle, name), to: type)
}

/// `flock(2)`, whose Swift name is shadowed by the `struct flock` that
/// `fcntl` uses. Reached through `dlsym` rather than renamed, because the
/// point of the test is that this exact C function's locks are visible to
/// ``LockFileProbe``.
private let bsdFlock = symbol("flock", as: (@convention(c) (Int32, Int32) -> Int32).self)

/// `fork(2)`, which the Darwin overlay marks unavailable in Swift.
///
/// The advice behind that annotation — use `posix_spawn` — has no answer for
/// what this test needs, which is a second process taking a POSIX record lock
/// on a path we choose. No binary that ships with macOS does that on request.
/// So: fork, and obey the rule the annotation exists to protect, which is
/// that a child of a multi-threaded process may only call async-signal-safe
/// functions. Everything below is `fcntl`, `write`, and `pause`.
private let cFork = symbol("fork", as: (@convention(c) () -> pid_t).self)

/// Forks a child that takes a POSIX write lock on `path` and holds it until
/// it is killed, and returns its pid.
///
/// A second process is not incidental here, it is the whole point: POSIX
/// record locks never conflict with the process that holds them, so a lock
/// taken in this process is invisible to `F_GETLK` in this process. The only
/// way to see a *named* lock holder is for the holder to be somebody else.
private func forkLockHolder(path: String) -> pid_t? {
    let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
    guard descriptor >= 0 else { return nil }
    var ends: [Int32] = [0, 0]
    guard pipe(&ends) == 0 else {
        close(descriptor)
        return nil
    }
    let readEnd = ends[0]
    let writeEnd = ends[1]

    // Allocated before the fork so the child never touches a Swift `inout`
    // and cannot end up inside the runtime's exclusivity bookkeeping.
    let request = UnsafeMutablePointer<Darwin.flock>.allocate(capacity: 1)
    request.initialize(
        to: Darwin.flock(
            l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET)))
    let signal = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    signal.pointee = 0
    defer {
        request.deallocate()
        signal.deallocate()
    }

    let child = cFork()
    if child == 0 {
        signal.pointee = fcntl(descriptor, F_SETLK, request) == 0 ? 1 : 0
        _ = write(writeEnd, signal, 1)
        while true { _ = pause() }
    }

    close(writeEnd)
    close(descriptor)
    guard child > 0 else {
        close(readEnd)
        return nil
    }

    let read = read(readEnd, signal, 1)
    close(readEnd)
    guard read == 1, signal.pointee == 1 else {
        reap(child)
        return nil
    }
    return child
}

private func reap(_ pid: pid_t) {
    kill(pid, SIGKILL)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
}

@Suite("LockFileProbe", .serialized)
struct LockFileProbeTests {
    @Test("a POSIX lock held by another process names its holder")
    func namedHolder() async throws {
        let tree = TemporaryTree()
        let path = tree.file("thread.lock").path
        tree.write("", to: "thread.lock")

        #expect(LockFileProbe.flockHolder(path: path) == nil)
        #expect(!LockFileProbe.isLocked(path: path))

        guard let holder = forkLockHolder(path: path) else {
            Issue.record("could not fork a lock holder; skipping the named-holder assertions")
            return
        }
        #expect(LockFileProbe.flockHolder(path: path) == holder)
        #expect(LockFileProbe.lockState(path: path) == .held(pid: holder))
        #expect(LockFileProbe.isLocked(path: path))

        reap(holder)
        #expect(await waitUntil(timeout: .seconds(3)) {
            LockFileProbe.flockHolder(path: path) == nil
        })
        #expect(LockFileProbe.lockState(path: path) == .unlocked)
    }

    @Test("a flock(2) lock is seen, but the kernel will not name its owner")
    func anonymousHolder() throws {
        let tree = TemporaryTree()
        let path = tree.file("bsd.lock").path
        tree.write("", to: "bsd.lock")

        let descriptor = open(path, O_RDWR)
        try #require(descriptor >= 0)
        defer { close(descriptor) }

        try #require(bsdFlock(descriptor, LOCK_EX | LOCK_NB) == 0)
        // `l_pid` comes back as -1 for a lock that belongs to an open file
        // description rather than to a process, which is what Rust's and Go's
        // file locks produce.
        #expect(LockFileProbe.lockState(path: path) == .heldByUnknownOwner)
        #expect(LockFileProbe.isLocked(path: path))
        #expect(LockFileProbe.flockHolder(path: path) == nil)

        _ = bsdFlock(descriptor, LOCK_UN)
        #expect(LockFileProbe.lockState(path: path) == .unlocked)
        #expect(!LockFileProbe.isLocked(path: path))
    }

    @Test("a file that is not there is unreadable, not unlocked")
    func missingFile() {
        let tree = TemporaryTree()
        let path = tree.file("never-created.lock").path
        #expect(LockFileProbe.lockState(path: path) == .unreadable)
        #expect(!LockFileProbe.isLocked(path: path))
        #expect(LockFileProbe.flockHolder(path: path) == nil)
    }

    @Test("recent writes are recognised, old ones are not")
    func mtimeWindow() throws {
        let tree = TemporaryTree()
        let path = tree.file("heartbeat").path
        tree.write("tick", to: "heartbeat")

        #expect(LockFileProbe.mtimeWithin(path: path, seconds: 60))
        #expect(try #require(LockFileProbe.ageOfLastWrite(path: path)) < 60)

        // Backdate it an hour, which is what a session abandoned before lunch
        // looks like.
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        #expect(!LockFileProbe.mtimeWithin(path: path, seconds: 60))
        #expect(try #require(LockFileProbe.ageOfLastWrite(path: path)) > 3000)

        #expect(!LockFileProbe.mtimeWithin(path: tree.file("absent").path, seconds: 60))
        #expect(LockFileProbe.ageOfLastWrite(path: tree.file("absent").path) == nil)
    }
}
