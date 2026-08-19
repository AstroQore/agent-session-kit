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
    /// Where the running app's listener is expected to be, resolved lazily.
    ///
    /// A closure rather than a stored `String` because some hosts derive
    /// their default from the real home directory — `RealHomeDirectory`,
    /// not `NSHomeDirectory()`, inside a sandboxed app — which can only be
    /// looked up correctly at the point the socket path is actually needed,
    /// not when the config happens to be built. Resolving lazily means a
    /// host never has to rebuild its config just because that lookup would
    /// have returned something different.
    public let defaultSocketPath: @Sendable () -> String
    /// What to print on stderr when nothing is listening. Given the socket
    /// path; the host owns the wording because only it can name the app the
    /// user is supposed to launch.
    public let notRunningMessage: @Sendable (String) -> String
    /// What to print when the app is alive but has no client slot left. The
    /// socket listener sends a private transport control frame before closing;
    /// the bridge consumes that frame and turns it into an actionable process
    /// failure instead of an empty successful stdout stream.
    public let connectionLimitMessage: @Sendable () -> String

    /// Primary initializer. `defaultSocketPath` is called each time
    /// ``MCPStdioBridge/socketPath(_:environment:)`` needs it — not cached.
    public init(
        flag: String,
        envKey: String,
        defaultSocketPath: @escaping @Sendable () -> String,
        notRunningMessage: @escaping @Sendable (String) -> String = { path in
            "No MCP server is listening on \(path). Start the app that serves it first."
        },
        connectionLimitMessage: @escaping @Sendable () -> String = {
            "The MCP server has no free client slots. Close stale MCP clients and try again."
        }
    ) {
        self.flag = flag
        self.envKey = envKey
        self.defaultSocketPath = defaultSocketPath
        self.notRunningMessage = notRunningMessage
        self.connectionLimitMessage = connectionLimitMessage
    }

    /// Backward-compatible convenience initializer for a default socket path
    /// that is already a fixed `String` — wrapped in a closure that always
    /// returns it.
    public init(
        flag: String,
        envKey: String,
        defaultSocketPath: String,
        notRunningMessage: @escaping @Sendable (String) -> String = { path in
            "No MCP server is listening on \(path). Start the app that serves it first."
        },
        connectionLimitMessage: @escaping @Sendable () -> String = {
            "The MCP server has no free client slots. Close stale MCP clients and try again."
        }
    ) {
        self.init(
            flag: flag,
            envKey: envKey,
            defaultSocketPath: { defaultSocketPath },
            notRunningMessage: notRunningMessage,
            connectionLimitMessage: connectionLimitMessage
        )
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
///
/// The primary API is static — `MCPStdioBridge.isRequested`,
/// `MCPStdioBridge.socketPath`, `MCPStdioBridge.run` — because a host's
/// `main.swift` runs before any instance would exist to hang them off of.
/// The instance API (`init(config:)` plus unlabeled `isRequested`,
/// `socketPath`, and `run`) is a thin convenience over the same statics for
/// hosts that would rather hold one configured value than thread `config`
/// through every call.
public struct MCPStdioBridge: Sendable {
    public enum ExitCode {
        public static let ok: Int32 = 0
        /// Nothing was listening — almost always "the app is not running".
        public static let notRunning: Int32 = 1
        /// The app is running, but its listener deliberately refused this
        /// bridge because every client slot is occupied.
        public static let connectionLimit: Int32 = 2
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
        return config.defaultSocketPath()
    }

    /// Connect, pump both directions, return an exit code.
    ///
    /// Returns when either side closes: stdin closing is the client shutting
    /// the server down, and the socket closing is the app quitting. Both are
    /// ordinary ends of a session, so both exit zero. Failure to connect and
    /// an explicit capacity rejection are non-zero and write to stderr.
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

        let downstream = pumpSocketToOutput(from: socketFD, to: output)
        // The socket closed. Do not wait on the stdin thread: it is parked in
        // a blocking read the client may never end, and the process exiting is
        // what the client is waiting for.
        close(socketFD)
        if downstream == .connectionLimit {
            standardError.write(Data((config.connectionLimitMessage() + "\n").utf8))
            return ExitCode.connectionLimit
        }
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

    // MARK: - Instance API

    /// This instance's configuration, as given to ``init(config:)``.
    public let config: MCPStdioBridgeConfig

    /// Wraps `config` for callers that would rather hold one configured
    /// value than pass `config` to every static call below.
    public init(config: MCPStdioBridgeConfig) {
        self.config = config
    }

    /// Whether `arguments` selects bridge mode. Wraps
    /// ``isRequested(_:arguments:)`` with ``config``.
    public func isRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        Self.isRequested(config, arguments: arguments)
    }

    /// Wraps ``socketPath(_:environment:)`` with ``config``.
    public func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        Self.socketPath(config, environment: environment)
    }

    /// Connect to `path`, pump both directions, return an exit code. Wraps
    /// ``run(_:socketPath:input:output:standardError:)`` with ``config``.
    public func run(
        socketPath path: String,
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        standardError: FileHandle = .standardError
    ) -> Int32 {
        Self.run(config, socketPath: path, input: input, output: output, standardError: standardError)
    }

    /// Resolve the socket from the environment and run. Wraps
    /// ``run(_:environment:input:output:standardError:)`` with ``config`` —
    /// the shape a host's `main.swift` wants:
    ///
    /// ```swift
    /// let bridge = MCPStdioBridge(config: config)
    /// if bridge.isRequested() { exit(bridge.run()) }
    /// ```
    public func run(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        standardError: FileHandle = .standardError
    ) -> Int32 {
        Self.run(config, environment: environment, input: input, output: output, standardError: standardError)
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

    private enum DownstreamResult {
        case ended
        case connectionLimit
    }

    /// The listener's capacity rejection is the one transport event a stdio
    /// client cannot otherwise distinguish from an orderly app shutdown: both
    /// are an immediate socket EOF. Buffer only the first few bytes while they
    /// still match the private rejection frame; every ordinary MCP response is
    /// forwarded byte-for-byte as soon as its prefix differs.
    private static func pumpSocketToOutput(from source: Int32, to destination: Int32) -> DownstreamResult {
        let rejection = MCPSocketServer.connectionLimitFrame
        var undecided = Data()
        var isCheckingRejection = true
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count > 0 {
                if isCheckingRejection {
                    undecided.append(contentsOf: chunk[0..<count])
                    if rejection.starts(with: undecided) {
                        if undecided.count == rejection.count { return .connectionLimit }
                        continue
                    }
                    guard writeAll([UInt8](undecided), count: undecided.count, to: destination) else {
                        return .ended
                    }
                    undecided.removeAll(keepingCapacity: false)
                    isCheckingRejection = false
                    continue
                }
                guard writeAll(chunk, count: count, to: destination) else { return .ended }
                continue
            }
            if !undecided.isEmpty {
                _ = writeAll([UInt8](undecided), count: undecided.count, to: destination)
            }
            if count == 0 { return .ended }
            if errno == EINTR { continue }
            return .ended
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
