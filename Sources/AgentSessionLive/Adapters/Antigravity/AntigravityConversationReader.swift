import AgentSessionKit
import Foundation
import SQLite3

/// Read-only access to one AntiGravity conversation database.
///
/// The store is `~/.gemini/antigravity{,-cli}/conversations/<uuid>.db`, one
/// SQLite file per conversation, in WAL mode, held open by a running `agy` or
/// by the IDE's language server. Reading it is `AgentSessionKit`'s
/// `LiveSQLiteReader` problem — open read-only, snapshot the file plus its
/// journal siblings when that is not enough — and this type is only the
/// schema on top of it:
///
/// ```text
/// trajectory_meta(trajectory_id, cascade_id, trajectory_type, source)
/// steps(idx PK, step_type, status, has_subtrajectory, metadata, error_details,
///       permissions, task_details, render_info, step_payload, step_format)
/// parent_references(idx, data)
/// gen_metadata, executor_metadata, trajectory_metadata_blob, battle_mode_infos
/// ```
///
/// The critical property of `steps` is that rows **mutate**: a tool call is
/// one row whose `status` walks `PENDING → RUNNING → DONE`, not two records.
/// That is why every read here is by `idx` range rather than "everything after
/// the cursor", and why ``AntigravityConversationTailer`` diffs what it gets
/// back.
///
/// Nothing here throws. A database that cannot be read yields `nil`, an
/// undecodable payload yields a row with no payload, and neither sinks a
/// session list.
public struct AntigravityConversationReader: Sendable {
    /// The `<uuid>.db` this reader is about.
    public let databaseURL: URL

    /// Rows returned by a single ``steps(fromIndex:limit:)`` call. A
    /// conversation with more open rows than this is pathological, and
    /// truncating keeps a poll from allocating without bound.
    public static let maxRowsPerPoll = 512

    /// Creates a reader. The file is not opened until something is asked of
    /// it.
    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    /// The conversation id, taken from the file name.
    public var conversationID: String {
        databaseURL.deletingPathExtension().lastPathComponent
    }

    // MARK: - trajectory_meta

    /// The single `trajectory_meta` row, when the table has one.
    public struct TrajectoryMeta: Hashable, Sendable {
        /// The trajectory these steps belong to.
        public let trajectoryID: String?
        /// The cascade the trajectory belongs to.
        public let cascadeID: String?
        /// What kind of trajectory it is.
        public let trajectoryType: AntigravityTrajectoryType?
        /// Which surface opened it — ``AntigravityTrajectorySource/cli`` for
        /// `agy`, ``AntigravityTrajectorySource/subagent`` for a child.
        public let source: AntigravityTrajectorySource?
        /// `trajectory_type` verbatim, for a value the table does not name.
        public let rawTrajectoryType: Int
        /// `source` verbatim.
        public let rawSource: Int

        /// Creates a row.
        public init(
            trajectoryID: String?,
            cascadeID: String?,
            rawTrajectoryType: Int,
            rawSource: Int
        ) {
            self.trajectoryID = trajectoryID
            self.cascadeID = cascadeID
            self.rawTrajectoryType = rawTrajectoryType
            self.rawSource = rawSource
            self.trajectoryType = AntigravityTrajectoryType(rawValue: rawTrajectoryType)
            self.source = AntigravityTrajectorySource(rawValue: rawSource)
        }
    }

    /// The conversation's `trajectory_meta` row, or `nil` when the table is
    /// empty or unreadable.
    public func trajectoryMeta() -> TrajectoryMeta? {
        LiveSQLiteReader.read(at: databaseURL) { database in
            let statement = try LiveSQLiteReader.prepare(
                database,
                "SELECT trajectory_id, cascade_id, trajectory_type, source FROM trajectory_meta LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw LiveSQLiteReader.ReadError.statement
            }
            return TrajectoryMeta(
                trajectoryID: LiveSQLiteReader.text(statement, 0),
                cascadeID: LiveSQLiteReader.text(statement, 1),
                rawTrajectoryType: Int(sqlite3_column_int64(statement, 2)),
                rawSource: Int(sqlite3_column_int64(statement, 3))
            )
        }
    }

    // MARK: - steps

    /// One `steps` row, with its payload decoded when it was asked for.
    public struct StepRow: Hashable, Sendable {
        /// The primary key, and the conversation's own ordering.
        public let idx: Int
        /// `step_type` verbatim.
        public let rawStepType: Int
        /// `status` verbatim.
        public let rawStatus: Int
        /// `has_subtrajectory`: the row spawned a child trajectory.
        public let hasSubtrajectory: Bool
        /// The decoded `step_payload`, when one was present and decodable.
        public let payload: AntigravityStepPayload?

        /// Creates a row.
        public init(
            idx: Int,
            rawStepType: Int,
            rawStatus: Int,
            hasSubtrajectory: Bool,
            payload: AntigravityStepPayload?
        ) {
            self.idx = idx
            self.rawStepType = rawStepType
            self.rawStatus = rawStatus
            self.hasSubtrajectory = hasSubtrajectory
            self.payload = payload
        }

        /// The typed step type, or `nil` for a value this build does not name.
        public var stepType: AntigravityStepType? { AntigravityStepType(rawValue: rawStepType) }

        /// The typed status. An unnamed value reads as
        /// ``AntigravityStepStatus/unspecified``, which is terminal — an
        /// unknown status must not leave a tool call open forever.
        public var status: AntigravityStepStatus {
            AntigravityStepStatus(rawValue: rawStatus) ?? .unspecified
        }

        /// What a board groups this row by, or `nil` when it is not a tool
        /// call.
        public var toolKind: ToolKind? { stepType?.toolKind }

        /// A display name: the payload's own tool name when it carried one,
        /// otherwise the step type's label.
        public var toolName: String {
            payload?.toolCall?.name ?? AntigravityStepType.label(rawValue: rawStepType)
        }
    }

    /// Rows with `idx >= fromIndex`, oldest first.
    ///
    /// Reading by index rather than "after the cursor" is the whole point: a
    /// row already consumed can still change, so a tailer re-reads the window
    /// that might have moved and diffs it.
    ///
    /// - Parameters:
    ///   - fromIndex: Lowest `idx` to return. Negative is treated as zero.
    ///   - limit: Upper bound on rows returned.
    ///   - decodePayloads: When `false`, payload blobs are not read at all —
    ///     for a caller that only needs statuses.
    public func steps(
        fromIndex: Int = 0,
        limit: Int = maxRowsPerPoll,
        decodePayloads: Bool = true
    ) -> [StepRow]? {
        let floor = max(0, fromIndex)
        let cap = max(0, min(limit, LiveSQLiteReader.maxRows))
        guard cap > 0 else { return [] }
        let columns = decodePayloads
            ? "idx, step_type, status, has_subtrajectory, step_payload"
            : "idx, step_type, status, has_subtrajectory, NULL"
        return LiveSQLiteReader.read(at: databaseURL) { database in
            let statement = try LiveSQLiteReader.prepare(
                database,
                "SELECT \(columns) FROM steps WHERE idx >= ? ORDER BY idx LIMIT ?"
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, sqlite3_int64(floor))
            sqlite3_bind_int64(statement, 2, sqlite3_int64(cap))
            var out: [StepRow] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let blob = decodePayloads ? LiveSQLiteReader.blob(statement, 4) : nil
                out.append(StepRow(
                    idx: Int(sqlite3_column_int64(statement, 0)),
                    rawStepType: Int(sqlite3_column_int64(statement, 1)),
                    rawStatus: Int(sqlite3_column_int64(statement, 2)),
                    hasSubtrajectory: sqlite3_column_int64(statement, 3) != 0,
                    payload: blob.flatMap(AntigravityStepPayload.decode)
                ))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE || out.count >= cap else {
                throw LiveSQLiteReader.ReadError.statement
            }
            return out
        }
    }

    /// How many `steps` rows the conversation has, or `nil` when the database
    /// could not be read.
    public func stepCount() -> Int? {
        LiveSQLiteReader.read(at: databaseURL) { database in
            let statement = try LiveSQLiteReader.prepare(database, "SELECT COUNT(*) FROM steps")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw LiveSQLiteReader.ReadError.statement
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// The highest `idx` in `steps`, or `nil` for an empty or unreadable
    /// table.
    public func lastStepIndex() -> Int? {
        LiveSQLiteReader.read(at: databaseURL) { database in
            let statement = try LiveSQLiteReader.prepare(database, "SELECT MAX(idx) FROM steps")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) != SQLITE_NULL
            else { throw LiveSQLiteReader.ReadError.statement }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - gen_metadata

    /// Turns decoded from the end of `gen_metadata` when the model is looked
    /// for. Two or three is usually enough; the window covers a tail of turns
    /// a router served without naming one.
    public static let modelWindow = 8

    /// The newest model `gen_metadata` names, or `nil` when no turn has
    /// billed against one yet.
    ///
    /// `steps` does not record the model — a tool call and a reply look the
    /// same whoever served them — so this table is the only place in the
    /// store the answer exists. Only the newest few rows are decoded: a
    /// conversation's model can change mid-thread and the current one is what
    /// a board shows, so reading the whole usage history to find it would be
    /// both slower and wrong.
    ///
    /// The blob is read through ``AgentSessionKit/AntigravityGenMetadataReader/modelNames(blob:)``
    /// rather than as a whole turn. Recent builds write usage records with no
    /// wall-clock timestamp, which a turn cannot be without and a model can.
    public func recentModel(limit: Int = modelWindow) -> String? {
        let cap = max(1, min(limit, LiveSQLiteReader.maxRows))
        return LiveSQLiteReader.read(at: databaseURL) { database in
            let statement = try LiveSQLiteReader.prepare(
                database, "SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT ?"
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, sqlite3_int64(cap))
            var found: String?
            var result = sqlite3_step(statement)
            var seen = 0
            while result == SQLITE_ROW, seen < cap {
                seen += 1
                defer { result = sqlite3_step(statement) }
                guard found == nil, let data = LiveSQLiteReader.blob(statement, 0)
                else { continue }
                found = AntigravityGenMetadataReader.modelNames(blob: data).display
            }
            guard result == SQLITE_DONE || seen >= cap else {
                throw LiveSQLiteReader.ReadError.statement
            }
            return found
        } ?? nil
    }

    // MARK: - parent_references

    /// `parent_references`, keyed by `idx`.
    ///
    /// Best-effort and deliberately undecoded: the blob's shape is not in any
    /// descriptor this adapter was built against, so it is handed back raw for
    /// a caller that learns more than we did. The parent edge a board actually
    /// draws comes from `conversation_summaries.parent_conversation_id`.
    public func parentReferences() -> [Int: Data] {
        let rows: [Int: Data]? = LiveSQLiteReader.read(at: databaseURL) { database in
            let statement = try LiveSQLiteReader.prepare(
                database, "SELECT idx, data FROM parent_references ORDER BY idx"
            )
            defer { sqlite3_finalize(statement) }
            var out: [Int: Data] = [:]
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW, out.count < LiveSQLiteReader.maxRows {
                if let data = LiveSQLiteReader.blob(statement, 1) {
                    out[Int(sqlite3_column_int64(statement, 0))] = data
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE || out.count >= LiveSQLiteReader.maxRows else {
                throw LiveSQLiteReader.ReadError.statement
            }
            return out
        }
        return rows ?? [:]
    }
}

/// The CLI's side index of every conversation it knows about:
/// `~/.gemini/antigravity-cli/conversation_summaries.db`.
///
/// This is the only store that names a conversation's title, its workspace,
/// its parent, and whether it is busy right now — none of which is anywhere in
/// the conversation database itself. It is also the store the IDE surface
/// borrows, because the IDE writes `agyhub_summaries_proto.pb` instead and
/// nothing here decodes that.
///
/// Two things it is not. It is not complete: on a real machine it can name a
/// fraction of the databases on disk, so discovery unions it with a file walk
/// rather than trusting it as the roll. And it is not fresh: `last_modified_time`
/// lags the `-wal` mtime, so liveness asks the file system first.
public struct AntigravitySummariesReader: Sendable {
    /// The `conversation_summaries.db` this reader is about.
    public let databaseURL: URL

    /// Creates a reader.
    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    /// One `conversation_summaries` row, reduced to what the live layer uses.
    public struct Summary: Hashable, Sendable {
        /// The conversation's uuid, lower-cased.
        public let conversationID: String
        /// A label for the thread. `title` is empty on every build seen so
        /// far and the usable label lands in `preview`, often as a markdown
        /// heading, so both are consulted and the heading markers stripped.
        public let title: String?
        /// How many `steps` rows the index believes the conversation has.
        public let stepCount: Int
        /// When the index last saw the conversation change.
        public let lastModified: Date?
        /// `workspace_uris`, decoded from its JSON array. Frequently empty.
        public let workspaceURIs: [String]
        /// The conversation that spawned this one, when it was spawned.
        public let parentConversationID: String?
        /// How deep in a sub-agent tree the conversation sits.
        public let nestingDepth: Int
        /// `not_fully_idle`: the conversation is doing something right now.
        public let notFullyIdle: Bool
        /// `killed`: the conversation was terminated rather than finished.
        public let killed: Bool
        /// The agent behind it, e.g. `agy`.
        public let agentName: String?

        /// Creates a summary.
        public init(
            conversationID: String,
            title: String?,
            stepCount: Int,
            lastModified: Date?,
            workspaceURIs: [String],
            parentConversationID: String?,
            nestingDepth: Int,
            notFullyIdle: Bool,
            killed: Bool,
            agentName: String?
        ) {
            self.conversationID = conversationID
            self.title = title
            self.stepCount = stepCount
            self.lastModified = lastModified
            self.workspaceURIs = workspaceURIs
            self.parentConversationID = parentConversationID
            self.nestingDepth = nestingDepth
            self.notFullyIdle = notFullyIdle
            self.killed = killed
            self.agentName = agentName
        }

        /// The first workspace as a plain path: `file:///Users/example/proj`
        /// becomes `/Users/example/proj`, percent-decoded.
        public var workspacePath: String? {
            AntigravitySummariesReader.path(fromURI: workspaceURIs.first)
        }
    }

    /// Every row the index holds, newest first, optionally filtered.
    ///
    /// The `last_modified_time` column is a text datetime, so the cutoff is
    /// applied in Swift rather than in SQL: a build that writes a different
    /// format would otherwise silently match nothing. A row with
    /// `not_fully_idle` set is returned whatever its timestamp says — a
    /// conversation that is busy right now is the one row a board must not
    /// lose.
    ///
    /// Returns `[]` when the store is missing, which is a normal state and
    /// not an error.
    public func summaries(modifiedSince: Date? = nil, limit: Int = LiveSQLiteReader.maxRows)
        -> [Summary] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        let all = readAll(limit: limit) ?? []
        guard let modifiedSince else { return all }
        return all.filter { summary in
            if summary.notFullyIdle { return true }
            guard let modified = summary.lastModified else { return false }
            return modified >= modifiedSince
        }
    }

    /// The columns this reader wants, and the shorter set an older build may
    /// be all that offers. Asking for a column a build never had fails the
    /// whole statement, and a missing title is not a reason to lose a session.
    static let fullColumns = """
        conversation_id, title, preview, step_count, last_modified_time, workspace_uris, \
        parent_conversation_id, nesting_depth, not_fully_idle, killed, agent_name
        """
    static let minimalColumns = """
        conversation_id, title, preview, step_count, last_modified_time, workspace_uris, \
        '', 0, 0, 0, ''
        """

    private func readAll(limit: Int) -> [Summary]? {
        if let rows = query(columns: Self.fullColumns, limit: limit) { return rows }
        return query(columns: Self.minimalColumns, limit: limit)
    }

    private func query(columns: String, limit: Int) -> [Summary]? {
        LiveSQLiteReader.read(at: databaseURL) { database in
            let statement = try LiveSQLiteReader.prepare(
                database,
                """
                SELECT \(columns) FROM conversation_summaries
                 ORDER BY last_modified_time DESC LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, sqlite3_int64(max(0, min(limit, LiveSQLiteReader.maxRows))))
            var out: [Summary] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW, out.count < LiveSQLiteReader.maxRows {
                defer { result = sqlite3_step(statement) }
                guard let id = LiveSQLiteReader.text(statement, 0), !id.isEmpty else { continue }
                out.append(Summary(
                    conversationID: id.lowercased(),
                    title: Self.label(
                        LiveSQLiteReader.text(statement, 1),
                        LiveSQLiteReader.text(statement, 2)
                    ),
                    stepCount: Int(sqlite3_column_int64(statement, 3)),
                    lastModified: Self.timestamp(LiveSQLiteReader.text(statement, 4)),
                    workspaceURIs: Self.workspaces(LiveSQLiteReader.text(statement, 5)),
                    parentConversationID: Self.identifier(LiveSQLiteReader.text(statement, 6)),
                    nestingDepth: Int(sqlite3_column_int64(statement, 7)),
                    notFullyIdle: sqlite3_column_int64(statement, 8) != 0,
                    killed: sqlite3_column_int64(statement, 9) != 0,
                    agentName: Self.identifier(LiveSQLiteReader.text(statement, 10))
                ))
            }
            guard result == SQLITE_DONE || out.count >= LiveSQLiteReader.maxRows else {
                throw LiveSQLiteReader.ReadError.statement
            }
            return out
        }
    }

    // MARK: - Column shapes

    /// `title` first, `preview` second, with markdown heading markers off the
    /// front of whichever answered.
    static func label(_ title: String?, _ preview: String?) -> String? {
        for candidate in [title, preview] {
            guard let candidate else { continue }
            let stripped = candidate
                .drop(while: { $0 == "#" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty { return stripped }
        }
        return nil
    }

    static func identifier(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return raw
    }

    /// `workspace_uris` is a JSON array of `file://` URIs where it is
    /// populated at all, and an empty string where it is not. A bare path is
    /// accepted too, because the column is untyped.
    static func workspaces(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        if let data = raw.data(using: .utf8),
           let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            return array.compactMap { $0 as? String }.filter { !$0.isEmpty }
        }
        guard !raw.hasPrefix("[") else { return [] }
        return [raw]
    }

    /// `file:///Users/example/agy%20misc` → `/Users/example/agy misc`.
    static func path(fromURI raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.hasPrefix("file://") else { return raw }
        let path = String(raw.dropFirst("file://".count))
        let decoded = path.removingPercentEncoding ?? path
        return decoded.isEmpty ? nil : decoded
    }

    /// `last_modified_time` is `2026-07-16 08:18:19.171238+00:00` — ISO-8601
    /// with a space where the `T` belongs, and a year-1 zero value for
    /// "never".
    static func timestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        var normalized = raw
        if let space = normalized.firstIndex(of: " ") {
            normalized.replaceSubrange(space...space, with: "T")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parsed = formatter.date(from: normalized)
        if parsed == nil {
            formatter.formatOptions = [.withInternetDateTime]
            parsed = formatter.date(from: normalized)
        }
        guard let parsed, parsed.timeIntervalSince1970 > 0 else { return nil }
        return parsed
    }
}
