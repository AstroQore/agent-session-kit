import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

@Suite("SessionKey")
struct SessionKeyTests {
    @Test("the canonical form is harness rawValue, colon, id")
    func description() {
        let key = SessionKey(harness: .claudeCode, sessionID: "abc")
        #expect(key.description == "claudeCode:abc")
    }

    @Test("every harness round-trips through its string form", arguments: Harness.allCases)
    func roundTripsEveryHarness(_ harness: Harness) {
        let key = SessionKey(harness: harness, sessionID: "11111111-2222-3333-4444-555555555555")
        #expect(SessionKey(string: key.description) == key)
    }

    @Test("an id containing colons survives, because only the first colon splits")
    func idsWithColons() {
        let key = SessionKey(harness: .antigravity, sessionID: "conv:42:cli")
        #expect(key.description == "antigravity:conv:42:cli")

        let parsed = SessionKey(string: key.description)
        #expect(parsed == key)
        #expect(parsed?.sessionID == "conv:42:cli")
    }

    @Test("malformed strings parse to nil", arguments: [
        "",
        "noColon",
        "claudeCode:",
        ":abc",
        "notAHarness:abc",
        "Claude Code:abc",
    ])
    func malformed(_ string: String) {
        #expect(SessionKey(string: string) == nil)
    }

    @Test("keys differing only by harness are different keys")
    func harnessIsPartOfIdentity() {
        let shared = "11111111-2222-3333-4444-555555555555"
        let a = SessionKey(harness: .codex, sessionID: shared)
        let b = SessionKey(harness: .claudeCode, sessionID: shared)
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }

    @Test("keys round-trip through JSON")
    func codable() throws {
        let key = SessionKey(harness: .grokBuild, sessionID: "session:with:colons")
        let data = try JSONEncoder().encode(key)
        #expect(try JSONDecoder().decode(SessionKey.self, from: data) == key)
    }
}

@Suite("ParentLink")
struct ParentLinkTests {
    @Test("every case round-trips through JSON", arguments: [
        ParentLink.subagent(toolUseID: "toolu_123"),
        .subagent(toolUseID: nil),
        .spawnedProcess,
        .envInherited,
        .manual,
    ])
    func codable(_ link: ParentLink) throws {
        let data = try JSONEncoder().encode(link)
        #expect(try JSONDecoder().decode(ParentLink.self, from: data) == link)
    }
}
