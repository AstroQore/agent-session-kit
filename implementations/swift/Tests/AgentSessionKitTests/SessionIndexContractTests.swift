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

    /// Every statement this lane creates appears in the contract, and every
    /// statement the contract declares is created by this lane — compared as
    /// whole normalised definitions, so a changed column type, constraint,
    /// index expression, FTS tokenizer, or trigger body fails here too.
    ///
    /// Normalisation collapses whitespace and drops `IF NOT EXISTS`, because
    /// those differ between a file meant to be run once and a writer that
    /// re-runs on every open. Nothing semantic is normalised away.
    func testCreatedStatementsMatchTheContract() throws {
        let contract = Self.createStatements(in: try contractSQL())
        let swift = Self.createStatements(in: SessionIndexStore.schemaSQLForContractTests)
        XCTAssertFalse(contract.isEmpty, "contract declares no statements")
        XCTAssertEqual(
            swift,
            contract,
            "session index schema drifted from contracts/storage/session-index-v5.sql"
        )
    }

    /// Whole `CREATE …;` statements, normalised and sorted.
    private static func createStatements(in sql: String) -> [String] {
        sql
            .split(separator: ";")
            .map { statement in
                statement
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                    .replacingOccurrences(of: "IF NOT EXISTS ", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { $0.uppercased().hasPrefix("CREATE ") }
            .sorted()
    }
}
