import Foundation

/// Turns source text into something an event may carry.
///
/// Every adapter runs user prompts and assistant prose through
/// ``preview(_:max:)`` before putting them in an ``AgentEvent``. Two reasons,
/// and the second is the important one:
///
/// - A board renders one line per session. A 40 KB prompt costs the same to
///   store and stream as the 200 characters that will actually be shown.
/// - Events are persisted, logged, and handed to a UI. The less of a
///   transcript that leaves the file it was written in, the smaller the
///   surface for the most personal data on the machine to escape through.
public enum EventText {
    /// Collapses whitespace and truncates, returning at most `max` characters.
    ///
    /// Runs of any whitespace — including the newlines that make a prompt
    /// tall and the tabs that make it wide — collapse to a single space, and
    /// the result is trimmed. When it still does not fit, it is cut and an
    /// ellipsis takes the last character, so the returned string never
    /// exceeds `max`. Counting is by `Character`, so a truncated emoji or a
    /// combining sequence is never split into mojibake.
    ///
    /// `max <= 0` yields `""`.
    public static func preview(_ s: String, max: Int = 200) -> String {
        guard max > 0 else { return "" }
        let collapsed = collapseWhitespace(s)
        guard collapsed.count > max else { return collapsed }
        return String(collapsed.prefix(max - 1)) + "…"
    }

    /// Collapses every run of whitespace to one space and trims the ends.
    public static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var pendingSpace = false
        for character in s {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
        }
        return out
    }
}
