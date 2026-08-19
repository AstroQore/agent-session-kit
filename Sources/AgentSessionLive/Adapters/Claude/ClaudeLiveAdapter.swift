import AgentSessionKit
import Foundation
import Synchronization

/// Reads Claude Code's transcripts live.
///
/// ## The store
///
/// ```text
/// ~/.claude/projects/<encoded cwd>/
///   <session id>.jsonl                       the session's timeline
///   <session id>/subagents/
///     agent-<agent id>.jsonl                 one child session each
///     agent-<agent id>.meta.json             agentType, description, toolUseId
///   <session id>/tool-results/<id>.txt       spilled large tool output
/// ~/.claude/sessions/
///   <pid>.json                               pid ↔ session ↔ cwd, while running
///   <pid>.<hex>.key                          socket credential; never read
/// ~/.config/claude/projects/…                the alternate root some installs use
/// ```
///
/// Every line of a transcript is a JSON object with a `type`, and
/// ``ClaudeRecordMapper`` owns the translation from those to
/// ``AgentEvent``s. This type owns everything around it: which files are worth
/// tailing, what can be known about a session before reading it, whether its
/// process is still there, and how a subagent gets attached to its parent.
///
/// ## Discovery
///
/// A transcript is worth tailing when it was written to since `activeSince`,
/// **or** when `~/.claude/sessions` says a process is driving it. The second
/// half is not redundant: a session that has been sitting at a prompt for an
/// hour has an hour-old transcript and is the most live thing on the machine,
/// and a cutoff alone would drop exactly the sessions a board exists to show.
///
/// Subagent transcripts are discovered alongside their parent and returned as
/// sources of their own, keyed `"<session id>/agent-<agent id>"`. They are
/// real sessions — they think, call tools, and burn tokens — and a board that
/// folded them into the parent would show one busy row where five things are
/// happening.
///
/// ## What discovery knows before reading anything
///
/// In order of how much it can be trusted:
///
/// 1. `~/.claude/sessions/<pid>.json` — exact `cwd`, `pid`, `procStart`,
///    `entrypoint`, and the harness's own name for the session.
/// 2. The first line of the transcript — exact `cwd`, `gitBranch`, `version`,
///    `model`. One bounded read of the head, not a parse of the file.
/// 3. ``ClaudeProjectPath`` — a guess from the directory name, and the reason
///    that type carries a warning.
///
/// ## Liveness
///
/// Claude Code holds no lock on its transcript — `lsof` shows nothing, because
/// it opens the file per write — so the transcript itself says nothing about
/// whether anyone is home. `~/.claude/sessions` does: the entry appears when
/// the process starts and is removed when it exits. So the probe is
///
/// - an entry names this session and its pid is in the process table, with a
///   matching start time → **alive**;
/// - an entry names it but that pid is gone, or is a different process wearing
///   a recycled pid → **dead**;
/// - no entry, and the transcript has been quiet for longer than
///   ``deadAfter`` → **dead**;
/// - no entry, but the transcript was touched recently → **unknown**. A
///   session mid-`--resume` has no entry for a moment, and calling it dead
///   would flicker every row that reconnects.
public struct ClaudeLiveAdapter: SourceAdapter {
    public let harness: Harness = .claudeCode

    /// How quiet a transcript with no `~/.claude/sessions` entry has to be
    /// before absence of an entry is read as death.
    ///
    /// Ten minutes, because the failure mode on each side is asymmetric: too
    /// short and a session whose entry was missed flickers dead and back, too
    /// long and a crashed session lingers on a board. A lingering row is the
    /// cheaper mistake.
    public let deadAfter: TimeInterval

    /// How far a process's start time may differ from the entry's `procStart`
    /// before the pid is treated as recycled. `procStart` has one-second
    /// resolution, so two seconds is one tick of slack.
    public let startTolerance: TimeInterval

    /// The variant every subagent identity carries, so a host can tell a
    /// delegated session from one a person started without parsing its key.
    public static let subagentVariant = "subagent"

    /// The prefix of a subagent transcript's file name.
    public static let subagentFilePrefix = "agent-"

    /// Separates the parent session id from the agent id inside a child's
    /// ``SessionKey/sessionID``.
    public static let subagentKeySeparator = "/"

    private let linker: ClaudeSubagentLinker
    private let clock: @Sendable () -> Date

    /// Creates an adapter.
    ///
    /// - Parameters:
    ///   - deadAfter: See ``deadAfter``.
    ///   - startTolerance: See ``startTolerance``.
    ///   - linker: The parent/child join. One adapter owns one; passing your
    ///     own is how a test drives it directly.
    ///   - clock: The observation clock, injected so the suite does not have
    ///     to wait for real time to pass.
    public init(
        deadAfter: TimeInterval = 600,
        startTolerance: TimeInterval = 2,
        linker: ClaudeSubagentLinker = ClaudeSubagentLinker(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.deadAfter = deadAfter
        self.startTolerance = startTolerance
        self.linker = linker
        self.clock = clock
    }

    /// The parent/child join this adapter announces subagents through.
    public var subagentLinker: ClaudeSubagentLinker { linker }

    // MARK: - Roots

    public func watchRoots(home: String) -> [URL] {
        let base = URL(fileURLWithPath: home)
        return [
            base.appendingPathComponent(".claude/projects"),
            // Watched even though nothing is tailed from it: an entry
            // appearing here is a session starting, and it is the only
            // notification of that which arrives before the first transcript
            // line does.
            base.appendingPathComponent(".claude/sessions"),
            base.appendingPathComponent(".config/claude/projects")
        ]
    }

    /// The project roots transcripts actually live under.
    public static func projectRoots(home: String) -> [URL] {
        let base = URL(fileURLWithPath: home)
        return [
            base.appendingPathComponent(".claude/projects"),
            base.appendingPathComponent(".config/claude/projects")
        ]
    }

    // MARK: - Discovery

    public func discover(home: String, activeSince: Date) async throws -> [SessionSource] {
        let entries = ClaudeSessionsDirectory.read(home: home)
        let builder = ClaudeSourceBuilder(harness: harness, linker: linker)
        var sources: [SessionSource] = []

        for root in Self.projectRoots(home: home) {
            for projectDirectory in ClaudeSourceBuilder.subdirectories(of: root) {
                sources.append(contentsOf: builder.sources(
                    in: projectDirectory, entries: entries, activeSince: activeSince
                ))
            }
        }
        return sources
    }

    // MARK: - Tailing

    public func makeTailer(_ source: SessionSource, cursor: SourceCursor?) throws -> any SessionTailer {
        ClaudeSessionTailer(source: source, cursor: cursor, linker: linker, clock: clock)
    }

    // MARK: - Liveness

    /// A transcript (`<project>/<session>.jsonl`), a child transcript
    /// (`…/subagents/agent-<id>.jsonl`), or a `sessions/<pid>.json` entry —
    /// the three files whose appearance means a session started. Everything
    /// else Claude Code writes under its roots (`tool-results/`, `.meta.json`,
    /// `.key` files) is a sidecar of a session already known.
    public func mightBeSessionFile(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        if name.hasSuffix(".jsonl") {
            if parent == "subagents" { return name.hasPrefix(Self.subagentFilePrefix) }
            return !name.hasPrefix(".")
        }
        return parent == "sessions" && name.hasSuffix(".json")
    }


    public func probeLiveness(
        _ identity: SessionIdentity,
        table: any ProcessTableReading,
        home: String
    ) -> LivenessHint {
        // A subagent has no process of its own; it runs inside its parent's,
        // so it is exactly as alive as the session it was spawned from.
        let rootSessionID = Self.rootSessionID(of: identity.key)
        let entries = ClaudeSessionsDirectory.read(home: home)

        guard let entry = ClaudeSessionsDirectory.session(for: rootSessionID, in: entries) else {
            guard let age = LockFileProbe.ageOfLastWrite(path: identity.sourcePath) else {
                return .unknown("no ~/.claude/sessions entry, and the transcript could not be stat'd")
            }
            guard age > deadAfter else {
                return .unknown(
                    "no ~/.claude/sessions entry yet, transcript written \(Int(age))s ago"
                )
            }
            return LivenessHint(
                verdict: .dead,
                pid: nil,
                evidence: "no ~/.claude/sessions entry, transcript quiet for \(Int(age))s"
            )
        }

        let socket = entry.hasMessagingSocket ? ", messaging socket present" : ", no messaging socket"
        guard let process = table.record(pid: entry.pid) else {
            return LivenessHint(
                verdict: .dead,
                pid: entry.pid,
                evidence: "~/.claude/sessions names pid \(entry.pid), not in the process table\(socket)"
            )
        }

        if let procStart = entry.procStart {
            let drift = abs(process.startTime.timeIntervalSince(procStart))
            guard drift <= startTolerance else {
                return LivenessHint(
                    verdict: .dead,
                    pid: entry.pid,
                    evidence: "pid \(entry.pid) is running but started \(Int(drift))s from the "
                        + "recorded procStart — recycled pid\(socket)"
                )
            }
            return LivenessHint(
                verdict: .alive,
                pid: entry.pid,
                evidence: "pid \(entry.pid) matches the recorded procStart within \(Int(drift))s\(socket)"
            )
        }

        return LivenessHint(
            verdict: .alive,
            pid: entry.pid,
            evidence: "~/.claude/sessions names pid \(entry.pid), which is running\(socket)"
        )
    }

    /// The parent session id inside a key — the key's own id for a top-level
    /// session, and the half before the separator for a subagent.
    public static func rootSessionID(of key: SessionKey) -> String {
        guard let separator = key.sessionID.range(of: subagentKeySeparator) else { return key.sessionID }
        return String(key.sessionID[key.sessionID.startIndex..<separator.lowerBound])
    }
}

/// A ``JSONLTailer`` over one Claude Code transcript, plus the two pieces of
/// bookkeeping a bare line decoder cannot do.
///
/// - **Identity patches are de-duplicated.** ``ClaudeRecordMapper`` emits one
///   per fully-stamped record because it sees one line at a time;
///   ``ClaudeIdentityFilter`` here forwards only the fields that changed, so a
///   thousand-line transcript produces one `cwd` event and not a thousand.
/// - **Subagents are announced.** A child's tailer reports what it read to the
///   ``ClaudeSubagentLinker``; a parent's tailer drains what the linker queued
///   for it. See that type for why the join cannot happen in the decoder.
final class ClaudeSessionTailer: SessionTailer {
    let source: SessionSource

    private let inner: JSONLTailer
    private let linker: ClaudeSubagentLinker
    private let clock: @Sendable () -> Date
    private let isSubagent: Bool

    init(
        source: SessionSource,
        cursor: SourceCursor?,
        linker: ClaudeSubagentLinker,
        clock: @escaping @Sendable () -> Date
    ) {
        self.source = source
        self.linker = linker
        self.clock = clock
        self.isSubagent = source.seedIdentity.variant == ClaudeLiveAdapter.subagentVariant

        let key = source.key
        let subagent = isSubagent
        let filter = Mutex(ClaudeIdentityFilter())
        filter.withLock { $0.prime(with: source.seedIdentity) }

        inner = JSONLTailer(source: source, cursor: cursor) { data, _ in
            let now = clock()
            let events = ClaudeRecordMapper.events(
                from: data, session: key, isSubagent: subagent, now: now
            )
            return events.compactMap { event in
                guard case let .identityUpdated(patch) = event.kind else { return event }
                guard let fresh = filter.withLock({ $0.reduce(patch) }) else { return nil }
                return AgentEvent(
                    id: event.id,
                    session: event.session,
                    timestamp: event.timestamp,
                    observedAt: event.observedAt,
                    kind: .identityUpdated(fresh),
                    raw: event.raw
                )
            }
        }
    }

    var cursor: SourceCursor { inner.cursor }

    func poll() throws -> [AgentEvent] {
        try link(inner.poll())
    }

    func seedFromTail(maxBytes: Int) throws -> [AgentEvent] {
        try link(inner.seedFromTail(maxBytes: maxBytes))
    }

    /// Reports a child's events to the linker, or prefixes a parent's with
    /// whatever the linker queued.
    ///
    /// The queued events come first because they describe something that
    /// happened before the lines just read: a child transcript that appeared
    /// during the last interval was spawned by a `Task` call the parent
    /// already logged.
    private func link(_ events: [AgentEvent]) -> [AgentEvent] {
        if isSubagent {
            linker.childProduced(events, child: source.key)
            return events
        }
        let queued = linker.drain(parent: source.key, now: clock())
        return queued.isEmpty ? events : queued + events
    }
}
