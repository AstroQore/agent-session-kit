import AgentSessionKit
import Foundation

/// One entry from a Grok Bot transcript replica, read from the transcript
/// owner's — the bot's — point of view.
///
/// Two vintages of entry coexist in the same array and neither is versioned,
/// so the shape is decided by `kind` and by which fields are present:
///
/// ```text
/// {"kind":"send-message","id":…,"timestampMs":…,
///  "message":{"type":"text","content":"…"}}          the bot answering a person
/// {"kind":"message","id":…,"role":"user","content":"…",
///  "isStreaming":false,"timestampMs":…,"clientNonce":…}   a person's own turn
/// {"kind":"message",…,"role":"user","fromAgent":{"name":…}}   another bot asking
/// {"kind":"message",…,"role":"assistant","toAgent":{"name":…}} this bot answering it
/// {"kind":"event","id":…,"event":{"type":"name-changed","from":…,"to":…}}
/// {"kind":"user-attachment","id":…,"file_name":…,"file_path":…}
/// ```
///
/// The direction is the part that is easy to get backwards, and getting it
/// backwards puts every reply on the wrong side of the conversation.
/// `send-message` is the bot's *outbound* turn to the person — it carries no
/// `role` and no `clientNonce`, because it came down from the server — while a
/// `message` with `role: "user"` and a `clientNonce` is what the person typed
/// into the composer. `GrokBotSessionAdapter` reads the same file the same
/// way, and the two must not drift.
public struct GrokBotEntry: Hashable, Sendable {
    /// The `kind` field, which is what decides the rest of the shape.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// The bot's own turn, addressed to the person.
        case sendMessage = "send-message"
        /// A turn by the person, or by another bot talking to this one.
        case message
        /// A rename or an automation change. Not conversation.
        case event
        /// A file the person attached. Not conversation.
        case userAttachment = "user-attachment"
    }

    /// The `role` field on a `message` entry.
    public enum Role: String, Hashable, Sendable, CaseIterable {
        case user
        case assistant
    }

    /// The client's own id for the entry. Stable across rewrites, which is
    /// what makes a cursor into this store possible at all.
    public let id: String
    /// Which shape this is.
    public let kind: Kind
    /// Who spoke, for a `message`. `nil` for every other kind.
    public let role: Role?
    /// The reply is still being generated. The client clears this in place
    /// when the turn finishes, so the same entry is read more than once.
    public let isStreaming: Bool
    /// The entry's own timestamp, when it carried one.
    public let timestamp: Date?
    /// The displayable text, flattened. Empty for an entry that carried none —
    /// a widget, a secret request, an attachment, an event.
    public let text: String
    /// `message.type` for a `send-message`: `text`, `widget`,
    /// `secret-request`, `attachment`, `auto-review-approval`.
    public let payloadType: String?
    /// `event.type` for an `event`: `name-changed`, `automation-changed`.
    public let eventType: String?
    /// The new name on a `name-changed`, or the automation's name on an
    /// `automation-changed`.
    public let eventSubject: String?
    /// The attached file's name. Its *path* is never read: it is a local path
    /// on the person's machine and nothing here has a use for it.
    public let fileName: String?
    /// The other bot in a bot-to-bot turn, by name. `nil` when the person is
    /// the other party.
    public let partner: String?

    /// Parses one entry, or returns `nil` for anything without an id or with
    /// a `kind` this package does not know.
    ///
    /// An unknown kind is dropped rather than guessed at: the client has
    /// added shapes before and will again, and a guess would put an
    /// unrecognised payload on a board as if it were a turn.
    public init?(json entry: [String: Any]) {
        guard let id = SessionParsing.string(entry["id"]), !id.isEmpty,
              let kind = SessionParsing.string(entry["kind"]).flatMap(Kind.init(rawValue:))
        else { return nil }

        self.id = id
        self.kind = kind
        self.role = SessionParsing.string(entry["role"]).flatMap(Role.init(rawValue:))
        self.isStreaming = SessionParsing.bool(entry["isStreaming"])
        self.timestamp = SessionParsing.date(entry["timestampMs"])

        let payload = entry["message"] as? [String: Any]
        switch kind {
        case .sendMessage:
            self.text = SessionParsing.firstNonEmptyText(payload?["content"])
            self.payloadType = SessionParsing.string(payload?["type"])
        case .message:
            self.text = SessionParsing.firstNonEmptyText(entry["content"])
            self.payloadType = nil
        case .event, .userAttachment:
            self.text = ""
            self.payloadType = nil
        }

        let event = entry["event"] as? [String: Any]
        self.eventType = SessionParsing.string(event?["type"])
        self.eventSubject = SessionParsing.firstString(event?["to"], event?["automationName"])
        self.fileName = SessionParsing.string(entry["file_name"])
        self.partner = Self.agentName(entry["fromAgent"]) ?? Self.agentName(entry["toAgent"])
    }

    /// A bot's display name out of a `fromAgent` / `toAgent` object.
    static func agentName(_ value: Any?) -> String? {
        guard let agent = value as? [String: Any] else { return nil }
        guard let name = SessionParsing.string(agent["name"]), !name.isEmpty else { return nil }
        return name
    }

    /// `true` when this entry is the bot talking rather than being talked to.
    ///
    /// A `send-message` is the bot answering the person; a `message` with
    /// `role: "assistant"` is the bot answering another bot. Everything else
    /// is inbound or is not conversation at all.
    public var isFromBot: Bool {
        switch kind {
        case .sendMessage: true
        case .message: role == .assistant
        case .event, .userAttachment: false
        }
    }

    /// `true` when this entry is a turn addressed *to* the bot, and so a turn
    /// the bot still owes an answer to.
    public var isPrompt: Bool {
        kind == .message && role == .user
    }
}
