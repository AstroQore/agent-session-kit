import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

@Suite("ProcessLinker")
struct ProcessLinkerTests {
    private let linker = ProcessLinker()

    // MARK: - Fixture helpers

    private func key(_ harness: Harness, _ id: String) -> SessionKey {
        SessionKey(harness: harness, sessionID: id)
    }

    private func identity(
        _ harness: Harness,
        _ id: String,
        pid: pid_t? = nil,
        procStart: Date? = nil,
        cwd: String? = nil,
        parent: SessionKey? = nil,
        parentLink: ParentLink? = nil
    ) -> SessionIdentity {
        SessionIdentity(
            key: key(harness, id),
            sourcePath: "/Users/example/store/\(id)",
            parent: parent,
            parentLink: parentLink,
            cwd: cwd,
            pid: pid,
            procStart: procStart
        )
    }

    private func record(_ pid: pid_t, ppid: pid_t, name: String = "harness") -> ProcessRecord {
        ProcessRecord(
            pid: pid,
            ppid: ppid,
            startTime: epoch,
            executablePath: "/Users/example/bin/\(name)",
            argv: []
        )
    }

    // MARK: - Environment inheritance

    @Test("a session id inherited through the environment links across harnesses")
    func environmentAcrossHarnesses() {
        // A Claude Code tool call ran `codex exec`; the Codex process carries
        // the Claude session id it was handed at exec.
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.codex, "codex-1", pid: 200),
        ]
        let table = FakeProcessTable(
            records: [record(100, ppid: 1), record(200, ppid: 1)],
            environments: [200: [SessionEnvironmentVariables.claudeSessionID: "claude-1"]]
        )

        let links = linker.infer(identities: identities, table: table)
        #expect(links.count == 1)
        #expect(links[0].child == key(.codex, "codex-1"))
        #expect(links[0].parent == key(.claudeCode, "claude-1"))
        #expect(links[0].link == .envInherited)
        #expect(links[0].confidence == .high)
        #expect(links[0].evidence.contains(SessionEnvironmentVariables.claudeSessionID))
    }

    @Test("the child's own harness variable outranks an outer one it also inherited")
    func nearestEnvironmentWins() {
        // claude-1 → codex-1 → codex-2. The innermost process carries both
        // variables; the nearer parent is the Codex one.
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.codex, "codex-1", pid: 200),
            identity(.codex, "codex-2", pid: 300),
        ]
        let table = FakeProcessTable(
            records: [record(100, ppid: 1), record(200, ppid: 1), record(300, ppid: 1)],
            environments: [
                200: [SessionEnvironmentVariables.claudeSessionID: "claude-1"],
                300: [
                    SessionEnvironmentVariables.claudeSessionID: "claude-1",
                    SessionEnvironmentVariables.codexSessionID: "codex-1",
                ],
            ]
        )

        let links = linker.infer(identities: identities, table: table)
        let byChild = Dictionary(uniqueKeysWithValues: links.map { ($0.child, $0.parent) })
        #expect(byChild[key(.codex, "codex-1")] == key(.claudeCode, "claude-1"))
        #expect(byChild[key(.codex, "codex-2")] == key(.codex, "codex-1"))
    }

    @Test("a variable matching another harness's session id is a weaker link")
    func crossTableMatchIsMedium() {
        // Only a Grok session answers to the id, and the variable that carries
        // it belongs to Codex. Usable, but not proof.
        let identities = [
            identity(.grokBuild, "shared-id", pid: 100),
            identity(.cursor, "cursor-1", pid: 200),
        ]
        let table = FakeProcessTable(
            records: [record(100, ppid: 1), record(200, ppid: 1)],
            environments: [200: [SessionEnvironmentVariables.codexSessionID: "shared-id"]]
        )

        let links = linker.infer(identities: identities, table: table)
        #expect(links.count == 1)
        #expect(links[0].parent == key(.grokBuild, "shared-id"))
        #expect(links[0].confidence == .medium)
    }

    @Test("an id claimed by two harnesses links to neither")
    func ambiguousCrossTableMatch() {
        let identities = [
            identity(.grokBuild, "shared-id", pid: 100),
            identity(.antigravity, "shared-id", pid: 150),
            identity(.cursor, "cursor-1", pid: 200),
        ]
        let table = FakeProcessTable(
            records: [record(100, ppid: 1), record(150, ppid: 1), record(200, ppid: 1)],
            environments: [200: [SessionEnvironmentVariables.codexSessionID: "shared-id"]]
        )
        #expect(linker.infer(identities: identities, table: table).isEmpty)
    }

    @Test("a variable naming the session's own id is not a link")
    func noSelfLink() {
        let identities = [identity(.claudeCode, "claude-1", pid: 100)]
        let table = FakeProcessTable(
            records: [record(100, ppid: 1)],
            environments: [100: [SessionEnvironmentVariables.claudeSessionID: "claude-1"]]
        )
        #expect(linker.infer(identities: identities, table: table).isEmpty)
    }

    @Test("a redacted value matches nothing")
    func redactedValueIsIgnored() {
        // `sanitizeEnvironment` blanks anything whose *name* looks secret; the
        // linker must not treat two placeholders as the same session.
        let identities = [
            identity(.claudeCode, ArgvSanitizer.redactionPlaceholder, pid: 100),
            identity(.codex, "codex-1", pid: 200),
        ]
        let table = FakeProcessTable(
            records: [record(100, ppid: 1), record(200, ppid: 1)],
            environments: [
                200: [SessionEnvironmentVariables.claudeSessionID: ArgvSanitizer.redactionPlaceholder]
            ]
        )
        #expect(linker.infer(identities: identities, table: table).isEmpty)
    }

    // MARK: - Process tree

    @Test("a descendant process links to the session that owns its ancestor")
    func ancestorChain() {
        // claude (100) → zsh (101) → grok (102), and nothing in the
        // environment says so.
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.grokBuild, "grok-1", pid: 102),
        ]
        let table = FakeProcessTable(records: [
            record(100, ppid: 1, name: "claude"),
            record(101, ppid: 100, name: "zsh"),
            record(102, ppid: 101, name: "grok"),
        ])

        let links = linker.infer(identities: identities, table: table)
        #expect(links.count == 1)
        #expect(links[0].parent == key(.claudeCode, "claude-1"))
        #expect(links[0].link == .spawnedProcess)
        #expect(links[0].confidence == .medium)
    }

    @Test("the nearest known ancestor wins over a further one")
    func nearestAncestorWins() {
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.grokBuild, "grok-1", pid: 101),
            identity(.cursor, "cursor-1", pid: 102),
        ]
        let table = FakeProcessTable(records: [
            record(100, ppid: 1),
            record(101, ppid: 100),
            record(102, ppid: 101),
        ])
        let links = linker.infer(identities: identities, table: table)
        let byChild = Dictionary(uniqueKeysWithValues: links.map { ($0.child, $0.parent) })
        #expect(byChild[key(.cursor, "cursor-1")] == key(.grokBuild, "grok-1"))
    }

    @Test("a re-parented child is still linked by the pid its parent named")
    func processIDVariableFallback() {
        // The shell exited, so the harness was re-parented to launchd and the
        // ancestor walk reaches nothing; `CLAUDE_PID` survives that.
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.codex, "codex-1", pid: 300),
        ]
        let table = FakeProcessTable(
            records: [record(100, ppid: 1), record(300, ppid: 1)],
            environments: [300: [SessionEnvironmentVariables.claudePID: "100"]]
        )

        let links = linker.infer(identities: identities, table: table)
        #expect(links.count == 1)
        #expect(links[0].parent == key(.claudeCode, "claude-1"))
        #expect(links[0].link == .spawnedProcess)
    }

    @Test("an environment match outranks a process-tree match for the same child")
    func environmentBeatsAncestry() {
        // The Codex process is a child of the Grok one — a shell started both —
        // but its environment names the Claude session that actually ran it.
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.grokBuild, "grok-1", pid: 200),
            identity(.codex, "codex-1", pid: 300),
        ]
        let table = FakeProcessTable(
            records: [record(100, ppid: 1), record(200, ppid: 1), record(300, ppid: 200)],
            environments: [300: [SessionEnvironmentVariables.claudeSessionID: "claude-1"]]
        )

        let links = linker.infer(identities: identities, table: table)
        let codex = try? #require(links.first { $0.child == key(.codex, "codex-1") })
        #expect(codex?.parent == key(.claudeCode, "claude-1"))
        #expect(codex?.link == .envInherited)
    }

    @Test("two sessions sharing one pid are too ambiguous to be a parent")
    func ambiguousPID() {
        // Two parentless sessions attributed to the same process: no link.
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.claudeCode, "claude-2", pid: 100),
            identity(.codex, "codex-1", pid: 200),
        ]
        let table = FakeProcessTable(records: [
            record(100, ppid: 1),
            record(200, ppid: 100),
        ])
        #expect(linker.infer(identities: identities, table: table).isEmpty)
    }

    @Test("a subagent sharing its parent's pid does not shadow the parent")
    func parentedSessionYieldsPIDToItsRoot() {
        // A Claude subagent runs inside its parent's process, so both carry the
        // same pid. The parentless one is the process's owner.
        let root = key(.claudeCode, "claude-1")
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.claudeCode, "claude-1/agent-a", pid: 100, parent: root, parentLink: .subagent(toolUseID: "t1")),
            identity(.codex, "codex-1", pid: 200),
        ]
        let table = FakeProcessTable(records: [
            record(100, ppid: 1),
            record(200, ppid: 100),
        ])
        let links = linker.infer(identities: identities, table: table)
        #expect(links.count == 1)
        #expect(links[0].child == key(.codex, "codex-1"))
        #expect(links[0].parent == root)
    }

    // MARK: - Precedence and safety

    @Test("a session that already has a parent is never re-linked")
    func existingParentIsNeverOverridden() {
        let recorded = key(.claudeCode, "claude-1")
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.grokBuild, "grok-1", pid: 200),
            identity(
                .codex, "codex-1", pid: 300,
                parent: recorded, parentLink: .subagent(toolUseID: "t1")
            ),
        ]
        // Evidence pointing somewhere else entirely.
        let table = FakeProcessTable(
            records: [record(100, ppid: 1), record(200, ppid: 1), record(300, ppid: 200)],
            environments: [300: [SessionEnvironmentVariables.grokSessionID: "grok-1"]]
        )
        #expect(linker.infer(identities: identities, table: table).isEmpty)
    }

    @Test("a manual link is left alone")
    func manualLinkIsLeftAlone() {
        let manual = key(.grokBuild, "grok-1")
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.grokBuild, "grok-1", pid: 200),
            identity(.cursor, "cursor-1", pid: 300, parent: manual, parentLink: .manual),
        ]
        let table = FakeProcessTable(
            records: [record(100, ppid: 1), record(200, ppid: 1), record(300, ppid: 100)],
            environments: [300: [SessionEnvironmentVariables.claudeSessionID: "claude-1"]]
        )
        #expect(linker.infer(identities: identities, table: table).isEmpty)
    }

    @Test("a session with no pid produces nothing")
    func noPIDNoLink() {
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.codex, "codex-1"),
        ]
        let table = FakeProcessTable(records: [record(100, ppid: 1)])
        #expect(linker.infer(identities: identities, table: table).isEmpty)
    }

    @Test("unrelated sessions are left unlinked")
    func unrelatedSessions() {
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.codex, "codex-1", pid: 200),
            identity(.cursor, "cursor-1", pid: 300),
        ]
        // Three siblings under the same login shell, and an environment that
        // names a session nobody has heard of.
        let table = FakeProcessTable(
            records: [
                record(1, ppid: 0, name: "launchd"),
                record(100, ppid: 1), record(200, ppid: 1), record(300, ppid: 1),
            ],
            environments: [200: [SessionEnvironmentVariables.claudeSessionID: "some-other-session"]]
        )
        #expect(linker.infer(identities: identities, table: table).isEmpty)
    }

    @Test("a pair of sessions naming each other yields one link, not a cycle")
    func cycleSafety() {
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.codex, "codex-1", pid: 200),
        ]
        let table = FakeProcessTable(
            records: [record(100, ppid: 1), record(200, ppid: 1)],
            environments: [
                100: [SessionEnvironmentVariables.codexSessionID: "codex-1"],
                200: [SessionEnvironmentVariables.claudeSessionID: "claude-1"],
            ]
        )
        let links = linker.infer(identities: identities, table: table)
        #expect(links.count == 1)
    }

    @Test("a cycle through an already-recorded parent is refused")
    func cycleThroughRecordedParent() {
        // grok-1's parent is already codex-1. Evidence that codex-1's parent is
        // grok-1 would close the loop.
        let identities = [
            identity(.codex, "codex-1", pid: 100),
            identity(
                .grokBuild, "grok-1", pid: 200,
                parent: key(.codex, "codex-1"), parentLink: .subagent(toolUseID: "t1")
            ),
        ]
        let table = FakeProcessTable(
            records: [record(100, ppid: 1), record(200, ppid: 1)],
            environments: [100: [SessionEnvironmentVariables.grokSessionID: "grok-1"]]
        )
        #expect(linker.infer(identities: identities, table: table).isEmpty)
    }

    @Test("the result is ordered by child key")
    func deterministicOrder() {
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.grokBuild, "grok-1", pid: 300),
            identity(.codex, "codex-1", pid: 200),
        ]
        let table = FakeProcessTable(records: [
            record(100, ppid: 1), record(200, ppid: 100), record(300, ppid: 100),
        ])
        let links = linker.infer(identities: identities, table: table)
        #expect(links.map(\.child.description) == links.map(\.child.description).sorted())
    }

    // MARK: - Patches

    @Test("patches carry the parent and its evidence")
    func patchesCarryTheLink() {
        let identities = [
            identity(.claudeCode, "claude-1", pid: 100),
            identity(.codex, "codex-1", pid: 200),
        ]
        let table = FakeProcessTable(
            records: [record(100, ppid: 1), record(200, ppid: 100)],
            environments: [200: [SessionEnvironmentVariables.claudeSessionID: "claude-1"]]
        )
        let patches = linker.identityPatches(from: linker.infer(identities: identities, table: table))
        #expect(patches.count == 1)
        #expect(patches[0].0 == key(.codex, "codex-1"))

        let applied = patches[0].1.applied(to: identities[1])
        #expect(applied.parent == key(.claudeCode, "claude-1"))
        #expect(applied.parentLink == .envInherited)
    }

    @Test("a weaker patch cannot displace a recorded parent")
    func patchPrecedence() {
        let recorded = identity(
            .codex, "codex-1",
            parent: key(.claudeCode, "claude-1"),
            parentLink: .subagent(toolUseID: "t1")
        )
        let weaker = SessionIdentityPatch(
            parent: key(.grokBuild, "grok-1"),
            parentLink: .envInherited
        )
        let applied = weaker.applied(to: recorded)
        #expect(applied.parent == key(.claudeCode, "claude-1"))
        #expect(applied.parentLink == .subagent(toolUseID: "t1"))

        // A person's own link outranks everything, in both directions.
        let manual = SessionIdentityPatch(parent: key(.grokBuild, "grok-1"), parentLink: .manual)
        #expect(manual.applied(to: recorded).parent == key(.grokBuild, "grok-1"))
        #expect(manual.applied(to: manual.applied(to: recorded)).parentLink == .manual)
        let demotion = SessionIdentityPatch(
            parent: key(.codex, "codex-9"),
            parentLink: .spawnedProcess
        )
        #expect(demotion.applied(to: manual.applied(to: recorded)).parent == key(.grokBuild, "grok-1"))
    }

    @Test("a patch naming only a link upgrades the evidence for the parent already there")
    func patchUpgradesEvidence() {
        let inferred = identity(
            .codex, "codex-1",
            parent: key(.claudeCode, "claude-1"),
            parentLink: .spawnedProcess
        )
        let upgrade = SessionIdentityPatch(parentLink: .subagent(toolUseID: "t7"))
        let applied = upgrade.applied(to: inferred)
        #expect(applied.parent == key(.claudeCode, "claude-1"))
        #expect(applied.parentLink == .subagent(toolUseID: "t7"))

        // With no parent recorded, a bare link is not enough to invent one.
        let bare = SessionIdentityPatch(parentLink: .manual).applied(to: identity(.codex, "codex-2"))
        #expect(bare.parent == nil)
        #expect(bare.parentLink == nil)
    }

    @Test("an empty patch is still empty with the new fields")
    func emptinessUnchanged() {
        #expect(SessionIdentityPatch().isEmpty)
        #expect(!SessionIdentityPatch(parent: key(.codex, "c")).isEmpty)
        #expect(!SessionIdentityPatch(parentLink: .manual).isEmpty)
        #expect(!SessionIdentityPatch(gitRoot: "/Users/example/repo").isEmpty)
        #expect(!SessionIdentityPatch(worktreePath: "/Users/example/repo/wt").isEmpty)
    }

    @Test("parent fields decode from a patch written before they existed")
    func patchDecodesWithoutParentFields() throws {
        let json = #"{"cwd":"/Users/example/repo","model":"a-model"}"#
        let patch = try JSONDecoder().decode(
            SessionIdentityPatch.self,
            from: Data(json.utf8)
        )
        #expect(patch.cwd == "/Users/example/repo")
        #expect(patch.parent == nil)
        #expect(patch.parentLink == nil)
    }

    // MARK: - Command matching

    private func commandCandidates(procStart: Date, cwd: String? = "/Users/example/repo") -> [SessionIdentity] {
        [
            identity(.claudeCode, "claude-1", cwd: "/Users/example/repo"),
            identity(.codex, "codex-1", procStart: procStart, cwd: cwd),
        ]
    }

    @Test("a shell command that launched a harness matches the session it started")
    func commandMatch() {
        let startedAt = epoch
        let match = linker.linkFromToolCommand(
            parent: key(.claudeCode, "claude-1"),
            command: "codex exec --skip-git-repo-check \"do the thing\"",
            startedAt: startedAt,
            candidates: commandCandidates(procStart: startedAt.addingTimeInterval(2))
        )
        #expect(match == key(.codex, "codex-1"))
    }

    @Test("a compound command is read segment by segment")
    func compoundCommand() {
        let startedAt = epoch
        let match = linker.linkFromToolCommand(
            parent: key(.claudeCode, "claude-1"),
            command: "cd /Users/example/repo && RUST_LOG=info codex exec 'go'",
            startedAt: startedAt,
            candidates: commandCandidates(procStart: startedAt)
        )
        #expect(match == key(.codex, "codex-1"))
    }

    @Test("a command that mentions a harness without launching it matches nothing")
    func mentionIsNotALaunch() {
        let startedAt = epoch
        let match = linker.linkFromToolCommand(
            parent: key(.claudeCode, "claude-1"),
            command: "grep -rn codex Sources",
            startedAt: startedAt,
            candidates: commandCandidates(procStart: startedAt)
        )
        #expect(match == nil)
    }

    @Test("a candidate that started outside the window does not match")
    func outsideTheWindow() {
        let startedAt = epoch
        let match = linker.linkFromToolCommand(
            parent: key(.claudeCode, "claude-1"),
            command: "codex exec 'go'",
            startedAt: startedAt,
            candidates: commandCandidates(procStart: startedAt.addingTimeInterval(600))
        )
        #expect(match == nil)
    }

    @Test("a candidate in another directory does not match")
    func differentWorkingDirectory() {
        let startedAt = epoch
        let match = linker.linkFromToolCommand(
            parent: key(.claudeCode, "claude-1"),
            command: "codex exec 'go'",
            startedAt: startedAt,
            candidates: commandCandidates(
                procStart: startedAt,
                cwd: "/Users/example/elsewhere"
            )
        )
        #expect(match == nil)
    }

    @Test("two equally plausible candidates match neither")
    func ambiguousCommandMatch() {
        let startedAt = epoch
        let candidates = [
            identity(.claudeCode, "claude-1", cwd: "/Users/example/repo"),
            identity(.codex, "codex-1", procStart: startedAt, cwd: "/Users/example/repo"),
            identity(.codex, "codex-2", procStart: startedAt.addingTimeInterval(1), cwd: "/Users/example/repo"),
        ]
        let match = linker.linkFromToolCommand(
            parent: key(.claudeCode, "claude-1"),
            command: "codex exec 'go'",
            startedAt: startedAt,
            candidates: candidates
        )
        #expect(match == nil)
    }

    @Test("a candidate that already has a parent is not eligible")
    func parentedCandidateIsSkipped() {
        let startedAt = epoch
        let candidates = [
            identity(.claudeCode, "claude-1", cwd: "/Users/example/repo"),
            identity(
                .codex, "codex-1", procStart: startedAt, cwd: "/Users/example/repo",
                parent: key(.grokBuild, "grok-1"), parentLink: .manual
            ),
        ]
        #expect(linker.linkFromToolCommand(
            parent: key(.claudeCode, "claude-1"),
            command: "codex exec 'go'",
            startedAt: startedAt,
            candidates: candidates
        ) == nil)
    }

    @Test("every harness's launcher is recognised, by basename")
    func executableNames() {
        #expect(ProcessLinker.harness(launchedBy: "claude -p 'hi'") == .claudeCode)
        #expect(ProcessLinker.harness(launchedBy: "/opt/homebrew/bin/codex exec") == .codex)
        #expect(ProcessLinker.harness(launchedBy: "/Users/example/.grok/bin/grok agent") == .grokBuild)
        #expect(ProcessLinker.harness(launchedBy: "cursor-agent --print 'hi'") == .cursor)
        #expect(ProcessLinker.harness(launchedBy: "agy --sandbox --print 'hi'") == .antigravity)
        #expect(ProcessLinker.harness(launchedBy: "env FOO=1 exec codex exec") == .codex)
        #expect(ProcessLinker.harness(launchedBy: "swift build") == nil)
        #expect(ProcessLinker.harness(launchedBy: "") == nil)
    }

    // MARK: - The variable table

    @Test("the variable table is deduplicated and stable")
    func variableTable() {
        let all = SessionEnvironmentVariables.allSessionIDVariables
        #expect(all.count == Set(all).count)
        #expect(all.contains(SessionEnvironmentVariables.claudeSessionID))
        #expect(SessionEnvironmentVariables.harnesses(namedBy: SessionEnvironmentVariables.claudeSessionID)
            == [.claudeCode, .claudeCowork])
        #expect(SessionEnvironmentVariables.harnesses(namedBy: "PATH").isEmpty)

        // Own harness first, then everything else, with nothing listed twice.
        let forCodex = SessionEnvironmentVariables.sessionIDVariables(for: .codex)
        #expect(forCodex.prefix(2) == [
            SessionEnvironmentVariables.codexSessionID,
            SessionEnvironmentVariables.codexThreadID,
        ])
        #expect(forCodex.count == Set(forCodex).count)
        #expect(Set(forCodex) == Set(all))

        // A harness with no variable of its own still consults every other's.
        #expect(SessionEnvironmentVariables.sessionIDVariables(for: .geminiCLI) == all)
    }
}
