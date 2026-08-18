import AgentSessionKit
import Foundation

/// Turns one line of Cursor's thin transcript into ``AgentEvent``s.
///
/// ## The file
///
/// `~/.cursor/projects/<cwd slug>/agent-transcripts/<agent id>/<agent id>.jsonl`,
/// written only when a `cursor-agent` CLI drove the session. Three line
/// shapes, and nothing else:
///
/// ```jsonl
/// {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>…</timestamp>\n<user_query>\n…\n</user_query>"}]}}
/// {"role":"assistant","message":{"content":[{"type":"text","text":"…"}]}}
/// {"type":"turn_ended","status":"success"}
/// ```
///
/// It is append-only and cheap to tail, and it is the only place a turn's
/// *end* is recorded at all — the store's graph says what was said, never that
/// the harness stopped saying it.
///
/// ## What it owns, and what it does not
///
/// | Fact | Source |
/// | --- | --- |
/// | `userPrompt` — the turn opener | **this file**, when it exists |
/// | `turnEnded` | **this file**; the store has no equivalent |
/// | `textBody(.user, …)` — the prompt in full | the store |
/// | assistant prose, reasoning, tool calls and results | the store |
///
/// The division exists because the reducer counts a turn per
/// ``AgentEventKind/userPrompt(preview:)``: emitting it from both sources
/// would double every turn on the board. The thin transcript wins because it
/// is where a turn is *bounded* — it records the end — so both halves of a
/// turn come from one clock. Everything with any detail in it stays with the
/// store, which has the tool calls this file does not record at all.
///
/// A `role: assistant` line is deliberately dropped. Its text is the same
/// reply the store carries, and taking it here would double every assistant
/// message on a board.
///
/// ``AgentEventKind/turnStarted`` is not emitted either. `userPrompt` already
/// opens a turn in ``SessionStateReducer``, and emitting both in one poll
/// counts the turn twice.
public enum CursorThinTranscriptMapper: Sendable {
    /// Characters kept in a `userPrompt` preview.
    public static let previewLimit = 200

    /// Maps one JSONL line.
    ///
    /// - Parameters:
    ///   - data: The raw bytes of one line, newline excluded.
    ///   - session: The key events are attributed to.
    ///   - now: The observation clock. Becomes ``AgentEvent/observedAt`` on
    ///     every event, and ``AgentEvent/timestamp`` on a line with no
    ///     `<timestamp>` header — which is every line but a prompt.
    public static func events(from data: Data, session: SessionKey, now: Date) -> [AgentEvent] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        return events(for: object, session: session, now: now)
    }

    /// Maps an already-parsed line.
    public static func events(
        for object: [String: Any],
        session: SessionKey,
        now: Date
    ) -> [AgentEvent] {
        if let type = SessionParsing.string(object["type"]), type == "turn_ended" {
            let reason = self.reason(SessionParsing.string(object["status"]))
            return [AgentEvent(session: session, timestamp: now, observedAt: now,
                               kind: .turnEnded(reason: reason))]
        }

        guard SessionParsing.string(object["role"]) == "user" else {
            // `assistant` lines are the store's to report, and an unknown
            // line shape is not a fact this package has a case for.
            return []
        }

        let raw = text(in: object["message"])
        let body = CursorPromptText.body(raw)
        guard !body.isEmpty else { return [] }
        let timestamp = CursorPromptText.timestamp(in: raw) ?? now
        return [
            AgentEvent(
                session: session,
                timestamp: timestamp,
                observedAt: now,
                kind: .userPrompt(preview: EventText.preview(body, max: previewLimit))
            )
        ]
    }

    /// `success` → complete, a failure → error, an interruption → aborted, and
    /// anything the next Cursor release invents → unknown rather than a guess.
    static func reason(_ status: String?) -> TurnEndReason {
        switch status?.lowercased() {
        case "success", "completed", "complete", "done", "ok": .complete
        case "error", "failed", "failure", "errored": .error
        case "aborted", "cancelled", "canceled", "interrupted", "stopped": .aborted
        default: .unknown
        }
    }

    /// `message.content[].text`, joined. Tolerates a `content` that is a plain
    /// string, which is how a one-part message is sometimes written.
    static func text(in message: Any?) -> String {
        guard let object = message as? [String: Any] else {
            return SessionParsing.string(message) ?? ""
        }
        let content = object["content"]
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            guard part["type"] as? String == "text", let text = part["text"] as? String,
                  !text.isEmpty
            else { return nil }
            return text
        }.joined(separator: "\n")
    }
}
