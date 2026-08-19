import Darwin
import Foundation
import XCTest
@testable import AgentSessionKit

/// End-to-end over a real Unix domain socket on a temporary path.
///
/// The handler here is a stub: what the transport owes its host is framing,
/// file mode, stale-socket recovery, and delivery of in-flight replies —
/// none of which depend on what the lines mean.
final class MCPSocketServerTests: XCTestCase {
    private var directory: URL!
    private var socketPath: String!
    private var socketServer: MCPSocketServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("askmcp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("s.sock").path
        XCTAssertLessThan(socketPath.utf8.count, 104, "The temp socket path must fit in sockaddr_un.")
    }

    override func tearDownWithError() throws {
        socketServer?.stop()
        socketServer = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func makeServer(
        path: String? = nil,
        idleTimeout: TimeInterval? = MCPSocketServer.defaultIdleTimeout
    ) -> MCPSocketServer {
        MCPSocketServer(
            handler: EchoLineHandler(),
            socketPath: path ?? socketPath,
            idleTimeout: idleTimeout
        )
    }

    @discardableResult
    private func startServer() throws -> MCPSocketServer {
        let socket = makeServer()
        try socket.start()
        socketServer = socket
        return socket
    }

    func testTheSocketIsCreatedPrivateAndRemovedOnStop() throws {
        let socket = try startServer()
        XCTAssertTrue(socket.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.int16Value & 0o777, 0o600, "The socket must not be readable by anyone else.")

        socket.stop()
        XCTAssertFalse(socket.isRunning)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketPath),
            "Quitting has to take the socket file with it."
        )
    }

    /// The host — not the server — decides which directory is its to create,
    /// and a hook that throws aborts the start before anything is bound.
    func testTheEnsureDirectoryHookRunsBeforeBindingAndCanRefuse() throws {
        let nested = directory.appendingPathComponent("run", isDirectory: true)
        let nestedSocket = nested.appendingPathComponent("s.sock").path

        struct Refused: Error {}
        let refusing = MCPSocketServer(
            handler: EchoLineHandler(),
            socketPath: nestedSocket,
            ensureDirectory: { throw Refused() }
        )
        XCTAssertThrowsError(try refusing.start()) { XCTAssertTrue($0 is Refused) }
        XCTAssertFalse(refusing.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))

        let creating = MCPSocketServer(
            handler: EchoLineHandler(),
            socketPath: nestedSocket,
            ensureDirectory: {
                try FileManager.default.createDirectory(
                    at: nested,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        )
        defer { creating.stop() }
        try creating.start()
        XCTAssertTrue(creating.isRunning)
    }

    func testAStaleSocketFileDoesNotBlockStartup() throws {
        // What a crash leaves behind: a socket inode with nothing behind it.
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        let socket = try startServer()
        XCTAssertTrue(socket.isRunning)
        XCTAssertEqual(socket.status, .listening)
    }

    /// A second copy of the host app — the usual case is a source build
    /// launched next to the installed one — must not unlink a socket that is
    /// being served. The file looks identical either way, so the check is a
    /// probe connect.
    func testASecondServerReportsAConflictInsteadOfStealingTheSocket() throws {
        let first = try startServer()
        XCTAssertEqual(first.status, .listening)

        let second = makeServer()
        defer { second.stop() }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? MCPSocketError, .socketOwnedByAnotherInstance(socketPath))
        }
        XCTAssertEqual(second.status, .conflict)
        XCTAssertFalse(second.isRunning)

        // The point of the whole exercise: the first server is still there.
        XCTAssertTrue(first.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        let client = try MCPSocketTestClient(path: socketPath)
        defer { client.close() }
        XCTAssertEqual(try client.request(id: 7)["id"]?.intValue, 7)
    }

    /// The conflicting server never bound, so stopping it must leave the live
    /// server's socket file alone.
    func testStoppingAConflictedServerDoesNotRemoveTheLiveSocket() throws {
        let first = try startServer()
        let second = makeServer()
        XCTAssertThrowsError(try second.start())
        second.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertTrue(first.isRunning)
    }

    func testTheLivenessProbeReadsAStaleInodeAsFree() throws {
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        XCTAssertFalse(MCPSocketServer.isAnyoneListening(atPath: socketPath))
        try startServer()
        XCTAssertTrue(MCPSocketServer.isAnyoneListening(atPath: socketPath))
    }

    func testALineRoundTripsToTheHandlerAndBack() throws {
        try startServer()
        let client = try MCPSocketTestClient(path: socketPath)
        defer { client.close() }

        let reply = try client.request(id: 1, method: "ping")
        XCTAssertEqual(reply["id"]?.intValue, 1)
        XCTAssertEqual(reply["result"]?["method"]?.stringValue, "ping")
    }

    /// A notification must not consume a reply slot, or every later response
    /// is read against the wrong request.
    func testANotificationIsAnsweredWithSilence() throws {
        try startServer()
        let client = try MCPSocketTestClient(path: socketPath)
        defer { client.close() }

        try client.send(MCPSocketTestClient.line(id: nil, method: "notifications/initialized"))
        let reply = try client.request(id: 2, method: "ping")
        XCTAssertEqual(reply["id"]?.intValue, 2)
    }

    /// A scripted client (`printf ... | app --mcp-stdio`) writes its requests,
    /// half-closes, and expects every answer before the server hangs up.
    func testRepliesInFlightAreDeliveredAfterThePeerHalfCloses() throws {
        try startServer()
        let client = try MCPSocketTestClient(path: socketPath)
        defer { client.close() }

        try client.send(MCPSocketTestClient.line(id: 1, method: "initialize"))
        try client.send(MCPSocketTestClient.line(id: nil, method: "notifications/initialized"))
        try client.send(MCPSocketTestClient.line(id: 2, method: "tools/list"))
        client.halfClose()

        let first = try client.readLine()
        let second = try client.readLine()
        XCTAssertEqual(Set([first["id"]?.intValue, second["id"]?.intValue]), [1, 2])
        // …and then the server closes on its own.
        XCTAssertTrue(client.readUntilEOF(timeoutSeconds: 5))
    }

    func testTwoClientsAreServedIndependently() throws {
        try startServer()
        let first = try MCPSocketTestClient(path: socketPath)
        let second = try MCPSocketTestClient(path: socketPath)
        defer {
            first.close()
            second.close()
        }
        XCTAssertEqual(try first.request(id: 10)["id"]?.intValue, 10)
        XCTAssertEqual(try second.request(id: 11)["id"]?.intValue, 11)
    }

    func testMalformedInputIsAnsweredRatherThanDroppingTheConnection() throws {
        try startServer()
        let client = try MCPSocketTestClient(path: socketPath)
        defer { client.close() }

        try client.send(Data("{oops".utf8))
        XCTAssertEqual(try client.readLine()["error"]?["code"]?.intValue, -32_700)
        XCTAssertEqual(
            try client.request(id: 4)["id"]?.intValue, 4,
            "The connection must survive a bad line."
        )
    }

    func testConnectionCountIsReported() throws {
        let socket = try startServer()
        XCTAssertEqual(socket.connectionCount, 0)
        let client = try MCPSocketTestClient(path: socketPath)
        _ = try client.request(id: 1)
        XCTAssertEqual(socket.connectionCount, 1)
        let disconnected = expectation(description: "server releases the disconnected client")
        socket.onConnectionChange = { count, _ in
            if count == 0 { disconnected.fulfill() }
        }
        client.close()
        wait(for: [disconnected], timeout: 5)
        socket.onConnectionChange = nil
        XCTAssertEqual(socket.connectionCount, 0)
    }

    func testConnectionDiagnosticsExposePeerPIDAndAllowSafeDisconnect() throws {
        let socket = try startServer()
        let client = try MCPSocketTestClient(path: socketPath)
        defer { client.close() }
        _ = try client.request(id: 1)

        let info = try XCTUnwrap(socket.clientConnections.first)
        XCTAssertEqual(info.processID, Int32(getpid()))
        XCTAssertLessThanOrEqual(info.connectedAt, info.lastActivityAt)
        XCTAssertTrue(socket.disconnectClient(id: info.id))
        XCTAssertEqual(socket.connectionCount, 0)
        XCTAssertTrue(client.readUntilEOF(timeoutSeconds: 5))
        XCTAssertFalse(socket.disconnectClient(id: info.id))
    }

    func testIdleClientIsReclaimedWithoutKillingItsProcess() throws {
        let socket = makeServer(idleTimeout: 0.05)
        socketServer = socket
        try socket.start()
        let expired = expectation(description: "idle client expires")
        socket.onConnectionChange = { count, _ in
            if count == 0 { expired.fulfill() }
        }

        let client = try MCPSocketTestClient(path: socketPath)
        defer { client.close() }
        _ = try client.request(id: 1)
        wait(for: [expired], timeout: 5)
        socket.onConnectionChange = nil
        XCTAssertTrue(client.readUntilEOF(timeoutSeconds: 5))
        XCTAssertEqual(socket.connectionCount, 0)
    }

    func testSeventeenthClientGetsAnExplicitCapacityError() throws {
        let socket = try startServer()
        var clients: [MCPSocketTestClient] = []
        defer { clients.forEach { $0.close() } }
        for id in 1...MCPSocketServer.maximumConnections {
            let client = try MCPSocketTestClient(path: socketPath)
            _ = try client.request(id: id)
            clients.append(client)
        }
        XCTAssertEqual(socket.connectionCount, MCPSocketServer.maximumConnections)

        let refused = try MCPSocketTestClient(path: socketPath)
        defer { refused.close() }
        let error = try refused.readLine()["error"]
        XCTAssertEqual(error?["code"]?.intValue, -32_098)
        XCTAssertEqual(error?["message"]?.stringValue, MCPSocketServer.connectionLimitError.message)
        XCTAssertTrue(refused.readUntilEOF(timeoutSeconds: 5))
    }

    func testAPathTooLongForSockaddrUnFailsClearly() {
        let long = "/tmp/" + String(repeating: "a", count: 120) + ".sock"
        let socket = makeServer(path: long)
        XCTAssertThrowsError(try socket.start()) { error in
            XCTAssertEqual(error as? MCPSocketError, .pathTooLong(long))
        }
    }
}

// MARK: - Stub handler

/// Decodes the line and echoes its method back, so a test can tell which
/// request an answer belongs to without a real tool surface.
private struct EchoLineHandler: MCPLineHandler {
    func handle(line: Data) async -> Data? {
        do {
            let request = try MCPRequest.decode(line: line)
            guard let id = request.id else { return nil }
            return MCPResponse(id: id, result: ["method": .string(request.method)]).framed()
        } catch let error as MCPRPCError {
            return MCPResponse(id: .null, error: error).framed()
        } catch {
            return MCPResponse(id: .null, error: .internalError("\(error)")).framed()
        }
    }
}

// MARK: - A blocking client, just for tests

/// The smallest possible newline-delimited JSON-RPC client. Blocking on
/// purpose: a test that has to poll is a test that flakes.
final class MCPSocketTestClient {
    struct Failure: Error { let message: String }

    private let fd: Int32
    private var buffer = Data()

    static func line(id: Int?, method: String) -> Data {
        var fields: [String: MCPJSON] = ["jsonrpc": "2.0", "method": .string(method)]
        if let id { fields["id"] = .int(Int64(id)) }
        return (try? MCPJSON.object(fields).serialized()) ?? Data()
    }

    init(path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) - 1 else {
            throw Failure(message: "Socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard let base = raw.baseAddress else { return }
            base.initializeMemory(as: UInt8.self, repeating: 0, count: raw.count)
            base.copyMemory(from: bytes, byteCount: bytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { throw Failure(message: "socket() failed: \(errno)") }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(handle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(handle)
            throw Failure(message: "connect() failed: \(errno)")
        }
        // A wedged server must fail the test rather than hang the suite.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        self.fd = handle
    }

    func close() {
        Darwin.close(fd)
    }

    /// Signal EOF to the server while keeping our read side open.
    func halfClose() {
        Darwin.shutdown(fd, SHUT_WR)
    }

    /// True when the server closes the connection within the timeout.
    func readUntilEOF(timeoutSeconds: Int) -> Bool {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return true }
            if count < 0 { return false }
        }
    }

    func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base + offset, raw.count - offset)
            }
            guard written > 0 else { throw Failure(message: "write() failed: \(errno)") }
            offset += written
        }
    }

    func send(_ line: Data) throws {
        var framed = line
        framed.append(0x0A)
        try write(framed)
    }

    func request(id: Int, method: String = "ping") throws -> MCPJSON {
        try send(Self.line(id: id, method: method))
        return try readLine()
    }

    func readLine() throws -> MCPJSON {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return try JSONDecoder().decode(MCPJSON.self, from: line)
            }
            var chunk = [UInt8](repeating: 0, count: 8_192)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { throw Failure(message: "The server closed before answering.") }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
