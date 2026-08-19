import AgentSessionKit
import Darwin
import Foundation

@testable import AgentSessionLive

// MARK: - Synthetic identifiers

/// Every id in these fixtures is invented. The `%` is not decoration: the
/// client's real account ids are percent-encoded and the key parser has to
/// keep accepting one, but nothing here is anybody's actual account.
enum GrokBotFixture {
    static let account = "auth0%7Cuser_example"
    static let otherAccount = "auth0%7Cuser_example2"

    static let scout = "11111111-2222-3333-4444-555555555555"
    static let archivist = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    static let stranger = "99999999-8888-7777-6666-555555555555"

    /// A fixed instant every fixture timeline is built from, in the epoch
    /// milliseconds the client writes.
    static let base: Int64 = 1_787_000_000_000

    static func at(_ offset: Int64) -> Int64 { base + offset * 1000 }
    static func date(_ offset: Int64) -> Date {
        Date(timeIntervalSince1970: Double(at(offset)) / 1000)
    }

    static func transcriptKey(bot: String, account: String = account) -> String {
        "sand.client.slice.account.\(account).transcript.replicas.\(bot)"
    }

    static func rosterKey(account: String = account) -> String {
        "sand.client.slice.account.\(account).roster.last-roster"
    }

    static func session(_ bot: String) -> SessionKey {
        SessionKey(harness: .grokBot, sessionID: bot)
    }
}

// MARK: - Entry builders

/// The JSON for one entry, in the vintage the argument list implies.
///
/// Both vintages coexist in a real replica and neither is versioned, so the
/// fixtures write both: `sendMessage` is the older shape with a nested
/// `message` payload and no `role`, `message` the newer one with `role`,
/// `content`, and `isStreaming` at the top level.
enum GrokBotEntryJSON {
    /// The bot's own turn, addressed to the person.
    static func sendMessage(id: String, at offset: Int64, text: String) -> String {
        """
        {"kind":"send-message","id":"\(id)","timestampMs":\(GrokBotFixture.at(offset)),
         "message":{"type":"text","content":"\(text)"}}
        """
    }

    /// A turn with no text: a widget, a secret request, an approval.
    static func sendPayload(id: String, at offset: Int64, type: String) -> String {
        """
        {"kind":"send-message","id":"\(id)","timestampMs":\(GrokBotFixture.at(offset)),
         "message":{"type":"\(type)","widget":{"kind":"poll"}}}
        """
    }

    /// What the person typed. `clientNonce` is what the client stamps on a
    /// locally composed turn.
    static func prompt(id: String, at offset: Int64, text: String) -> String {
        """
        {"kind":"message","id":"\(id)","role":"user","content":"\(text)",
         "isStreaming":false,"clientNonce":"nonce-\(id)",
         "timestampMs":\(GrokBotFixture.at(offset))}
        """
    }

    /// Another bot asking this one something.
    static func inbound(id: String, at offset: Int64, text: String, from: String) -> String {
        """
        {"kind":"message","id":"\(id)","role":"user","content":"\(text)",
         "isStreaming":false,"timestampMs":\(GrokBotFixture.at(offset)),
         "fromAgent":{"id":"\(GrokBotFixture.archivist)","name":"\(from)"}}
        """
    }

    /// This bot answering another one, possibly mid-stream.
    static func outbound(
        id: String, at offset: Int64, text: String, to: String, streaming: Bool = false
    ) -> String {
        """
        {"kind":"message","id":"\(id)","role":"assistant","content":"\(text)",
         "isStreaming":\(streaming),"timestampMs":\(GrokBotFixture.at(offset)),
         "toAgent":{"id":"\(GrokBotFixture.archivist)","name":"\(to)","kind":"agent"}}
        """
    }

    static func renamed(id: String, at offset: Int64, to: String) -> String {
        """
        {"kind":"event","id":"\(id)","timestampMs":\(GrokBotFixture.at(offset)),
         "event":{"type":"name-changed","from":"Watcher","to":"\(to)"}}
        """
    }

    static func attachment(id: String, name: String) -> String {
        """
        {"kind":"user-attachment","id":"\(id)","file_name":"\(name)",
         "file_path":"/Users/example/Desktop/\(name)","width":8,"height":8,"byteSize":42}
        """
    }

    /// An entry shape this package does not know, which must be skipped
    /// rather than guessed at.
    static func unknownKind(id: String) -> String {
        #"{"kind":"box-instruction","id":"\#(id)","boxRequestId":"r1"}"#
    }
}

// MARK: - A synthetic Grok Bot home

/// A temporary home with a `sand-client-persistence` directory in it.
///
/// Everything the tests read is written by the test that reads it: no fixture
/// file on disk, no real account, and no line of anybody's conversation.
struct GrokBotHome {
    let tree: TemporaryTree

    init(_ label: String = #function) {
        tree = TemporaryTree(label)
        try? FileManager.default.createDirectory(
            at: GrokBotStore.root(home: home), withIntermediateDirectories: true)
    }

    /// The tree's path with every symlink resolved.
    ///
    /// `contentsOfDirectory(at:)` hands back resolved paths — a temporary tree
    /// under `/var` comes back as `/private/var` — and the adapter reports
    /// what the walk found. Resolving once here compares like with like.
    var home: String { Self.real(tree.path) }

    static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    var store: URL { GrokBotStore.root(home: home) }

    /// The path the client would give a blob holding `key`.
    func blobPath(key: String) -> URL {
        store.appendingPathComponent(Base32FixtureEncoder.encode(key)).appendingPathExtension("blob")
    }

    @discardableResult
    func writeBlob(key: String, json: String) -> URL {
        let url = blobPath(key: key)
        try? Data(json.utf8).write(to: url)
        return url
    }

    /// A transcript replica holding `entries`, in file order.
    @discardableResult
    func writeReplica(
        bot: String,
        account: String = GrokBotFixture.account,
        entries: [String]
    ) -> URL {
        writeBlob(
            key: GrokBotFixture.transcriptKey(bot: bot, account: account),
            json: """
            {"schemaVersion":1,"value":{"persistedAt":\(GrokBotFixture.base),
             "epochHint":3,"acceptedSequenceHint":9,"entries":[\(entries.joined(separator: ","))]}}
            """
        )
    }

    /// A roster holding `rows`.
    @discardableResult
    func writeRoster(account: String = GrokBotFixture.account, rows: [String]) -> URL {
        writeBlob(
            key: GrokBotFixture.rosterKey(account: account),
            json: #"{"schemaVersion":2,"value":{"rows":[\#(rows.joined(separator: ","))]}}"#
        )
    }

    /// One roster row. `awaitingUserResponse` is written only when asked for,
    /// because the client leaves it out of most rows.
    static func rosterRow(
        id: String,
        name: String,
        lastActivityAt: Date? = nil,
        awaiting: Bool? = nil
    ) -> String {
        var fields = [
            #""id":"\#(id)""#,
            #""name":"\#(name)""#,
            #""title":"""#,
            #""description":"""#,
            #""path":"/home/box/sand-data/agents/\#(id)/state""#,
            #""createdAt":\#(GrokBotFixture.base)"#
        ]
        if let lastActivityAt {
            fields.append(#""lastActivityAt":\#(Int64(lastActivityAt.timeIntervalSince1970 * 1000))"#)
        }
        if let awaiting {
            fields.append(#""awaitingUserResponse":\#(awaiting)"#)
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Sets a file's modification date, so a test can age a replica without
    /// waiting.
    func touch(_ url: URL, secondsAgo: TimeInterval) {
        let when = Date().addingTimeInterval(-secondsAgo)
        try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
    }
}

// MARK: - Base32, encode side

/// The encoder the client's filenames imply. `AgentSessionKit` ships only the
/// decoder — nothing in the package ever writes one of these files — so the
/// fixtures carry the inverse.
enum Base32FixtureEncoder {
    static func encode(_ text: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in Data(text.utf8) {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            out.append(alphabet[(buffer << (5 - bits)) & 0x1F])
        }
        return out
    }
}

// MARK: - Event helpers

extension Array where Element == AgentEvent {
    /// Every event's kind, for asserting on a whole poll at once.
    var kinds: [AgentEventKind] { map(\.kind) }

    /// The previews of the user prompts, in order.
    var prompts: [String] {
        compactMap { if case let .userPrompt(preview) = $0.kind { preview } else { nil } }
    }

    /// The previews of the assistant turns, in order.
    var replies: [String] {
        compactMap { if case let .assistantText(preview) = $0.kind { preview } else { nil } }
    }

    /// The notes, in order.
    var notes: [String] {
        compactMap { if case let .note(text) = $0.kind { text } else { nil } }
    }

    /// The full-text bodies, in order, with the role each carried.
    var bodies: [(TextBodyRole, String)] {
        compactMap {
            if case let .textBody(role, text, _) = $0.kind { (role, text) } else { nil }
        }
    }

    var hasThinking: Bool {
        contains { if case .thinking = $0.kind { true } else { false } }
    }

    var hasTurnEnded: Bool {
        contains { if case .turnEnded = $0.kind { true } else { false } }
    }
}
