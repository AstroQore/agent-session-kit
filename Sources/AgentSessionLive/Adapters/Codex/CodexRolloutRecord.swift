import AgentSessionKit
import Foundation

/// One decoded JSON value out of a Codex rollout line.
///
/// A rollout record is not a fixed shape. `session_meta.source` is a string
/// (`"vscode"`, `"cli"`) in an ordinary thread and an object
/// (`{"subagent": {"other": "guardian"}}`) in a sub-agent's; a tool call's
/// `output` is a plain string from the CLI and an array of
/// `{"type": "input_text", "text": …}` parts from the desktop app; a
/// `guardian_assessment` grows four fields the moment it resolves. Modelling
/// that with `Codable` structs means either a struct per vintage or a decoder
/// that throws the first time OpenAI adds a field, and a live board that goes
/// blank on a Codex point release is worse than one that ignores a record it
/// does not recognise.
///
/// So: a lenient tree, read once per line, queried by key. Unknown keys cost
/// nothing, missing keys answer `nil`, and a value of the wrong type answers
/// `nil` rather than throwing.
///
/// Deliberately *not* `[String: Any]`: this crosses into a `@Sendable` decode
/// closure, and a `Sendable` value tree is what lets the tailer stay in Swift
/// 6's strict mode without an `@unchecked` anywhere.
public enum CodexJSON: Sendable, Hashable, Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CodexJSON])
    case object([String: CodexJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CodexJSON].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    /// A member of an object, or `nil` for every other case.
    public subscript(key: String) -> CodexJSON? {
        guard case let .object(members) = self else { return nil }
        let value = members[key]
        if case .null = value { return nil }
        return value
    }

    /// The string value, or `nil` when this is not a string.
    ///
    /// Deliberately strict: a number that happens to be spelled as an id is
    /// still not a string, and coercing it would invent an identifier.
    public var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    /// The value as an integer, accepting a numeric string as well — Codex
    /// writes `process_id` as `"7068"` and `exit_code` as `0` in the same
    /// record.
    public var int: Int? {
        switch self {
        case let .number(value):
            guard value.isFinite else { return nil }
            return Int(value)
        case let .string(value):
            return Int(value)
        default:
            return nil
        }
    }

    /// The boolean value, or `nil` when this is not a boolean.
    public var bool: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    /// The elements, or `nil` when this is not an array.
    public var array: [CodexJSON]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    /// The members, or `nil` when this is not an object.
    public var object: [String: CodexJSON]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    /// The first non-`nil` string among `keys`, in the order given.
    ///
    /// The vintage-tolerance workhorse: `firstString("id", "session_id")`
    /// reads a header whichever of the two names this Codex wrote.
    public func firstString(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key]?.string, !value.isEmpty { return value }
        }
        return nil
    }

    /// Every `text` found by walking this value, in order.
    ///
    /// Handles the three shapes a Codex payload uses for prose without the
    /// caller having to know which one it is looking at: a bare string, a
    /// `{"text": …}` object, and an array of content parts. Recursion is
    /// bounded by `depth`, so a pathological record cannot blow the stack.
    public func texts(depth: Int = 6) -> [String] {
        guard depth > 0 else { return [] }
        switch self {
        case let .string(value):
            return value.isEmpty ? [] : [value]
        case let .array(elements):
            return elements.flatMap { $0.texts(depth: depth - 1) }
        case let .object(members):
            if let text = members["text"]?.string {
                return text.isEmpty ? [] : [text]
            }
            return []
        case .null, .bool, .number:
            return []
        }
    }

    /// The concatenation of ``texts(depth:)``, newline-separated.
    public var joinedText: String { texts().joined(separator: "\n") }
}

/// One line of a Codex rollout: the envelope, plus its payload as a lenient
/// tree.
///
/// Every line in `~/.codex/sessions/**/rollout-*.jsonl` has the same three
/// keys — `timestamp`, `type`, `payload` — and everything that varies is
/// inside `payload`. `type` is the outer discriminator (`session_meta`,
/// `turn_context`, `response_item`, `event_msg`, `compacted`, `world_state`,
/// `inter_agent_communication_metadata`) and `payload.type` the inner one.
public struct CodexRolloutRecord: Sendable, Hashable {
    /// The source's own timestamp, or `nil` when the line carried none.
    public let timestamp: Date?
    /// The envelope discriminator.
    public let type: String
    /// Everything else.
    public let payload: CodexJSON

    /// The payload discriminator — `response_item.payload.type` and
    /// `event_msg.payload.type`. `nil` for the envelopes that have none.
    public var payloadType: String? { payload["type"]?.string }

    /// Creates a record. Used by tests; the tailer goes through
    /// ``decode(_:)``.
    public init(timestamp: Date?, type: String, payload: CodexJSON) {
        self.timestamp = timestamp
        self.type = type
        self.payload = payload
    }

    /// Parses one JSONL line, or returns `nil` when it is not a rollout
    /// record.
    ///
    /// Total, like every parser in this package: a truncated line, a line of
    /// a shape we have never seen, and a line of non-JSON bytes all answer
    /// `nil` rather than throwing. A tailer skips it and reads the next one.
    public static func decode(_ data: Data) -> CodexRolloutRecord? {
        guard let envelope = try? JSONDecoder().decode(CodexJSON.self, from: data),
              let type = envelope["type"]?.string
        else { return nil }
        return CodexRolloutRecord(
            timestamp: envelope["timestamp"]?.string.flatMap(SessionParsing.parseISO),
            type: type,
            payload: envelope["payload"] ?? .object([:])
        )
    }
}
