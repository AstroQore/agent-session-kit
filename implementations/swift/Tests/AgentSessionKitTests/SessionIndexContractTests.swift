import XCTest
@testable import AgentSessionKit

/// The session index schema is shared with the Rust lane through
/// `contracts/storage/session-index-v5.sql`. Nothing generates one lane from
/// the other, so without a check the two drift silently: a column added in
/// Swift would simply be invisible to a Rust reader that still believes it
/// understands version 5.
///
/// The Rust lane has the mirror of this test — it builds a database straight
/// from the contract file and opens it with its reader.
final class SessionIndexContractTests: XCTestCase {
    /// `implementations/swift/Tests/AgentSessionKitTests/<this file>` →
    /// five levels up.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contractSQL() throws -> String {
        try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("contracts/storage/session-index-v5.sql"),
            encoding: .utf8
        )
    }

    /// The version this lane stamps is the version the contract declares.
    func testSchemaVersionMatchesTheContract() throws {
        let sql = try contractSQL()
        let declared = sql
            .split(separator: "\n")
            .compactMap { line -> Int? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("PRAGMA user_version = ") else { return nil }
                return Int(
                    trimmed
                        .dropFirst("PRAGMA user_version = ".count)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "; "))
                )
            }
            .first
        XCTAssertEqual(declared, SessionIndexStore.schemaVersion)
    }

    /// Every object this lane creates is named in the contract, and every
    /// object the contract names is created by this lane. Compared as sorted
    /// object names rather than raw text so that formatting differences do
    /// not fail the build, but a real addition or removal does.
    func testCreatedObjectsMatchTheContract() throws {
        let contractObjects = Self.createdObjectNames(in: try contractSQL())
        let swiftObjects = Self.createdObjectNames(in: SessionIndexStore.schemaSQLForContractTests)
        XCTAssertFalse(contractObjects.isEmpty, "contract declares no objects")
        XCTAssertEqual(
            swiftObjects,
            contractObjects,
            "session index schema drifted from contracts/storage/session-index-v5.sql"
        )
    }

    /// `CREATE [UNIQUE] INDEX|TABLE|VIRTUAL TABLE|TRIGGER [IF NOT EXISTS] <name>`
    /// reduced to the bare object name.
    private static func createdObjectNames(in sql: String) -> [String] {
        var names: [String] = []
        for line in sql.split(separator: "\n") {
            var tokens = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard tokens.first?.uppercased() == "CREATE" else { continue }
            tokens.removeFirst()
            while let next = tokens.first?.uppercased(),
                  ["UNIQUE", "VIRTUAL", "TABLE", "INDEX", "TRIGGER", "IF", "NOT", "EXISTS"]
                      .contains(next) {
                tokens.removeFirst()
            }
            guard let name = tokens.first else { continue }
            names.append(name.split(separator: "(").first.map(String.init) ?? name)
        }
        return names.sorted()
    }
}
