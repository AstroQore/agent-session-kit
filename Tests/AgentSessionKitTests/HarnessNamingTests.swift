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
                "Cursor"
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
                "geminiCLI", "antigravity", "grokBuild", "cursor"
            ]
        )
    }

    /// Every provider's default harness has to be a real case, and the two
    /// Codex surfaces are the only pair that shares a provider.
    func testEveryProviderHasADefaultHarness() {
        XCTAssertEqual(
            SessionProvider.allCases.map(\.defaultHarness),
            [.claudeCode, .claudeCowork, .codex, .grokBuild, .cursor, .geminiCLI, .antigravity]
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
    }
}
