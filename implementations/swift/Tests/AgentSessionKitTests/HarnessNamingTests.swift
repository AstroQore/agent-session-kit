import XCTest
@testable import AgentSessionKit

/// Naming only. Whatever a host maps a harness onto — a quota, a company, a
/// price table — is that host's axis, and its tests live with it.
final class HarnessNamingTests: XCTestCase {
    func testDisplayNamesMatchTheCatalogTable() {
        XCTAssertEqual(
            Harness.allCases.map(\.displayName),
            [
                "Codex",
                "ChatGPT Work",
                "Claude Code",
                "Claude Cowork",
                "Gemini CLI",
                "AntiGravity",
                "Grok Build",
                "Cursor",
                "Grok Bot",
                "Muse Code",
                "Muse",
                "Devin",
                "Mistral Vibe"
            ]
        )
    }

    /// Gemini Web is a billing-side SubProvider with no local sessions at
    /// all. The deprecated CLI owns the transcripts under `~/.gemini/tmp`,
    /// and labelling those "Gemini Web" would put a billing name on a
    /// usage row.
    func testGeminiHarnessIsNamedForTheCLINotTheWebSubProvider() {
        XCTAssertEqual(Harness.geminiCLI.displayName, HarnessCatalog.geminiCLI)
        XCTAssertEqual(Harness.geminiCLI.displayName, "Gemini CLI")
    }

    func testRawValuesAreStableStorageKeys() {
        // These land in SQLite and in host scan caches; renaming one
        // silently orphans every stored row.
        XCTAssertEqual(
            Harness.allCases.map(\.rawValue),
            [
                "codex", "chatgptWork", "claudeCode", "claudeCowork",
                "geminiCLI", "antigravity", "grokBuild", "cursor", "grokBot", "museCode",
                "museAgent", "devin", "mistralVibe"
            ]
        )
    }

    /// Every provider's default harness has to be a real case, and the two
    /// Codex surfaces are the only pair that shares a provider.
    func testEveryProviderHasADefaultHarness() {
        XCTAssertEqual(
            SessionProvider.allCases.map(\.defaultHarness),
            [.claudeCode, .claudeCowork, .codex, .grokBuild, .cursor, .geminiCLI,
             .antigravity, .grokBot, .museCode, .devin, .mistralVibe, .museAgent]
        )
        XCTAssertEqual(
            Set(Harness.allCases).subtracting(SessionProvider.allCases.map(\.defaultHarness)),
            [.chatgptWork],
            "ChatGPT Work is the one harness a provider alone cannot name; it comes from the "
                + "rollout's own originator."
        )
    }

    func testProviderDisplayNamesComeFromTheHarnessCatalog() {
        XCTAssertEqual(SessionProvider.claude.displayName, HarnessCatalog.claudeCode)
        XCTAssertEqual(SessionProvider.claudeCowork.displayName, HarnessCatalog.claudeCowork)
        XCTAssertEqual(SessionProvider.antigravity.displayName, HarnessCatalog.antigravity)
        XCTAssertEqual(SessionProvider.grokBot.displayName, HarnessCatalog.grokBot)
        XCTAssertEqual(SessionProvider.muse.displayName, HarnessCatalog.museCode)
        XCTAssertEqual(Harness.museCode.displayName, "Muse Code")
        XCTAssertEqual(SessionProvider.devin.displayName, HarnessCatalog.devin)
        XCTAssertEqual(Harness.devin.displayName, "Devin")
        XCTAssertEqual(SessionProvider.mistralVibe.displayName, HarnessCatalog.mistralVibe)
        XCTAssertEqual(Harness.mistralVibe.displayName, "Mistral Vibe")
        XCTAssertEqual(SessionProvider.museAgent.displayName, HarnessCatalog.museAgent)
        XCTAssertEqual(Harness.museAgent.displayName, "Muse")
    }

    /// The provider raw values are storage keys too.
    func testNewProviderRawValuesAreStable() {
        XCTAssertEqual(SessionProvider.devin.rawValue, "devin")
        XCTAssertEqual(SessionProvider.mistralVibe.rawValue, "mistralVibe")
        XCTAssertEqual(SessionProvider.museAgent.rawValue, "museAgent")
        XCTAssertEqual(Harness.museAgent.rawValue, "museAgent")
    }

    /// Muse (the desktop agent app) and Muse Code (the `muse` CLI) share a
    /// company and a word, and nothing on disk. Collapsing them would put a
    /// CLI's name on a cloud conversation.
    func testMuseCodeAndMuseAreDistinctHarnesses() {
        XCTAssertNotEqual(Harness.museCode, Harness.museAgent)
        XCTAssertNotEqual(SessionProvider.muse, SessionProvider.museAgent)
        XCTAssertEqual(SessionProvider.muse.defaultHarness, .museCode)
        XCTAssertEqual(SessionProvider.museAgent.defaultHarness, .museAgent)
    }

    /// Grok Build and Grok Bot share a company and nothing else: one is a
    /// local CLI with rollouts on disk, the other a cloud bot whose client
    /// caches conversations here. Collapsing them would put a CLI's name on
    /// a server's transcript.
    func testGrokBuildAndGrokBotAreDistinctHarnesses() {
        XCTAssertNotEqual(Harness.grokBuild, Harness.grokBot)
        XCTAssertEqual(Harness.grokBuild.displayName, "Grok Build")
        XCTAssertEqual(Harness.grokBot.displayName, "Grok Bot")
    }
}
