import AgentSessionKit
import Foundation

/// Where one message sits in the blob graph: the blob it was found in, and
/// its index among the messages that blob carries.
///
/// A reference rather than the message itself, because the two questions a
/// tailer asks are answered at different costs. "What is in this conversation,
/// in order" needs only the graph's shape — a byte-level look at each blob,
/// no JSON. "What does this message say" needs a parse, and after a restart
/// only the handful of messages past the persisted anchor need one.
///
/// ``anchor`` is that persisted position. It is stable because the graph is
/// content-addressed: a blob's id is a hash of its bytes, so a message that
/// has been written can never move, change, or be renumbered within its blob.
public struct CursorMessageRef: Hashable, Sendable {
    /// The `blobs.id` the message was found in.
    public let blobID: String
    /// Index among the messages inside that blob. `0` for a blob that *is* a
    /// message; the nth inline message for a node that carries several.
    public let partIndex: Int

    /// Creates a reference.
    public init(blobID: String, partIndex: Int = 0) {
        self.blobID = blobID
        self.partIndex = partIndex
    }

    /// The compact string form a cursor persists: `"<blob id>.<index>"`.
    ///
    /// Blob ids are hex, so `.` cannot occur inside one and the split is
    /// unambiguous.
    public var anchor: String { "\(blobID).\(partIndex)" }
}

/// One piece of a message's `content` array.
///
/// Cursor's parts are named by a `type` string and the set grows between
/// releases, so anything unrecognised keeps its name in ``other(type:)``
/// rather than being dropped silently or guessed into a case it does not
/// belong in.
public enum CursorContentPart: Hashable, Sendable {
    /// `{"type":"text","text":…}` — a prompt or a reply.
    case text(String)
    /// `{"type":"reasoning",…}` — the model's private scratch work. Only its
    /// existence is reported; the text never leaves the store.
    case reasoning
    /// `{"type":"tool-call","toolCallId":…,"toolName":…,"args"|"input":{…}}`.
    case toolCall(id: String, name: String, arguments: [String: String])
    /// `{"type":"tool-result","toolCallId":…,"result"|"output":…}`.
    case toolResult(id: String, isError: Bool, text: String)
    /// A part type this vintage of the adapter does not know.
    case other(type: String)
}

/// One decoded message out of a Cursor store.
public struct CursorMessage: Hashable, Sendable {
    /// Where it was found, and the anchor a cursor persists.
    public let ref: CursorMessageRef
    /// `"user"`, `"assistant"`, `"tool"`, `"system"`, or whatever else the
    /// store said, verbatim.
    public let role: String
    /// The message's content parts, in order.
    public let parts: [CursorContentPart]
    /// The model that produced it, from `providerOptions.cursor.modelName` on
    /// one of its parts. `nil` for user turns and for short conversations
    /// Cursor never stamped.
    public let model: String?
    /// The message's own timestamp, when one could be established — from a
    /// metadata field, or from the `<timestamp>` header Cursor prefixes a
    /// user prompt with. `nil` means the caller should use its own clock.
    public let timestamp: Date?

    /// Creates a message.
    public init(
        ref: CursorMessageRef,
        role: String,
        parts: [CursorContentPart],
        model: String? = nil,
        timestamp: Date? = nil
    ) {
        self.ref = ref
        self.role = role
        self.parts = parts
        self.model = model
        self.timestamp = timestamp
    }

    /// Every `text` part, joined. A prompt with an attachment arrives as
    /// several parts and only the text half is what a person typed.
    public var plainText: String {
        parts.compactMap { part -> String? in
            guard case let .text(text) = part else { return nil }
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
    }
}

// MARK: - Decoding

extension CursorMessage {
    /// Keys of a tool call's arguments that are worth keeping.
    ///
    /// A whitelist for the same reason Claude Code's transcript record has
    /// one: an `edit_file` call carries the whole new file body in its
    /// arguments, and a tool call's `target` is a path, not a patch. Only
    /// scalars are kept, and only from these keys.
    static let toolArgumentKeys: Set<String> = [
        "command", "cmd", "script",
        "path", "file_path", "filePath", "target_file", "targetFile",
        "relative_workspace_path", "dir_path", "directory", "file", "notebook_path",
        "query", "pattern", "glob_pattern", "search_term", "regex",
        "url", "uri",
        "description", "explanation", "name", "server", "tool",
        "agent", "subagent_type", "agentType"
    ]

    /// Parses one message object.
    ///
    /// Returns `nil` when the object has no `role`, which is how a node blob
    /// or a fragment of something else is told apart from a message.
    static func decode(_ object: [String: Any], ref: CursorMessageRef) -> CursorMessage? {
        guard let role = SessionParsing.string(object["role"]) else { return nil }
        let content = object["content"]
        var parts: [CursorContentPart] = []
        var model: String?

        if let text = content as? String {
            if !text.isEmpty { parts.append(.text(text)) }
        } else if let array = content as? [[String: Any]] {
            for part in array {
                if model == nil { model = modelName(in: part) }
                if let decoded = decodePart(part) { parts.append(decoded) }
            }
        }

        let timestamp = self.timestamp(of: object)
            ?? parts.lazy.compactMap { part -> Date? in
                guard case let .text(text) = part else { return nil }
                return CursorPromptText.timestamp(in: text)
            }.first

        return CursorMessage(ref: ref, role: role, parts: parts, model: model, timestamp: timestamp)
    }

    private static func decodePart(_ part: [String: Any]) -> CursorContentPart? {
        switch SessionParsing.string(part["type"]) {
        case "text":
            guard let text = part["text"] as? String, !text.isEmpty else { return nil }
            return .text(text)

        case "reasoning", "redacted-reasoning", "reasoning-signature":
            return .reasoning

        case "tool-call", "tool_call", "tool-invocation":
            guard let id = SessionParsing.firstString(part["toolCallId"], part["tool_call_id"], part["id"])
            else { return nil }
            let name = SessionParsing.firstString(part["toolName"], part["tool_name"], part["name"])
                ?? "unknown"
            let raw = (part["args"] ?? part["input"] ?? part["arguments"]) as? [String: Any] ?? [:]
            return .toolCall(id: id, name: name, arguments: arguments(raw))

        case "tool-result", "tool_result":
            guard let id = SessionParsing.firstString(part["toolCallId"], part["tool_call_id"], part["id"])
            else { return nil }
            let payload = part["result"] ?? part["output"] ?? part["content"]
            return .toolResult(id: id, isError: isError(part, payload: payload), text: resultText(payload))

        case let other?:
            return .other(type: other)

        case nil:
            return nil
        }
    }

    /// The whitelisted, stringified subset of a tool call's arguments.
    static func arguments(_ raw: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in raw where toolArgumentKeys.contains(key) {
            if let text = SessionParsing.string(value) {
                out[key] = text
            } else if let number = value as? NSNumber {
                out[key] = number.stringValue
            }
        }
        return out
    }

    /// Whether a `tool-result` part reports a failure.
    ///
    /// Three shapes seen in the wild — a sibling `isError`, an `error` key on
    /// the payload object, and a payload that is only `{"error": …}` — and a
    /// missing flag means success, never "unknown". A tool call that finished
    /// is the common case and a false red mark is worse than a missed one.
    static func isError(_ part: [String: Any], payload: Any?) -> Bool {
        if SessionParsing.bool(part["isError"]) || SessionParsing.bool(part["is_error"]) { return true }
        if SessionParsing.string(part["state"])?.lowercased().contains("error") == true { return true }
        guard let object = payload as? [String: Any] else { return false }
        if SessionParsing.bool(object["isError"]) || SessionParsing.bool(object["is_error"]) { return true }
        return object["error"] != nil
    }

    /// A tool result's payload rendered as text, for the searchable body.
    ///
    /// A string stays a string; anything else is re-serialised compactly, so
    /// a structured result is still indexable without the mapper needing to
    /// know the shape of every tool Cursor ships.
    static func resultText(_ payload: Any?) -> String {
        if let text = payload as? String { return text }
        guard let payload else { return "" }
        if let parts = payload as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `providerOptions.cursor.modelName` — Cursor stamps the model on the
    /// assistant *part*, not on the message.
    static func modelName(in part: [String: Any]) -> String? {
        guard let options = part["providerOptions"] as? [String: Any],
              let cursor = options["cursor"] as? [String: Any]
        else { return nil }
        return SessionParsing.string(cursor["modelName"])
    }

    /// A message-level timestamp, under any of the names a Cursor vintage
    /// has used for one.
    static func timestamp(of object: [String: Any]) -> Date? {
        SessionParsing.firstDate(
            object["timestamp"], object["createdAt"], object["createdAtMs"],
            object["ts"], object["time"]
        )
    }
}

/// The envelope Cursor wraps a person's prompt in, and how to get the prompt
/// back out of it.
///
/// A user message's text is not what anybody typed. Cursor prefixes a
/// timestamp element and wraps the prompt itself:
///
/// ```text
/// <timestamp>Tuesday, Aug 18, 2026, 5:39 PM (UTC+8)</timestamp>
/// <user_query>
/// add a test for the reducer
/// </user_query>
/// ```
///
/// Both halves are useful: the wrapper has to come off before a preview is
/// worth showing, and the timestamp is the only per-turn clock the store
/// carries — the protobuf nodes' own millisecond field is the same value for
/// every node in a conversation, so it dates the conversation and not the
/// turn.
public enum CursorPromptText {
    /// The text a person actually typed.
    ///
    /// Strips the `<timestamp>` element and unwraps `<user_query>`. Anything
    /// outside those elements is kept — an attachment preamble is part of the
    /// prompt as far as this package is concerned — and text with no wrapper
    /// at all is returned unchanged, which is what an IDE-side message looks
    /// like.
    public static func body(_ raw: String) -> String {
        var text = raw
        if let range = element(named: "timestamp", in: text) {
            text.removeSubrange(range.outer)
        }
        if let range = element(named: "user_query", in: text) {
            text = String(text[range.inner])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The instant in the `<timestamp>` header, when there is one and it
    /// parses.
    public static func timestamp(in raw: String) -> Date? {
        guard let range = element(named: "timestamp", in: raw) else { return nil }
        return parse(String(raw[range.inner]))
    }

    /// `Tuesday, Aug 18, 2026, 5:39 PM (UTC+8)` → an instant.
    ///
    /// Parsed by hand rather than with a `DateFormatter`, for two reasons.
    /// `(UTC+8)` is not an ISO-8601 offset — `X` wants `+08` or `Z` and
    /// rejects a single-digit hour — and a formatter is a reference type that
    /// a `Sendable` static cannot hold, so the alternative would be building
    /// one per prompt. The month and weekday names are English whatever the
    /// system language is, because Cursor writes the header itself.
    ///
    /// Returns `nil` on anything that does not match, which the caller reads
    /// as "no timestamp" and answers with its own clock.
    public static func parse(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var offset: TimeInterval = 0

        if let open = text.range(of: "(UTC", options: .backwards),
           let close = text.range(of: ")", options: .backwards),
           open.upperBound <= close.lowerBound {
            offset = zoneOffset(String(text[open.upperBound..<close.lowerBound]))
            text = String(text[text.startIndex..<open.lowerBound])
        }

        var fields = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // The weekday is decoration: it carries no information the date does
        // not, and dropping it also covers a vintage that stops writing it.
        if let first = fields.first, !first.contains(where: \.isNumber) { fields.removeFirst() }
        guard fields.count >= 3 else { return nil }

        let monthDay = fields[0].split(separator: " ")
        guard monthDay.count == 2,
              let month = monthNumber(String(monthDay[0])),
              let day = Int(monthDay[1]),
              let year = Int(fields[1]),
              let clock = clock(fields[2])
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = clock.hour
        components.minute = clock.minute
        components.second = clock.second

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = calendar.date(from: components) else { return nil }
        return date.addingTimeInterval(-offset)
    }

    /// `Aug`, `august`, `AUGUST` → 8. Prefix matching, so both the
    /// abbreviated and the spelled-out name resolve.
    static func monthNumber(_ name: String) -> Int? {
        let lowered = name.lowercased()
        guard lowered.count >= 3 else { return nil }
        let prefix = String(lowered.prefix(3))
        guard let index = monthPrefixes.firstIndex(of: prefix) else { return nil }
        return index + 1
    }

    private static let monthPrefixes = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
    ]

    /// `5:39 PM`, `17:39`, `5:39:07 AM` → hour, minute, second on a 24-hour
    /// clock.
    static func clock(_ raw: String) -> (hour: Int, minute: Int, second: Int)? {
        let fields = raw.split(separator: " ")
        guard let time = fields.first else { return nil }
        let digits = time.split(separator: ":")
        guard digits.count >= 2, var hour = Int(digits[0]), let minute = Int(digits[1]) else {
            return nil
        }
        let second = digits.count > 2 ? Int(digits[2]) ?? 0 : 0

        switch fields.count > 1 ? fields[1].uppercased() : "" {
        case "PM" where hour < 12: hour += 12
        case "AM" where hour == 12: hour = 0
        default: break
        }
        guard (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else {
            return nil
        }
        return (hour, minute, second)
    }

    /// `+8`, `-05:30`, `+0800`, or `""` → seconds east of UTC.
    static func zoneOffset(_ raw: String) -> TimeInterval {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "+" || first == "-" else { return 0 }
        let sign: TimeInterval = first == "-" ? -1 : 1
        let digits = trimmed.dropFirst()
        let hours: Int
        let minutes: Int
        if let colon = digits.firstIndex(of: ":") {
            hours = Int(digits[digits.startIndex..<colon]) ?? 0
            minutes = Int(digits[digits.index(after: colon)...]) ?? 0
        } else if digits.count == 4, let value = Int(digits) {
            hours = value / 100
            minutes = value % 100
        } else {
            hours = Int(digits) ?? 0
            minutes = 0
        }
        return sign * TimeInterval(hours * 3600 + minutes * 60)
    }

    /// The ranges of `<name>…</name>` in `text`: the whole element, and its
    /// contents.
    private static func element(named name: String, in text: String)
        -> (outer: Range<String.Index>, inner: Range<String.Index>)? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return (open.lowerBound..<close.upperBound, open.upperBound..<close.lowerBound)
    }
}
