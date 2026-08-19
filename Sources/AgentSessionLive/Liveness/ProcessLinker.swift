import AgentSessionKit
import Foundation

/// One inferred parent/child edge, with the evidence that produced it.
///
/// A link is a *proposal*. It carries its own confidence and a sentence
/// explaining itself so a host can show a dotted line, log why a row moved, or
/// discard everything below a threshold — none of which is possible once the
/// inference has been flattened into a `parent` field.
public struct ProcessLink: Hashable, Codable, Sendable {
    /// How much the evidence is worth.
    ///
    /// - `high`: an identifier the parent itself wrote into the child's
    ///   environment. There is no other way that value got there.
    /// - `medium`: a process relationship — the child is a descendant of the
    ///   parent's pid, or names it. True of a spawned harness, and also true
    ///   of anything else that happened to be started from the same shell.
    /// - `low`: reserved for a caller's own weaker heuristics; nothing in
    ///   ``ProcessLinker/infer(identities:table:)`` emits it.
    public enum Confidence: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
        case low
        case medium
        case high

        private var rank: Int {
            switch self {
            case .low: 0
            case .medium: 1
            case .high: 2
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    /// The session that was spawned.
    public let child: SessionKey
    /// The session that spawned it.
    public let parent: SessionKey
    /// What kind of evidence this is.
    public let link: ParentLink
    /// How much that evidence is worth.
    public let confidence: Confidence
    /// One sentence naming the evidence. Safe to log: it carries variable
    /// names, pids, and session keys, and never a path, a value, or a command.
    public let evidence: String

    /// Creates a link.
    public init(
        child: SessionKey,
        parent: SessionKey,
        link: ParentLink,
        confidence: Confidence,
        evidence: String
    ) {
        self.child = child
        self.parent = parent
        self.link = link
        self.confidence = confidence
        self.evidence = evidence
    }
}

/// Infers parent/child links between sessions that no log records.
///
/// Two harnesses that spawn each other write nothing about it. A Claude Code
/// tool call that runs `codex exec` produces a Claude transcript with a `Bash`
/// call in it and a Codex rollout that begins as if a person had typed the
/// prompt; the only places the relationship survives are the process tree and
/// the environment the parent handed down. This reads both.
///
/// ## Precedence
///
/// Evidence is ranked, strongest first — the same order as
/// ``ParentLink/precedence``:
///
/// | Link | Meaning | Who produces it |
/// | --- | --- | --- |
/// | ``ParentLink/manual`` | a person said so | the host's UI |
/// | ``ParentLink/subagent`` | the parent's log recorded the spawn | an adapter |
/// | ``ParentLink/envInherited`` | the parent's session id is in the child's environment | this type |
/// | ``ParentLink/spawnedProcess`` | the child's process descends from the parent's | this type |
///
/// ``infer(identities:table:)`` **only fills blanks**: a session that already
/// has a parent is skipped whatever the evidence for it was, so an inference
/// can never displace a recorded spawn or a person's decision. Within one
/// inference the ranking still applies — an environment match wins over a
/// process-tree match for the same child, because a shell that started two
/// harnesses in a row makes them each other's ancestors without either having
/// spawned the other.
///
/// ## What it will not do
///
/// - No self-links, and no cycles: a proposal that would close a loop through
///   the parents already recorded, or through the ones proposed in the same
///   pass, is dropped rather than reordered.
/// - No link from an ambiguous match. Two sessions sharing one pid, or one
///   session id matching two harnesses, produce nothing — a wrong edge moves a
///   row under the wrong project, and an absent edge only leaves it where it
///   was.
/// - Nothing for a session with no pid. Codex holds its thread lock with
///   `flock(2)`, which the kernel does not attribute, so most Codex sessions
///   have no pid to read an environment from; ``linkFromToolCommand(parent:command:startedAt:candidates:)``
///   is the hook for that case, and it needs a tool call from the parent's log
///   that this type never sees.
public struct ProcessLinker: Sendable {
    /// How far a candidate's start may be from the tool call that supposedly
    /// launched it, in ``linkFromToolCommand(parent:command:startedAt:candidates:)``.
    public let commandWindow: TimeInterval

    /// Creates a linker.
    ///
    /// - Parameter commandWindow: the ± window a command match allows between
    ///   the tool call and the candidate's `procStart`. Ten seconds covers a
    ///   cold harness start on a busy machine without reaching the next one a
    ///   person launched by hand.
    public init(commandWindow: TimeInterval = 10) {
        self.commandWindow = commandWindow
    }

    // MARK: - Inference

    /// Proposes a parent for every session that has none.
    ///
    /// Pure with respect to `table`, and one call reads one snapshot of it:
    /// ``ProcessTable`` caches, so an ancestor walk and an environment read for
    /// sixty sessions cost one process-table read between them.
    ///
    /// The result is ordered by child key, so two runs over the same inputs
    /// produce the same array.
    public func infer(
        identities: [SessionIdentity],
        table: any ProcessTableReading
    ) -> [ProcessLink] {
        let ordered = identities.sorted { $0.key.description < $1.key.description }
        let index = Index(identities: ordered)
        var proposed: [SessionKey: SessionKey] = [:]
        var links: [ProcessLink] = []

        for identity in ordered {
            // Only blanks. A recorded spawn or a person's own link is not
            // something a process-tree guess gets to argue with.
            guard identity.parent == nil, let pid = identity.pid else { continue }

            let environment = table.environment(pid: pid)
            let candidate = environmentLink(for: identity, environment: environment, index: index)
                ?? spawnLink(
                    for: identity,
                    pid: pid,
                    environment: environment,
                    table: table,
                    index: index
                )

            guard let candidate else { continue }
            guard !closesCycle(
                child: candidate.child,
                parent: candidate.parent,
                recorded: index.parents,
                proposed: proposed
            ) else { continue }

            proposed[candidate.child] = candidate.parent
            links.append(candidate)
        }
        return links
    }

    /// Turns links into patches a host can feed back through
    /// ``AgentEventKind/identityUpdated(_:)``.
    ///
    /// The patch carries both the parent and the evidence, because
    /// ``SessionIdentity/parentLink`` is documented as non-`nil` exactly when
    /// ``SessionIdentity/parent`` is, and because
    /// ``SessionIdentityPatch/applied(to:)`` needs the link to know whether it
    /// outranks whatever is already recorded.
    public func identityPatches(
        from links: [ProcessLink]
    ) -> [(SessionKey, SessionIdentityPatch)] {
        links.map { link in
            (link.child, SessionIdentityPatch(parent: link.parent, parentLink: link.link))
        }
    }

    // MARK: - Command matching

    /// Matches a shell command the parent ran against the sessions on the
    /// board, for the case a process tree cannot answer.
    ///
    /// A tool call is the one piece of evidence that exists when the child has
    /// no pid at all — a Codex thread whose `flock(2)` the kernel will not
    /// attribute, a `cursor-agent` run whose worker exited. The parent's log
    /// says a command started at a moment; a candidate says it started at
    /// roughly that moment in the same directory; the executable says which
    /// harness it is. Three weak facts, and only their conjunction is used.
    ///
    /// Pure, and deliberately not called from ``infer(identities:table:)``:
    /// the tool call lives in the parent's event stream, which is the host's
    /// to read.
    ///
    /// Returns `nil` — not a best guess — when more than one candidate
    /// qualifies. Two `codex exec` calls a second apart genuinely cannot be
    /// told apart this way, and an edge under the wrong parent is worse than
    /// no edge.
    ///
    /// - Parameters:
    ///   - parent: the session whose tool call this was. Looked up in
    ///     `candidates` for its working directory; when it is not there, or has
    ///     none recorded, the directory test is skipped rather than failed.
    ///   - command: the command line as the parent's log recorded it.
    ///   - startedAt: when the tool call started.
    ///   - candidates: the sessions to match against. A candidate that already
    ///     has a parent, that is the parent itself, or that has no `procStart`
    ///     is not eligible.
    public func linkFromToolCommand(
        parent: SessionKey,
        command: String,
        startedAt: Date,
        candidates: [SessionIdentity]
    ) -> SessionKey? {
        guard let harness = Self.harness(launchedBy: command) else { return nil }
        let parentCWD = candidates.first { $0.key == parent }?.cwd

        var best: (key: SessionKey, drift: TimeInterval)?
        var isAmbiguous = false

        for candidate in candidates.sorted(by: { $0.key.description < $1.key.description }) {
            guard candidate.key != parent,
                  candidate.key.harness == harness,
                  candidate.parent == nil,
                  let procStart = candidate.procStart
            else { continue }
            if let parentCWD, let candidateCWD = candidate.cwd, candidateCWD != parentCWD { continue }

            let drift = abs(procStart.timeIntervalSince(startedAt))
            guard drift <= commandWindow else { continue }

            if best == nil {
                best = (candidate.key, drift)
            } else {
                isAmbiguous = true
            }
        }
        guard !isAmbiguous else { return nil }
        return best?.key
    }

    /// The harness a command line launches, or `nil` when it launches none of
    /// them.
    ///
    /// Walks past environment assignments and the wrappers that precede a real
    /// executable (`env`, `exec`, `nohup`, `command`), and looks at every
    /// segment of a compound command, so `cd /repo && codex exec …` is a Codex
    /// launch. Quoting is handled only to the extent of stripping a leading
    /// quote from a path — this reads a command, it does not run one.
    public static func harness(launchedBy command: String) -> Harness? {
        for segment in command.split(whereSeparator: \.isShellSeparator) {
            for token in segment.split(whereSeparator: \.isWhitespace) {
                let word = Self.unquoted(String(token))
                if word.isEmpty { continue }
                // `FOO=bar cmd …` — keep walking; the assignment is not the
                // executable.
                if let equals = word.firstIndex(of: "="), equals != word.startIndex,
                   !word.hasPrefix("-"), !word.contains("/") {
                    continue
                }
                let name = (word as NSString).lastPathComponent
                if Self.commandWrappers.contains(name) { continue }
                if let harness = Self.harnessByExecutable[name] { return harness }
                // The first real word of a segment was something else. A
                // harness later in the same segment is an argument, not a
                // launch.
                break
            }
        }
        return nil
    }

    /// Executable names that launch a harness. Basenames only: a person's
    /// `~/.grok/bin/grok` and a Homebrew `grok` are the same harness.
    static let harnessByExecutable: [String: Harness] = [
        "claude": .claudeCode,
        "codex": .codex,
        "grok": .grokBuild,
        "cursor-agent": .cursor,
        "agy": .antigravity,
    ]

    /// Words that stand in front of the executable without being it.
    static let commandWrappers: Set<String> = ["env", "exec", "nohup", "command", "time"]

    // MARK: - Environment

    /// A parent named by a variable in the child's own environment.
    private func environmentLink(
        for identity: SessionIdentity,
        environment: [String: String]?,
        index: Index
    ) -> ProcessLink? {
        guard let environment else { return nil }

        for variable in SessionEnvironmentVariables.sessionIDVariables(for: identity.key.harness) {
            guard let value = Self.usableValue(environment[variable]) else { continue }

            // The variable's own harness first: a name that means "a Codex
            // session id" matching a Codex session is not a coincidence.
            for harness in SessionEnvironmentVariables.harnesses(namedBy: variable) {
                guard let parent = index.key(harness: harness, sessionID: value),
                      parent != identity.key
                else { continue }
                return ProcessLink(
                    child: identity.key,
                    parent: parent,
                    link: .envInherited,
                    confidence: .high,
                    evidence: "\(variable) in pid \(identity.pid.map(String.init) ?? "?")"
                        + "'s environment names \(parent)"
                )
            }

            // Failing that, the same value as *some* session's id. Weaker: the
            // name promised one harness and the value was found in another, so
            // it is only used when exactly one session answers to it.
            let matches = index.keys(sessionID: value).filter { $0 != identity.key }
            if matches.count == 1 {
                return ProcessLink(
                    child: identity.key,
                    parent: matches[0],
                    link: .envInherited,
                    confidence: .medium,
                    evidence: "\(variable) holds the session id of \(matches[0]), "
                        + "which is not the harness that variable belongs to"
                )
            }
        }
        return nil
    }

    // MARK: - Process tree

    /// A parent found by walking up the process tree, or named by a
    /// pid-carrying variable when the tree has been broken by re-parenting.
    private func spawnLink(
        for identity: SessionIdentity,
        pid: pid_t,
        environment: [String: String]?,
        table: any ProcessTableReading,
        index: Index
    ) -> ProcessLink? {
        for ancestor in table.ancestors(of: pid) {
            guard let parent = index.key(pid: ancestor.pid), parent != identity.key else { continue }
            return ProcessLink(
                child: identity.key,
                parent: parent,
                link: .spawnedProcess,
                confidence: .medium,
                evidence: "pid \(pid) descends from pid \(ancestor.pid), which runs \(parent)"
            )
        }

        guard let environment else { return nil }
        for variable in SessionEnvironmentVariables.allProcessIDVariables {
            guard let value = Self.usableValue(environment[variable]),
                  let named = pid_t(value), named != pid,
                  let parent = index.key(pid: named), parent != identity.key
            else { continue }
            return ProcessLink(
                child: identity.key,
                parent: parent,
                link: .spawnedProcess,
                confidence: .medium,
                evidence: "\(variable) names pid \(named), which runs \(parent)"
            )
        }
        return nil
    }

    // MARK: - Guards

    /// `true` when making `parent` the parent of `child` would close a loop.
    ///
    /// Walks up from the proposed parent through both the parents already
    /// recorded and the ones proposed earlier in the same pass. The step limit
    /// is a backstop: the walk already stops on a repeat, and a chain longer
    /// than the number of sessions cannot exist.
    private func closesCycle(
        child: SessionKey,
        parent: SessionKey,
        recorded: [SessionKey: SessionKey],
        proposed: [SessionKey: SessionKey]
    ) -> Bool {
        if parent == child { return true }
        var seen: Set<SessionKey> = [child]
        var current: SessionKey? = parent
        while let key = current, seen.insert(key).inserted {
            current = proposed[key] ?? recorded[key]
            if current == child { return true }
        }
        return false
    }

    /// An environment value worth matching: present, not blank, and not the
    /// placeholder ``ArgvSanitizer`` leaves behind. A redacted value would
    /// otherwise match every other redacted value on the board.
    private static func usableValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ArgvSanitizer.redactionPlaceholder else { return nil }
        return trimmed
    }

    private static func unquoted(_ token: String) -> String {
        var value = token
        while let first = value.first, first == "\"" || first == "'" || first == "\\" {
            value.removeFirst()
        }
        while let last = value.last, last == "\"" || last == "'" {
            value.removeLast()
        }
        return value
    }

    // MARK: - Index

    /// The lookups one inference pass needs, built once.
    ///
    /// Ambiguity is resolved here rather than at each use, and always in the
    /// direction of answering nothing: a session id claimed by two sessions of
    /// one harness cannot happen, but a pid claimed by two sessions can — a
    /// Claude Code subagent runs inside its parent's process — so a pid maps to
    /// a key only when exactly one *parentless* session holds it.
    private struct Index {
        private var byHarness: [Harness: [String: SessionKey]] = [:]
        private var bySessionID: [String: [SessionKey]] = [:]
        private var byPID: [pid_t: SessionKey] = [:]
        var parents: [SessionKey: SessionKey] = [:]

        init(identities: [SessionIdentity]) {
            var pidClaims: [pid_t: [SessionIdentity]] = [:]
            for identity in identities {
                let key = identity.key
                byHarness[key.harness, default: [:]][key.sessionID] = key
                bySessionID[key.sessionID, default: []].append(key)
                if let parent = identity.parent { parents[key] = parent }
                if let pid = identity.pid { pidClaims[pid, default: []].append(identity) }
            }
            for (pid, claimants) in pidClaims {
                let roots = claimants.filter { $0.parent == nil }
                let winners = roots.isEmpty ? claimants : roots
                guard winners.count == 1 else { continue }
                byPID[pid] = winners[0].key
            }
        }

        func key(harness: Harness, sessionID: String) -> SessionKey? {
            byHarness[harness]?[sessionID]
        }

        func keys(sessionID: String) -> [SessionKey] {
            bySessionID[sessionID] ?? []
        }

        func key(pid: pid_t) -> SessionKey? {
            byPID[pid]
        }
    }
}

extension Character {
    /// The separators between the commands of a compound shell line. Splitting
    /// on these is what lets `cd /repo && codex exec …` be recognised as a
    /// Codex launch rather than a `cd`.
    fileprivate var isShellSeparator: Bool {
        self == "&" || self == "|" || self == ";" || self == "\n" || self == "\r"
    }
}
