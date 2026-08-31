import AgentSessionKit
import Darwin
import Foundation
@testable import AgentSessionLive

// MARK: - The fixture files

/// The synthetic Claude Code transcripts in `Fixtures/claude`.
///
/// Shared by the mapper tests and the adapter tests so both read the same
/// bytes: a mapping the mapper gets right and the tailer gets wrong is the
/// interesting failure, and it only shows up when they are fed identically.
enum ClaudeFixture {
    /// The session id every fixture record carries.
    static let sessionID = "11111111-2222-3333-4444-555555555555"
    /// The agent id of the one subagent transcript.
    static let agentID = "a1b2c3d4e5f60718"
    /// The parent's tool-use id for the `Task` call that spawned it.
    static let toolUseID = "toolu_task01"
    /// Where the fixture session was launched.
    static let cwd = "/Users/example/code/demo"
    /// Where it moved when it entered a worktree, mid-transcript.
    static let worktree = "/Users/example/code/demo/.claude/worktrees/feat+event-mapper"
    /// The branch inside that worktree.
    static let worktreeBranch = "worktree-feat+event-mapper"
    /// The project directory name `cwd` encodes to.
    static let projectDirectory = "-Users-example-code-demo"

    static var directory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/claude")
    }

    static var sessionURL: URL { directory.appendingPathComponent("session.jsonl") }
    static var subagentURL: URL { directory.appendingPathComponent("subagent.jsonl") }
    static var subagentMetaURL: URL { directory.appendingPathComponent("subagent.meta.json") }
    static var sessionPIDURL: URL { directory.appendingPathComponent("session-pid.json") }

    /// Every non-empty line of a fixture, as the tailer would hand it over.
    static func lines(of url: URL) -> [Data] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let bytes = [UInt8](data)
        let slices = bytes.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        return slices.map { Data($0) }
    }

    static var sessionLines: [Data] { lines(of: sessionURL) }
    static var subagentLines: [Data] { lines(of: subagentURL) }

    /// The key the parent transcript is tailed under.
    static var parentKey: SessionKey {
        SessionKey(harness: .claudeCode, sessionID: sessionID)
    }

    /// The key the subagent transcript is tailed under.
    static var childKey: SessionKey {
        SessionKey(harness: .claudeCode, sessionID: "\(sessionID)/agent-\(agentID)")
    }
}

/// A fixed observation clock, so nothing in these tests depends on when the
/// suite runs. Auxiliary records — the ones Claude Code writes with no
/// timestamp at all — are stamped with exactly this.
let claudeNow = Date(timeIntervalSinceReferenceDate: 820_000_000)

// MARK: - Event shapes

extension Array where Element == AgentEvent {
    /// How many events of each kind, keyed by a short label. Comparing whole
    /// dictionaries makes a diff say *which* mapping moved rather than that
    /// some count changed.
    var kindCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for event in self { counts[event.kind.label, default: 0] += 1 }
        return counts
    }

    /// The first non-`nil` result of `transform` over the events' kinds.
    func firstValue<T>(_ transform: (AgentEventKind) -> T?) -> T? {
        for event in self {
            if let value = transform(event.kind) { return value }
        }
        return nil
    }

    /// Every non-`nil` result of `transform` over the events' kinds.
    func values<T>(_ transform: (AgentEventKind) -> T?) -> [T] {
        compactMap { transform($0.kind) }
    }
}

extension AgentEventKind {
    /// A stable short name per case, for count tables.
    var label: String {
        switch self {
        case .sessionStarted: "sessionStarted"
        case .identityUpdated: "identityUpdated"
        case .userPrompt: "userPrompt"
        case .turnStarted: "turnStarted"
        case .thinking: "thinking"
        case .assistantText: "assistantText"
        case .toolCallStarted: "toolCallStarted"
        case .toolCallFinished: "toolCallFinished"
        case .permissionRequested: "permissionRequested"
        case .permissionResolved: "permissionResolved"
        case .subagentStarted: "subagentStarted"
        case .subagentFinished: "subagentFinished"
        case .turnEnded: "turnEnded"
        case .usage: "usage"
        case .contextUsage: "contextUsage"
        case .quota: "quota"
        case .compaction: "compaction"
        case .sessionEnded: "sessionEnded"
        case .liveness: "liveness"
        case .note: "note"
        case .textBody: "textBody"
        }
    }
}

/// One started tool call, flattened for assertions.
struct StartedCall: Hashable {
    let id: String
    let name: String
    let kind: ToolKind
    let target: String?

    init?(_ kind: AgentEventKind) {
        guard case let .toolCallStarted(id, name, toolKind, target) = kind else { return nil }
        self.id = id
        self.name = name
        self.kind = toolKind
        self.target = target
    }
}

/// One finished tool call, flattened for assertions.
struct FinishedCall: Hashable {
    let id: String
    let isError: Bool

    init?(_ kind: AgentEventKind) {
        guard case let .toolCallFinished(id, isError) = kind else { return nil }
        self.id = id
        self.isError = isError
    }
}

/// One text body, flattened for assertions.
struct Body: Hashable {
    let role: TextBodyRole
    let text: String
    let toolCallID: String?

    init?(_ kind: AgentEventKind) {
        guard case let .textBody(role, text, toolCallID) = kind else { return nil }
        self.role = role
        self.text = text
        self.toolCallID = toolCallID
    }
}

func identityPatch(_ kind: AgentEventKind) -> SessionIdentityPatch? {
    guard case let .identityUpdated(patch) = kind else { return nil }
    return patch
}

func usageTotals(_ events: [AgentEvent]) -> (input: Int, output: Int, cached: Int) {
    var totals = (input: 0, output: 0, cached: 0)
    for event in events {
        guard case let .usage(_, input, output, cached) = event.kind else { continue }
        totals.input += input
        totals.output += output
        totals.cached += cached
    }
    return totals
}

// MARK: - A synthetic Claude home

/// Builds the directory layout `ClaudeLiveAdapter` expects, from the flat
/// fixture files.
///
/// The fixtures are stored flat because that is what reads well in a diff; the
/// adapter needs `projects/<encoded cwd>/<session id>.jsonl` with a
/// `<session id>/subagents` beside it, so the shape is assembled here.
struct ClaudeHome {
    let tree: TemporaryTree

    var home: String { tree.path }

    var projectDirectory: URL {
        tree.url
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(ClaudeFixture.projectDirectory)
    }

    var transcriptPath: String {
        projectDirectory.appendingPathComponent("\(ClaudeFixture.sessionID).jsonl").path
    }

    var subagentsDirectory: URL {
        projectDirectory
            .appendingPathComponent(ClaudeFixture.sessionID)
            .appendingPathComponent("subagents")
    }

    var subagentPath: String {
        subagentsDirectory.appendingPathComponent("agent-\(ClaudeFixture.agentID).jsonl").path
    }

    var sessionsDirectory: URL {
        tree.url.appendingPathComponent(".claude/sessions")
    }

    /// Creates the tree.
    ///
    /// - Parameter withSubagent: Whether to lay down the child transcript and
    ///   its meta file.
    init(_ label: String = #function, withSubagent: Bool = true) {
        tree = TemporaryTree(label)
        let manager = FileManager.default
        try? manager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try? manager.copyItem(at: ClaudeFixture.sessionURL, to: URL(fileURLWithPath: transcriptPath))
        Self.touch(transcriptPath)
        guard withSubagent else { return }
        try? manager.createDirectory(at: subagentsDirectory, withIntermediateDirectories: true)
        try? manager.copyItem(at: ClaudeFixture.subagentURL, to: URL(fileURLWithPath: subagentPath))
        Self.touch(subagentPath)
        try? manager.copyItem(
            at: ClaudeFixture.subagentMetaURL,
            to: subagentsDirectory.appendingPathComponent("agent-\(ClaudeFixture.agentID).meta.json")
        )
    }

    /// `copyItem` preserves the source's modification date, and the fixture's
    /// date is whenever the checkout happened — older than `deadAfter` on any
    /// checkout more than ten minutes old, which turns "freshly written" into
    /// "stale" and flips the liveness verdict. Stamp the copies with now so the
    /// tests describe the file, not the clone.
    private static func touch(_ path: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
    }

    /// Writes a `~/.claude/sessions/<pid>.json` naming this session.
    ///
    /// `procStart` is rendered the way Claude Code renders it — `ctime(3)`
    /// text in UTC — so a test that passes here would fail if the parser
    /// assumed local time, which is the whole point of writing it this way
    /// rather than reusing the fixture's string.
    @discardableResult
    func writeSessionEntry(
        pid: pid_t,
        procStart: Date?,
        sessionID: String = ClaudeFixture.sessionID,
        socketPath: String? = nil
    ) -> URL {
        var object: [String: Any] = [
            "pid": Int(pid),
            "sessionId": sessionID,
            "cwd": ClaudeFixture.cwd,
            "startedAt": 1_767_603_600_000,
            "version": "2.1.229",
            "kind": "interactive",
            "entrypoint": "claude-desktop",
            "name": "demo-01"
        ]
        if let procStart { object["procStart"] = ctimeUTC(procStart) }
        if let socketPath { object["messagingSocketPath"] = socketPath }

        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let url = sessionsDirectory.appendingPathComponent("\(pid).json")
        try? JSONSerialization.data(withJSONObject: object).write(to: url)
        // The credential file that sits beside every entry. Present so the
        // "only `.json` is read" rule is exercised rather than assumed.
        try? Data("not a session".utf8).write(
            to: sessionsDirectory.appendingPathComponent("\(pid).deadbeef.key")
        )
        return url
    }

    /// Backdates the transcript so the "quiet for too long" branch can be
    /// driven without waiting.
    func backdateTranscript(by seconds: TimeInterval) {
        let when = Date().addingTimeInterval(-seconds)
        try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: transcriptPath)
    }
}

/// Renders a date as `ctime(3)` text in UTC, which is what Claude Code writes
/// into `procStart`.
func ctimeUTC(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return formatter.string(from: date)
}
