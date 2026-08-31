import Foundation
import Testing
@testable import AgentSessionLive

@Suite("RegistrySnapshot")
struct RegistrySnapshotTests {
    /// Counts how many times the expensive read actually ran.
    private final class Reads: @unchecked Sendable {
        var count = 0
    }

    @Test("one read answers for every session in a pass")
    func readOnce() {
        let tree = TemporaryTree()
        let file = tree.write("first", to: "registry.json").path
        let snapshot = RegistrySnapshot<String>()
        let reads = Reads()

        // Six hundred sessions asking the same question is the case this
        // exists for: it is one fact about the machine, not six hundred.
        let answers = (0..<600).map { _ in
            snapshot.value(at: file) {
                reads.count += 1
                return (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            }
        }
        #expect(answers.allSatisfy { $0 == "first" })
        #expect(reads.count == 1)
    }

    @Test("a file that moved is read again, whatever the window says")
    func stampWins() throws {
        let tree = TemporaryTree()
        let file = tree.file("registry.json").path
        tree.write("first", to: "registry.json")
        let snapshot = RegistrySnapshot<String>(lifetime: 3600)
        let read = { (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }

        #expect(snapshot.value(at: file, read: read) == "first")
        // Same size, so only the mtime separates them — which is exactly what
        // a registry rewritten under its own lock looks like.
        tree.write("après", to: "registry.json")
        #expect(snapshot.value(at: file, read: read) == "après")
    }

    @Test("a file that appears invalidates the answer that it was not there")
    func missingThenPresent() {
        let tree = TemporaryTree()
        let file = tree.file("registry.json").path
        let snapshot = RegistrySnapshot<String?>(lifetime: 3600)
        let read = { try? String(contentsOfFile: file, encoding: .utf8) }

        #expect(snapshot.value(at: file, read: read) == nil)
        tree.write("arrived", to: "registry.json")
        #expect(snapshot.value(at: file, read: read) == "arrived")
    }

    @Test("the window expires even when nothing about the file moved")
    func windowExpires() {
        let tree = TemporaryTree()
        let file = tree.write("stable", to: "registry.json").path
        let snapshot = RegistrySnapshot<Int>(lifetime: 1)
        let reads = Reads()
        let read = { reads.count += 1; return reads.count }
        let start = Date()

        #expect(snapshot.value(at: file, now: start, read: read) == 1)
        #expect(snapshot.value(at: file, now: start.addingTimeInterval(0.5), read: read) == 1)
        // A change a stamp cannot see — an entry rewritten in place under an
        // unchanged directory — is picked up here and nowhere else.
        #expect(snapshot.value(at: file, now: start.addingTimeInterval(1.5), read: read) == 2)
    }

    @Test("a zero window is no cache at all")
    func zeroLifetime() {
        let tree = TemporaryTree()
        let file = tree.write("stable", to: "registry.json").path
        let snapshot = RegistrySnapshot<Int>(lifetime: 0)
        let reads = Reads()

        for expected in 1...3 {
            #expect(snapshot.value(at: file) { reads.count += 1; return reads.count } == expected)
        }
    }
}
