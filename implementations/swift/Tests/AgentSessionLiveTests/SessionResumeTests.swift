import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

@Suite("SessionResume")
struct SessionResumeTests {
    private static func identity(
        _ harness: Harness,
        id: String = "11111111-2222-3333-4444-555555555555",
        cwd: String? = "/Users/example/code/demo",
        variant: String? = nil
    ) -> SessionIdentity {
        SessionIdentity(
            key: SessionKey(harness: harness, sessionID: id),
            sourcePath: "/Users/example/store/session.jsonl",
            variant: variant,
            cwd: cwd
        )
    }

    // MARK: - The harnesses with a CLI

    @Test("every harness with a CLI produces its own command", arguments: [
        (Harness.claudeCode, "claude --resume 11111111-2222-3333-4444-555555555555"),
        (.codex, "codex resume 11111111-2222-3333-4444-555555555555"),
        (.chatgptWork, "codex resume 11111111-2222-3333-4444-555555555555"),
        (.grokBuild, "grok --resume 11111111-2222-3333-4444-555555555555"),
        (.geminiCLI, "gemini --resume 11111111-2222-3333-4444-555555555555"),
    ])
    func commandPerHarness(_ harness: Harness, _ expected: String) {
        #expect(SessionResume.availability(for: Self.identity(harness)).command == expected)
    }

    @Test("the shell line lands in the session's own working directory")
    func shellLineCarriesCwd() {
        let line = SessionResume.resumeCommand(for: Self.identity(.claudeCode))
        #expect(line == "cd '/Users/example/code/demo' && claude --resume 11111111-2222-3333-4444-555555555555")
    }

    @Test("a session with no recorded cwd resumes where the terminal already is")
    func shellLineWithoutCwd() {
        let line = SessionResume.resumeCommand(for: Self.identity(.codex, cwd: nil))
        #expect(line == "codex resume 11111111-2222-3333-4444-555555555555")
    }

    @Test("a working directory with a quote in it is escaped, not refused")
    func quotedCwd() {
        let identity = Self.identity(.claudeCode, cwd: "/Users/example/it's here")
        let line = SessionResume.resumeCommand(for: identity)
        #expect(line?.hasPrefix("cd '/Users/example/it'\\''s here' && claude --resume") == true)
    }

    // MARK: - The harnesses without one

    @Test("Claude Cowork, Cursor, and Grok Bot cannot be resumed", arguments: [
        Harness.claudeCowork, .cursor, .grokBot,
    ])
    func harnessesWithoutAResume(_ harness: Harness) {
        let availability = SessionResume.availability(for: Self.identity(harness))
        #expect(SessionResume.resumeCommand(for: Self.identity(harness)) == nil)
        #expect(availability.isAvailable == false)
        #expect(SessionResume.isResumable(harness) == false)
        // The reason is what a disabled menu item shows, so it has to say
        // something a person can act on.
        let reason = availability.reason ?? ""
        #expect(!reason.isEmpty)
        #expect(reason != "This session cannot be resumed from the command line.")
    }

    @Test("an AntiGravity CLI conversation resumes and an IDE one explains why not")
    func antigravityVariants() {
        let cli = Self.identity(
            .antigravity, variant: SessionResumeCommandBuilder.antigravityCLIVariant)
        #expect(SessionResume.availability(for: cli).command
            == "agy --conversation 11111111-2222-3333-4444-555555555555")

        let ide = Self.identity(.antigravity, variant: "ide")
        #expect(SessionResume.resumeCommand(for: ide) == nil)
        #expect(SessionResume.availability(for: ide).reason?.contains("CLI sessions") == true)
        // The harness has a CLI even though this session does not qualify.
        #expect(SessionResume.isResumable(.antigravity))
    }

    @Test("a subagent points at its parent rather than at nothing")
    func subagentKey() {
        let identity = Self.identity(
            .claudeCode,
            id: "11111111-2222-3333-4444-555555555555/agent-a1b2c3d4e5f60718",
            variant: ClaudeLiveAdapter.subagentVariant
        )
        #expect(SessionResume.resumeCommand(for: identity) == nil)
        #expect(SessionResume.availability(for: identity).reason?.contains("parent") == true)
    }

    @Test("an id with a shell metacharacter in it is refused, not escaped")
    func refusesAnUnexpectedID() {
        let identity = Self.identity(.claudeCode, id: "abc; rm -rf /")
        #expect(SessionResume.resumeCommand(for: identity) == nil)
        #expect(SessionResume.availability(for: identity).reason?.isEmpty == false)
    }

    // MARK: - The harness/provider join

    @Test("every harness maps to the store its sessions are in")
    func harnessToProvider() {
        #expect(Harness.codex.sessionProvider == .codex)
        #expect(Harness.chatgptWork.sessionProvider == .codex)
        #expect(Harness.claudeCode.sessionProvider == .claude)
        #expect(Harness.claudeCowork.sessionProvider == .claudeCowork)
        #expect(Harness.geminiCLI.sessionProvider == .gemini)
        #expect(Harness.antigravity.sessionProvider == .antigravity)
        #expect(Harness.grokBuild.sessionProvider == .grok)
        #expect(Harness.cursor.sessionProvider == .cursor)
        #expect(Harness.grokBot.sessionProvider == .grokBot)
    }

    @Test("the mapping is the inverse of the provider's default harness")
    func mappingRoundTrips() {
        for provider in SessionProvider.allCases {
            #expect(provider.defaultHarness.sessionProvider == provider)
        }
        // Every harness is accounted for, so a new one cannot be added without
        // deciding which store it reads.
        #expect(Set(Harness.allCases.map(\.sessionProvider)) == Set(SessionProvider.allCases))
    }

    @Test("every harness answers, one way or the other")
    func everyHarnessAnswers() {
        for harness in Harness.allCases {
            let availability = SessionResume.availability(
                for: Self.identity(harness, variant: harness == .antigravity ? "cli" : nil))
            #expect(availability.isAvailable == SessionResume.isResumable(harness))
        }
    }
}
