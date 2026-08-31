import Darwin
import Foundation

/// The two questions about a `cursor-agent` worker that the file system alone
/// cannot answer.
///
/// Cursor leaves two kinds of evidence that a CLI agent is running, and both
/// of them lie in one direction. A `cursor-agent-worker-<id>.pid` file survives
/// a crash, so its existence proves nothing and the pid inside it has to be
/// checked. A `worker.sock` survives an unclean exit too, so a *stale* socket
/// looks exactly like a live one until something tries to connect to it.
enum CursorWorkerProbe {
    /// Whether a pid names a process that exists right now.
    ///
    /// `kill(pid, 0)` sends no signal; it asks the kernel whether it could.
    /// `EPERM` is a *yes* — the process exists and belongs to somebody else —
    /// and only `ESRCH` means gone.
    ///
    /// Used where no ``ProcessTableReading`` is available, which is discovery;
    /// ``CursorLiveAdapter/probeLiveness(_:table:home:)`` asks the injected
    /// table instead so the suite can drive every branch.
    static func isProcessAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Whether anything is listening on a unix socket.
    ///
    /// A non-blocking `connect(2)` to an `AF_UNIX` stream socket completes or
    /// fails immediately; there is no round trip to wait on and no handshake
    /// to interrupt. The descriptor is closed at once and nothing is written,
    /// so a live worker sees a connection that opened and went away — which is
    /// what every dead client already looks like to it.
    ///
    /// `false` for a path that is not a socket, for a socket nobody is
    /// listening on (`ECONNREFUSED` — the stale-file case this exists to
    /// detect), and for a path too long for `sun_path`.
    static func socketAccepts(path: String) -> Bool {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < capacity else { return false }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
            destination[bytes.count] = 0
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        // A stream connect that has not finished yet still proves somebody is
        // listening; only a refusal proves nobody is.
        return errno == EINPROGRESS || errno == EALREADY || errno == EISCONN
    }
}
