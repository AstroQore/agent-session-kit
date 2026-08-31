import Foundation

/// What a session is doing right now, as a board would show it.
///
/// This is derived state: it is a pure function of the events seen so far,
/// computed by ``SessionStateReducer``, and nothing constructs it by hand
/// except tests. The cases are chosen for what a person watching several
/// agents at once needs to tell apart at a glance — above all, *is anyone
/// waiting on me?*
public enum SessionState: Hashable, Codable, Sendable {
    /// The turn is closed and nothing is outstanding.
    case idle
    /// The model is reasoning or streaming, with no tool call open.
    case thinking
    /// A tool call is open. `name` is the harness's raw tool name, because
    /// that is what a person recognises in their own terminal.
    case toolCalling(name: String)
    /// A tool call that mutates the working tree is open. Called out
    /// separately from ``toolCalling(name:)`` because it is the one activity
    /// a person may want to interrupt.
    case writingFile(path: String?)
    /// One or more child sessions are running and the parent is waiting on
    /// them.
    case delegating(children: Int)
    /// Blocked on a person. The one state that means the agent will make no
    /// further progress until someone looks at it.
    case waitingPermission(tool: String?)
    /// The session is over.
    case ended(reason: SessionEndReason)

    /// `true` for every state but ``idle`` and ``ended(reason:)`` — that is,
    /// whenever the harness is expected to produce more events on its own.
    public var isActive: Bool {
        switch self {
        case .idle, .ended: false
        case .thinking, .toolCalling, .writingFile, .delegating, .waitingPermission: true
        }
    }

    /// A short human-facing label, suitable for a status column.
    public var label: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .toolCalling(let name): "Tool: \(name)"
        case .writingFile: "Writing file"
        case .delegating(let children): "Delegating (\(children))"
        case .waitingPermission: "Waiting for permission"
        case .ended: "Ended"
        }
    }

    /// Board ordering: the state that most needs a person comes first.
    ///
    /// `waitingPermission` < `delegating` < `writingFile` < `toolCalling` <
    /// `thinking` < `idle` < `ended`. Blocked sessions sort to the top
    /// because they are the only ones that will never resolve themselves;
    /// finished ones sink because they never will either, but nobody has to
    /// do anything about it.
    ///
    /// Rank alone is not a total order — two `toolCalling` sessions tie —
    /// so a sort should break ties on something stable such as
    /// ``SessionSnapshot/lastEventAt``.
    public var sortRank: Int {
        switch self {
        case .waitingPermission: 0
        case .delegating: 1
        case .writingFile: 2
        case .toolCalling: 3
        case .thinking: 4
        case .idle: 5
        case .ended: 6
        }
    }

    /// `true` when the session has ended, whatever the reason.
    public var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }
}
