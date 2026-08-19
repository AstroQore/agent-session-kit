import XCTest
@testable import AgentSessionKit

/// The release contract, enforced as a test.
///
/// `AgentSessionKitInfo.version` is the only version number a statically
/// linked host can read, and `CHANGELOG.md` is the only place a human
/// reads. If they disagree, one of them is lying to somebody. These tests
/// make the disagreement fail `swift test` — on a pull request, long
/// before it can fail a tag.
final class AgentSessionKitInfoTests: XCTestCase {
    /// The repository root, resolved from this file rather than from the
    /// working directory: `swift test` can be invoked from anywhere, and
    /// the package deliberately ships no test resource for this.
    /// `Tests/AgentSessionKitTests/<this file>` → three levels up.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgentSessionKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }

    private func changelog() throws -> String {
        let url = repositoryRoot.appendingPathComponent("CHANGELOG.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `## [X.Y.Z]` heading, in file order. `[Unreleased]` has no
    /// version number and so never matches.
    private func releasedVersions(in changelog: String) -> [String] {
        var versions: [String] = []
        for line in changelog.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("## [") else { continue }
            let body = line.dropFirst(4)
            guard let close = body.firstIndex(of: "]") else { continue }
            let candidate = String(body[body.startIndex..<close])
            if isSemver(candidate) { versions.append(candidate) }
        }
        return versions
    }

    private func isSemver(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }) else { return false }
            // No leading zeros: "0" is fine, "01" is not.
            if part.count > 1 && part.hasPrefix("0") { return false }
        }
        return true
    }

    func testVersionIsSemver() {
        XCTAssertTrue(
            isSemver(AgentSessionKitInfo.version),
            "AgentSessionKitInfo.version must be a bare X.Y.Z, got \(AgentSessionKitInfo.version)"
        )
    }

    /// The load-bearing one. The newest `## [X.Y.Z]` section in the
    /// changelog is what this tree releases as; the constant has to say the
    /// same thing. Cutting a release means moving `[Unreleased]` down into
    /// a dated section *and* bumping the constant — see `RELEASING.md`.
    func testVersionMatchesTopReleasedChangelogSection() throws {
        let versions = releasedVersions(in: try changelog())
        guard let newest = versions.first else {
            return XCTFail("CHANGELOG.md has no `## [X.Y.Z]` section")
        }
        XCTAssertEqual(
            AgentSessionKitInfo.version,
            newest,
            """
            AgentSessionKitInfo.version (\(AgentSessionKitInfo.version)) and the top \
            released CHANGELOG.md section (\(newest)) disagree. Both move in the \
            release commit; see RELEASING.md.
            """
        )
    }

    /// A changelog that lists the same version twice, or lists an older one
    /// above a newer one, would make "the top section" ambiguous.
    func testChangelogVersionsDescendAndAreUnique() throws {
        let versions = releasedVersions(in: try changelog())
        XCTAssertEqual(Set(versions).count, versions.count, "duplicate version headings in CHANGELOG.md")
        let ordered = versions.map { $0.split(separator: ".").compactMap { Int($0) } }
        for (newer, older) in zip(ordered, ordered.dropFirst()) {
            XCTAssertTrue(
                newer.lexicographicallyPrecedes(older) == false && newer != older,
                "CHANGELOG.md sections must run newest first, found \(newer) above \(older)"
            )
        }
    }

    func testRepositoryURL() {
        XCTAssertEqual(
            AgentSessionKitInfo.repositoryURL.absoluteString,
            "https://github.com/AstroQore/agent-session-kit"
        )
    }

    /// Tags are bare, so the release page is the tag page.
    func testReleaseNotesURLPointsAtTheBareTag() {
        XCTAssertEqual(
            AgentSessionKitInfo.releaseNotesURL(for: "0.3.0").absoluteString,
            "https://github.com/AstroQore/agent-session-kit/releases/tag/0.3.0"
        )
        XCTAssertEqual(
            AgentSessionKitInfo.bundledReleaseNotesURL.absoluteString,
            "https://github.com/AstroQore/agent-session-kit/releases/tag/\(AgentSessionKitInfo.version)"
        )
    }

    /// A caller handing over a tag read out of an API response should not
    /// have to know whether this project writes `v` or not.
    func testReleaseNotesURLToleratesAVPrefixAndWhitespace() {
        XCTAssertEqual(
            AgentSessionKitInfo.releaseNotesURL(for: " v0.3.0 ").absoluteString,
            "https://github.com/AstroQore/agent-session-kit/releases/tag/0.3.0"
        )
        XCTAssertEqual(AgentSessionKitInfo.normalizedTag("v1.2.3"), "1.2.3")
        // Not a version prefix — a tag that genuinely starts with a letter
        // keeps every character it has.
        XCTAssertEqual(AgentSessionKitInfo.normalizedTag("version-1"), "version-1")
    }

    /// An empty or unusable tag falls back to the releases index rather
    /// than building a 404.
    func testReleaseNotesURLFallsBackForAnEmptyTag() {
        XCTAssertEqual(
            AgentSessionKitInfo.releaseNotesURL(for: "   ").absoluteString,
            "https://github.com/AstroQore/agent-session-kit/releases"
        )
    }
}
