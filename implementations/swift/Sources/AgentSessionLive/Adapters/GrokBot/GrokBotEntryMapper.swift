import AgentSessionKit
import Foundation

/// Turns one ``GrokBotEntry`` into events.
///
/// Pure and total: an entry in, zero or more events out, no clock and no
/// state of its own. Everything about *when* an entry is read — whether it is
/// new, whether it stopped streaming since the last poll, whether a turn
/// closed — belongs to ``GrokBotTranscriptTailer`` and is deliberately not
/// here.
///
/// ## What the store cannot answer
///
/// There are no tool calls, no model, no token counts, and no working
/// directory in this format, so `toolCallStarted`, `usage`, and a `cwd` never
/// come out of it. What is left is the conversation itself and a thin band of
/// client bookkeeping — renames, automations, widgets, attachments — which
/// rides in ``AgentEventKind/note(_:)`` rather than pretending to be a turn.
public enum GrokBotEntryMapper {
    /// Characters a preview keeps. Matches every other adapter.
    public static let previewLimit = 200

    /// The events one entry contributes.
    ///
    /// - Parameters:
    ///   - entry: The entry, as the client last wrote it.
    ///   - session: The conversation it belongs to.
    ///   - sourcePath: The replica file, for ``RawRef``.
    ///   - index: The entry's position in the array, which is the only
    ///     locator this store offers — there are no byte offsets into a file
    ///     that is rewritten whole.
    ///   - now: The observation clock, so a cold-start replay of a week-old
    ///     conversation is not stamped as fresh activity.
    public static func events(
        for entry: GrokBotEntry,
        session: SessionKey,
        sourcePath: String,
        index: Int,
        now: Date
    ) -> [AgentEvent] {
        let raw = RawRef(path: sourcePath, byteOffset: nil, rowID: Int64(index), lineNumber: nil)
        let stamp = entry.timestamp ?? now
        func event(_ kind: AgentEventKind) -> AgentEvent {
            AgentEvent(session: session, timestamp: stamp, observedAt: now, kind: kind, raw: raw)
        }

        // A streaming entry is a reply being written *right now*. Its text is
        // a prefix of what the entry will hold a second later, so emitting it
        // as `assistantText` would put a half-sentence on a board and then
        // never correct it. The entry is read again when the client clears
        // the flag, and that read is the one that carries the words.
        if entry.isStreaming { return [event(.thinking)] }

        /// The preview event plus the searchable body behind it, in that
        /// order: the board reads the first and a full-text index the second,
        /// and a body without its state event would be invisible.
        func spoken(_ text: String, role: TextBodyRole) -> [AgentEvent] {
            let preview = EventText.preview(text, max: previewLimit)
            let state: AgentEventKind = role == .user
                ? .userPrompt(preview: preview)
                : .assistantText(preview: preview)
            var out = [event(state)]
            if let body = body(text) {
                out.append(event(.textBody(role: role, text: body, toolCallID: nil)))
            }
            return out
        }

        switch entry.kind {
        case .sendMessage:
            guard !entry.text.isEmpty else {
                return note(entry).map { [event(.note($0))] } ?? []
            }
            return spoken(entry.text, role: .assistant)

        case .message:
            switch entry.role {
            case .user:
                // Inbound, whether it came from the person or from another
                // bot. The sender's name is prefixed because the event model
                // has no case for "somebody else's agent", and because the
                // reply is owed either way.
                return spoken(prefixed(entry.text, with: entry.partner, arrow: false), role: .user)
            case .assistant:
                guard !entry.text.isEmpty else { return [] }
                return spoken(
                    prefixed(entry.text, with: entry.partner, arrow: true), role: .assistant)
            case nil:
                return []
            }

        case .event, .userAttachment:
            return note(entry).map { [event(.note($0))] } ?? []
        }
    }

    /// The one-line description of an entry that is not conversation, or
    /// `nil` when there is nothing worth saying.
    ///
    /// Everything here is display-only — the reducer treats a note as a
    /// heartbeat — so it is kept short and it never carries a local path. An
    /// attachment's `file_path` points at the person's own disk and has no
    /// meaning to anything reading these events.
    static func note(_ entry: GrokBotEntry) -> String? {
        switch entry.kind {
        case .userAttachment:
            let name = entry.fileName.map { EventText.preview($0, max: fileNameLimit) }
            return name.map { "attachment: \($0)" } ?? "attachment"

        case .event:
            let subject = entry.eventSubject.map { EventText.preview($0, max: nameLimit) }
            switch entry.eventType {
            case "name-changed":
                return subject.map { "renamed to \($0)" } ?? "renamed"
            case "automation-changed":
                return subject.map { "automation changed: \($0)" } ?? "automation changed"
            case let other?:
                return EventText.preview(other, max: nameLimit)
            case nil:
                return nil
            }

        case .sendMessage:
            // A turn with no text: the client rendered a widget, asked for a
            // secret, or attached a file. It happened, and a board should say
            // so, but there is nothing to quote.
            switch entry.payloadType {
            case "widget": return "widget"
            case "secret-request": return "secret requested"
            case "attachment": return "attachment"
            case "auto-review-approval": return "auto-review approval"
            case let other?: return EventText.preview(other, max: nameLimit)
            case nil: return nil
            }

        case .message:
            return nil
        }
    }

    /// `Name: …` for an inbound bot turn, `→ Name: …` for an outbound one.
    /// Text with no bot on the other end is its own.
    ///
    /// The same shape `GrokBotSessionAdapter` renders in the transcript, so a
    /// preview on a board and the message in the session list read alike.
    static func prefixed(_ text: String, with name: String?, arrow: Bool) -> String {
        guard let name, !name.isEmpty else { return text }
        let label = EventText.preview(name, max: nameLimit)
        guard !text.isEmpty else { return arrow ? "→ \(label)" : label }
        return (arrow ? "→ " : "") + label + ": " + text
    }

    /// A bot's name in a preview. Long enough for any name the client's own
    /// sidebar shows.
    static let nameLimit = 60
    /// An attached file's name in a note.
    static let fileNameLimit = 80

    /// A full-text body, capped at ``AgentEventKind/textBodyLimit`` bytes on
    /// a character boundary.
    ///
    /// Returns `nil` for an empty string, so a body event is never emitted
    /// with nothing in it.
    public static func body(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.utf8.count > AgentEventKind.textBodyLimit else { return text }
        var out = ""
        var bytes = 0
        for character in text {
            let width = String(character).utf8.count
            if bytes + width > AgentEventKind.textBodyLimit { break }
            out.append(character)
            bytes += width
        }
        return out.isEmpty ? nil : out
    }
}
