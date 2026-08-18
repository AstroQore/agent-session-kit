import Darwin
import Foundation

/// How a host binary presents its stdio bridge: the flag that selects the
/// mode, the environment variable that overrides the socket, and where the
/// socket lives by default.
///
/// All three are the host's vocabulary, not the package's — the flag appears
/// in every user's MCP client config, and the environment key is how a second
/// build points at a temporary socket during tests.
public struct MCPStdioBridgeConfig: Sendable {
    /// The argv token that puts the binary into bridge mode, e.g. `--mcp-stdio`.
    public let flag: String
    /// Environment variable that overrides `defaultSocketPath`.
    public let envKey: String
    /// Where the running app's listener is expected to be.
    public let defaultSocketPath: String
    /// What to print on stderr when nothing is listening. Given the socket
    /// path; the host owns the wording because only it can name the app the
    /// user is supposed to launch.
    public let notRunningMessage: @Sendable (String) -> String

    public init(
        flag: String,
        envKey: String,
        defaultSocketPath: String,
        notRunningMessage: @escaping @Sendable (String) -> String = { path in
            "No MCP server is listening on \(path). Start the app that serves it first."
        }
    ) {
        self.flag = flag
        self.envKey = envKey
        self.defaultSocketPath = defaultSocketPath
        self.notRunningMessage = notRunningMessage
    }
}

/// The stdio mode: run the host binary as a plain stdio MCP server that
/// forwards to the running app's Unix socket.
///
/// MCP clients spawn a command and speak newline-delimited JSON-RPC over its
/// stdin/stdout. `MCPSocketServer` speaks the same framing over a Unix
/// socket, so this is a byte pump rather than a protocol bridge — no parsing,
/// no reframing, and therefore nothing that can corrupt a message it did not
/// understand.
///
/// One command configures every client:
///
/// ```
/// /Applications/YourApp.app/Contents/MacOS/YourApp --mcp-stdio
/// ```
///
/// The process installs no status item, opens no window, and touches nothing
/// on disk except the socket it connects to.
public enum MCPStdioBridge {
    public enum ExitCode {
        public static let ok: Int32 = 0
        /// Nothing was listening — almost always "the app is not running".
        public static let notRunning: Int32 = 1
    }

    /// Whether `arguments` selects bridge mode.
    public static func isRequested(
        _ config: MCPStdioBridgeConfig,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        arguments.dropFirst().contains(config.flag)
    }

    public static func socketPath(
        _ config: MCPStdioBridgeConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let override = environment[config.envKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return config.defaultSocketPath
    }

    /// Connect, pump both directions, return an exit code.
    ///
    /// Returns when either side closes: stdin closing is the client shutting
    /// the server down, and the socket closing is the app quitting. Both are
    /// ordinary ends of a session, so both exit zero — only a failure to
    /// connect at all is an error worth a non-zero code.
    public static func run(
        _ config: MCPStdioBridgeConfig,
        socketPath path: String,
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        standardError: FileHandle = .standardError
    ) -> Int32 {
        guard let socketFD = connect(to: path) else {
            standardError.write(Data((config.notRunningMessage(path) + "\n").utf8))
            return ExitCode.notRunning
        }

        // stdin runs on its own thread with blocking reads. A DispatchSource
        // would work too, but stdin here is a pipe owned by the MCP client and
        // a plain blocking read is both simpler and impossible to get subtly
        // wrong around partial reads.
        let upstreamFinished = DispatchSemaphore(value: 0)
        let thread = Thread {
            pump(from: input, to: socketFD)
            // Half-close so the app sees EOF and releases the connection while
            // still being able to flush whatever it was mid-reply on.
            shutdown(socketFD, SHUT_WR)
            upstreamFinished.signal()
        }
        thread.name = "com.astroqore.AgentSessionKit.mcp.stdio"
        thread.start()

        pump(from: socketFD, to: output)
        // The socket closed. Do not wait on the stdin thread: it is parked in
        // a blocking read the client may never end, and the process exiting is
        // what the client is waiting for.
        close(socketFD)
        return ExitCode.ok
    }

    /// Resolve the socket from the environment and run — the shape a host's
    /// `main.swift` wants.
    public static func run(
        _ config: MCPStdioBridgeConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        standardError: FileHandle = .standardError
    ) -> Int32 {
        run(
            config,
            socketPath: socketPath(config, environment: environment),
            input: input,
            output: output,
            standardError: standardError
        )
    }

    // MARK: - Plumbing

    private static func connect(to path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) - 1 else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard let base = raw.baseAddress else { return }
            base.initializeMemory(as: UInt8.self, repeating: 0, count: raw.count)
            base.copyMemory(from: pathBytes, byteCount: pathBytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Copy bytes until the source ends. Byte-for-byte: the newline framing
    /// travels inside the stream, so nothing here needs to know where a
    /// message starts.
    private static func pump(from source: Int32, to destination: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count > 0 {
                guard writeAll(chunk, count: count, to: destination) else { return }
                continue
            }
            if count == 0 { return }
            if errno == EINTR { continue }
            return
        }
    }

    private static func writeAll(_ bytes: [UInt8], count: Int, to destination: Int32) -> Bool {
        var offset = 0
        while offset < count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(destination, base + offset, count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if errno == EINTR { continue }
            return false
        }
        return true
    }
}
