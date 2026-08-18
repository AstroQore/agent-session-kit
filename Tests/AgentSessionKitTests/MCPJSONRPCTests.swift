import Foundation
import XCTest
@testable import AgentSessionKit

/// The wire types only. Dispatching a method against a real tool surface is
/// the host application's business; what has to hold here is that a line
/// decodes to what the client wrote and a reply frames back byte-exactly.
final class MCPJSONRPCTests: XCTestCase {
    // MARK: - MCPJSON

    func testIntegersSurviveTheRoundTripAsIntegers() throws {
        // Re-encoding 1 as 1.0 makes a token count look like a measurement.
        let value = try MCPJSON.encoding(["tokens": 1_234])
        XCTAssertEqual(value["tokens"], .int(1_234))
        let text = String(decoding: try value.serialized(), as: UTF8.self)
        XCTAssertEqual(text, #"{"tokens":1234}"#)
    }

    func testEveryScalarShapeDecodesToItsOwnCase() throws {
        let raw = Data(#"{"a":null,"b":true,"c":7,"d":1.5,"e":"s","f":[1,"x"],"g":{"h":0}}"#.utf8)
        let value = try JSONDecoder().decode(MCPJSON.self, from: raw)
        XCTAssertEqual(value["a"], .null)
        XCTAssertEqual(value["b"], .bool(true))
        XCTAssertEqual(value["c"], .int(7))
        XCTAssertEqual(value["d"], .double(1.5))
        XCTAssertEqual(value["e"], .string("s"))
        XCTAssertEqual(value["f"], .array([.int(1), .string("x")]))
        XCTAssertEqual(value["g"], .object(["h": .int(0)]))
    }

    /// A client that sends `20.0` for a page size means twenty.
    func testWholeDoublesReadAsIntegersAndFractionsDoNot() {
        XCTAssertEqual(MCPJSON.double(20).intValue, 20)
        XCTAssertNil(MCPJSON.double(20.5).intValue)
        XCTAssertNil(MCPJSON.double(.infinity).intValue)
        XCTAssertEqual(MCPJSON.int(3).doubleValue, 3)
    }

    /// Clients reach for the bare string when a filter happens to have one
    /// element, and rejecting that buys nothing.
    func testStringListTakesBothTheListAndTheSingletonSpelling() {
        XCTAssertEqual(MCPJSON.string("codex").stringListValue, ["codex"])
        XCTAssertEqual(MCPJSON.array(["codex", "cursor"]).stringListValue, ["codex", "cursor"])
        XCTAssertNil(MCPJSON.int(1).stringListValue)
    }

    func testEncoderKeepsKeysSortedAndSlashesUnescaped() throws {
        struct Row: Encodable {
            let uri: String
            let at: Date
        }
        let text = try MCPJSON.prettyText(Row(uri: "kit://a/b", at: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(text.contains("kit://a/b"), text)
        XCTAssertTrue(text.contains("1970-01-01T00:00:00Z"), text)
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "\"at\"")).lowerBound,
            try XCTUnwrap(text.range(of: "\"uri\"")).lowerBound,
            "Sorted keys are what keeps the text block and structuredContent in step."
        )
    }

    // MARK: - Requests

    func testARequestDecodesItsMethodIDAndParams() throws {
        let request = try MCPRequest.decode(
            line: Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"x"}}"#.utf8)
        )
        XCTAssertEqual(request.id, .int(4))
        XCTAssertEqual(request.method, "tools/call")
        XCTAssertEqual(request.params?["name"], .string("x"))
        XCTAssertFalse(request.isNotification)
    }

    /// A notification is exactly a request with no id — and an explicit
    /// `"id": null` is the same thing, which is what keeps a client that
    /// spells it that way from waiting forever for a reply.
    func testAMissingOrNullIDMakesItANotification() throws {
        for line in [
            #"{"method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"notifications/initialized"}"#
        ] {
            let request = try MCPRequest.decode(line: Data(line.utf8))
            XCTAssertTrue(request.isNotification, line)
            XCTAssertNil(request.id, line)
        }
    }

    /// Bytes that are not JSON and JSON that is not a request are two
    /// different failures, fixed in two different places.
    func testParseErrorsAndInvalidRequestsAreDistinguished() {
        XCTAssertThrowsError(try MCPRequest.decode(line: Data("{oops".utf8))) {
            XCTAssertEqual(($0 as? MCPRPCError)?.code, -32_700)
        }
        for line in [#"[1,2]"#, #"{"id":1}"#, #"{"method":""}"#] {
            XCTAssertThrowsError(try MCPRequest.decode(line: Data(line.utf8)), line) {
                XCTAssertEqual(($0 as? MCPRPCError)?.code, -32_600, line)
            }
        }
    }

    /// Omitting `"jsonrpc"` is tolerated; claiming a *different* version is
    /// a real mismatch worth naming.
    func testOnlyAWrongJSONRPCVersionIsRejected() throws {
        XCTAssertNoThrow(try MCPRequest.decode(line: Data(#"{"id":1,"method":"ping"}"#.utf8)))
        XCTAssertThrowsError(
            try MCPRequest.decode(line: Data(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#.utf8))
        ) {
            XCTAssertEqual(($0 as? MCPRPCError)?.code, -32_600)
        }
    }

    // MARK: - Responses

    func testAFramedResponseIsExactlyOneNewlineTerminatedLine() throws {
        let framed = MCPResponse(id: .int(1), result: ["ok": true]).framed()
        XCTAssertEqual(framed.last, 0x0A)
        XCTAssertEqual(framed.dropLast().firstIndex(of: 0x0A), nil, "No embedded newlines.")
        let decoded = try JSONDecoder().decode(MCPJSON.self, from: framed.dropLast())
        XCTAssertEqual(decoded["jsonrpc"], .string("2.0"))
        XCTAssertEqual(decoded["id"], .int(1))
        XCTAssertEqual(decoded["result"]?["ok"], .bool(true))
        XCTAssertNil(decoded["error"])
    }

    func testAnErrorResponseCarriesTheCodeMessageAndData() throws {
        let error = MCPRPCError.invalidParams("'limit' must be a whole number.")
        let framed = MCPResponse(id: .string("abc"), error: error).framed()
        let decoded = try JSONDecoder().decode(MCPJSON.self, from: framed.dropLast())
        XCTAssertEqual(decoded["id"], .string("abc"))
        XCTAssertEqual(decoded["error"]?["code"], .int(-32_602))
        XCTAssertEqual(decoded["error"]?["message"]?.stringValue, "'limit' must be a whole number.")
        XCTAssertNil(decoded["result"])

        let withData = MCPRPCError(code: -32_000, message: "m", data: ["why": "because"])
        let payload = MCPResponse(id: .null, error: withData).framed()
        let decodedData = try JSONDecoder().decode(MCPJSON.self, from: payload.dropLast())
        XCTAssertEqual(decodedData["error"]?["data"]?["why"], .string("because"))
    }

    func testTheStandardErrorConstructorsUseTheSpecCodes() {
        XCTAssertEqual(MCPRPCError.parseError().code, -32_700)
        XCTAssertEqual(MCPRPCError.invalidRequest("x").code, -32_600)
        XCTAssertEqual(MCPRPCError.methodNotFound("nope").code, -32_601)
        XCTAssertEqual(MCPRPCError.methodNotFound("nope").message, "Unknown method 'nope'.")
        XCTAssertEqual(MCPRPCError.invalidParams("x").code, -32_602)
        XCTAssertEqual(MCPRPCError.internalError("x").code, -32_603)
    }

    // MARK: - Arguments

    private static let tool = MCPTool(
        name: "sessions.list",
        title: "List sessions",
        description: "",
        inputSchema: [
            "type": "object",
            "properties": [
                "harnesses": ["type": "array"],
                "since": ["type": "string"],
                "limit": ["type": "integer"],
                "verbose": ["type": "boolean"]
            ]
        ]
    )

    private func arguments(_ raw: MCPJSON?) throws -> MCPArguments {
        try MCPArguments(tool: Self.tool, raw: raw)
    }

    /// A misspelled filter that is silently ignored answers a question
    /// nobody asked, so unknown keys are a hard error naming both sides.
    func testUnknownArgumentsAreRejectedAndTheAcceptedSetIsListed() {
        XCTAssertThrowsError(try arguments(["harneses": ["codex"]])) { error in
            let message = (error as? MCPRPCError)?.message ?? ""
            XCTAssertTrue(message.contains("'harneses'"), message)
            XCTAssertTrue(message.contains("'harnesses'"), message)
        }
        XCTAssertThrowsError(try arguments(.string("nope"))) {
            XCTAssertEqual(($0 as? MCPRPCError)?.code, -32_602)
        }
        XCTAssertNoThrow(try arguments(nil))
        XCTAssertNoThrow(try arguments(.null))
    }

    func testNullIsTreatedAsAbsentRatherThanAsAValue() throws {
        let args = try arguments(["limit": .null, "since": .null])
        XCTAssertNil(try args.optionalInt("limit", minimum: 1, maximum: 10))
        XCTAssertNil(try args.optionalDate("since"))
    }

    func testTypeAndRangeFailuresNameTheToolAndTheKey() throws {
        let args = try arguments(["limit": .string("many"), "verbose": .int(1)])
        XCTAssertThrowsError(try args.optionalInt("limit", minimum: 1, maximum: 10)) {
            XCTAssertTrue(($0 as? MCPRPCError)?.message.contains("sessions.list: 'limit'") ?? false)
        }
        XCTAssertThrowsError(try args.optionalBool("verbose"))

        let big = try arguments(["limit": 999])
        XCTAssertThrowsError(try big.optionalInt("limit", minimum: 1, maximum: 10)) {
            XCTAssertTrue(($0 as? MCPRPCError)?.message.contains("got 999") ?? false)
        }
    }

    func testEnumListsRejectUnknownMembersAndKeepAnExplicitEmptyList() throws {
        let good = try arguments(["harnesses": ["codex", "cursor"]])
        XCTAssertEqual(try good.optionalEnumList("harnesses", Harness.self), [.codex, .cursor])

        // Empty means "nothing matches", not "everything".
        let empty = try arguments(["harnesses": .array([])])
        XCTAssertEqual(try empty.optionalEnumList("harnesses", Harness.self), [])

        let bad = try arguments(["harnesses": ["codex", "nope"]])
        XCTAssertThrowsError(try bad.optionalEnumList("harnesses", Harness.self)) {
            XCTAssertTrue(($0 as? MCPRPCError)?.message.contains("'nope'") ?? false)
        }
    }

    func testRequiredValuesFailWhenAbsent() throws {
        let args = try arguments([:])
        XCTAssertThrowsError(try args.requiredString("since"))
        XCTAssertThrowsError(try args.requiredEnum("harnesses", Harness.self))
    }

    /// A bare `YYYY-MM-DD` means midnight *local*: an agent asking for
    /// "since 2026-08-01" means the user's own first of August, not UTC's.
    func testDatesAcceptBothISOSpellingsAndABareLocalDay() throws {
        var utc = DateComponents()
        utc.year = 2026
        utc.month = 8
        utc.day = 1
        utc.hour = 9
        utc.minute = 30
        utc.timeZone = TimeZone(secondsFromGMT: 0)
        let instant = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: utc))

        XCTAssertEqual(MCPDateParsing.parse("2026-08-01T09:30:00Z"), instant)
        XCTAssertEqual(
            MCPDateParsing.parse("2026-08-01T09:30:00.250Z"),
            instant.addingTimeInterval(0.25)
        )
        let localMidnight = try XCTUnwrap(MCPDateParsing.parse("2026-08-01"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        XCTAssertEqual(calendar.component(.hour, from: localMidnight), 0)
        XCTAssertEqual(calendar.component(.day, from: localMidnight), 1)

        XCTAssertNil(MCPDateParsing.parse("   "))
        XCTAssertNil(MCPDateParsing.parse("last tuesday"))
        XCTAssertThrowsError(try arguments(["since": "last tuesday"]).optionalDate("since"))
    }

    func testToolAndResourceDescriptorsRenderTheirListShape() {
        XCTAssertEqual(Self.tool.json["name"], .string("sessions.list"))
        XCTAssertEqual(Self.tool.json["inputSchema"], Self.tool.inputSchema)
        let resource = MCPResource(
            uri: "kit://naming",
            name: "naming",
            title: "Naming",
            description: "d",
            mimeType: "text/markdown"
        )
        XCTAssertEqual(resource.json["uri"], .string("kit://naming"))
        XCTAssertEqual(resource.json["mimeType"], .string("text/markdown"))
    }
}
