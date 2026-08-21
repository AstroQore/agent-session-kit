import AgentSessionKit
import Foundation
import SQLite3

@testable import AgentSessionLive

// MARK: - A protobuf writer

/// The inverse of the wire reader: just enough encoder to build a
/// `steps.step_payload` blob shaped like the real thing.
///
/// Synthetic by necessity. A real conversation database carries the most
/// personal text on a developer's machine — prompts, file paths, source — so
/// no fixture in this repository is a copy of one. Every payload the suite
/// reads was written by the suite.
enum AntigravityProto {
    static func varint(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var remaining = value
        while remaining > 0x7F {
            out.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        out.append(UInt8(remaining & 0x7F))
        return out
    }

    static func tag(_ field: Int, _ wire: UInt64) -> [UInt8] {
        varint((UInt64(field) << 3) | wire)
    }

    static func varintField(_ field: Int, _ value: UInt64) -> [UInt8] {
        tag(field, 0) + varint(value)
    }

    static func message(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(UInt64(payload.count)) + payload
    }

    static func string(_ field: Int, _ value: String) -> [UInt8] {
        message(field, [UInt8](value.utf8))
    }

    /// `google.protobuf.Timestamp`: seconds at `1`, nanos at `2`.
    static func timestamp(_ field: Int, _ seconds: UInt64, nanos: UInt64 = 0) -> [UInt8] {
        message(field, varintField(1, seconds) + varintField(2, nanos))
    }
}

// MARK: - One step row

/// A `steps` row, and the payload blob that goes in it.
///
/// Mirrors the layout the adapter decodes: `1` step type, `4` status, `5`
/// metadata carrying the timestamps, the source, the tool call, and the status
/// log, plus one type-specific submessage holding whatever text the row has.
struct AntigravityStepFixture: Sendable {
    struct ToolCall: Sendable {
        var callID: String
        var name: String
        var argsJSON: String

        init(callID: String, name: String, argsJSON: String = "{}") {
            self.callID = callID
            self.name = name
            self.argsJSON = argsJSON
        }
    }

    struct Transition: Sendable {
        var status: AntigravityStepStatus
        var at: UInt64
    }

    var idx: Int
    var type: AntigravityStepType
    var status: AntigravityStepStatus
    var hasSubtrajectory = false
    var text: String?
    var toolCall: ToolCall?
    var startedAt: UInt64?
    var endedAt: UInt64?
    var source: AntigravityStepSource?
    var transitions: [Transition] = []
    var promptTokens: UInt64?
    var requestID: String?
    /// Extra strings alongside the real text, to prove the prose filter keeps
    /// the content and drops the identifiers.
    var noise: [String] = []
    /// Written into the blob but not into the columns, so a test can prove
    /// which of the two the adapter believes.
    var payloadStepTypeOverride: AntigravityStepType?

    init(
        idx: Int,
        type: AntigravityStepType,
        status: AntigravityStepStatus,
        hasSubtrajectory: Bool = false,
        text: String? = nil,
        toolCall: ToolCall? = nil,
        startedAt: UInt64? = nil,
        endedAt: UInt64? = nil,
        source: AntigravityStepSource? = nil,
        transitions: [Transition] = [],
        promptTokens: UInt64? = nil,
        requestID: String? = nil,
        noise: [String] = [],
        payloadStepTypeOverride: AntigravityStepType? = nil
    ) {
        self.idx = idx
        self.type = type
        self.status = status
        self.hasSubtrajectory = hasSubtrajectory
        self.text = text
        self.toolCall = toolCall
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.transitions = transitions
        self.promptTokens = promptTokens
        self.requestID = requestID
        self.noise = noise
        self.payloadStepTypeOverride = payloadStepTypeOverride
    }

    /// The field number this step type parks its content in. Types the layout
    /// does not name use a high field number, which is what the decoder's
    /// "lowest candidate above the metadata" fallback resolves.
    var typeSpecificField: Int {
        AntigravityStepPayload.typeSpecificField[type] ?? 50
    }

    /// The text field inside the type-specific submessage. `USER_INPUT` puts
    /// the prompt at `19.2`; everything else observed puts its text at `.1`.
    var textField: Int { type == .userInput ? 2 : 1 }

    var payload: Data {
        var metadata: [UInt8] = []
        if let startedAt { metadata += AntigravityProto.timestamp(1, startedAt) }
        if let source { metadata += AntigravityProto.varintField(3, UInt64(source.rawValue)) }
        if let toolCall {
            metadata += AntigravityProto.message(4, AntigravityProto.string(1, toolCall.callID)
                + AntigravityProto.string(2, toolCall.name)
                + AntigravityProto.string(3, toolCall.argsJSON))
        }
        if promptTokens != nil || requestID != nil {
            var usage: [UInt8] = []
            if let promptTokens { usage += AntigravityProto.varintField(1, promptTokens) }
            if let requestID { usage += AntigravityProto.string(11, requestID) }
            metadata += AntigravityProto.message(9, usage)
        }
        metadata += AntigravityProto.message(
            20,
            AntigravityProto.string(1, AntigravityDatabaseFixture.trajectoryID)
                + AntigravityProto.varintField(2, UInt64(idx))
                + AntigravityProto.string(4, AntigravityDatabaseFixture.cascadeID)
        )
        for transition in transitions {
            metadata += AntigravityProto.message(
                26,
                AntigravityProto.message(
                    1,
                    AntigravityProto.varintField(1, UInt64(transition.status.rawValue))
                        + AntigravityProto.timestamp(2, transition.at)
                )
            )
        }
        if let endedAt { metadata += AntigravityProto.timestamp(32, endedAt) }

        var specific: [UInt8] = []
        if let text { specific += AntigravityProto.string(textField, text) }
        for (offset, junk) in noise.enumerated() {
            specific += AntigravityProto.string(textField + 20 + offset, junk)
        }

        var out = AntigravityProto.varintField(
            1, UInt64((payloadStepTypeOverride ?? type).rawValue))
        out += AntigravityProto.varintField(4, UInt64(status.rawValue))
        out += AntigravityProto.message(5, metadata)
        if !specific.isEmpty { out += AntigravityProto.message(typeSpecificField, specific) }
        return Data(out)
    }
}

// MARK: - The databases

/// Writes conversation and summary databases with AntiGravity's own schema.
enum AntigravityDatabaseFixture {
    static let trajectoryID = "aaaaaaaa-1111-2222-3333-444444444444"
    static let cascadeID = "bbbbbbbb-1111-2222-3333-444444444444"

    /// Verbatim from a 2026-08 build, columns and all, so a query that would
    /// fail against the real store fails here too.
    static let conversationSchema = """
        CREATE TABLE `trajectory_meta` (`trajectory_id` text,`cascade_id` text,
            `trajectory_type` integer,`source` integer,PRIMARY KEY (`trajectory_id`));
        CREATE TABLE `steps` (`idx` integer,`step_type` integer NOT NULL DEFAULT 0,
            `status` integer NOT NULL DEFAULT 0,`has_subtrajectory` numeric NOT NULL DEFAULT false,
            `metadata` blob,`error_details` blob,`permissions` blob,`task_details` blob,
            `render_info` blob,`step_payload` blob,`step_format` integer NOT NULL DEFAULT 0,
            PRIMARY KEY (`idx`));
        CREATE INDEX `idx_steps_status` ON `steps`(`status`);
        CREATE INDEX `idx_steps_step_type` ON `steps`(`step_type`);
        CREATE TABLE `gen_metadata` (`idx` integer,`data` blob,
            `size` integer NOT NULL DEFAULT 0,PRIMARY KEY (`idx`));
        CREATE TABLE `executor_metadata` (`idx` integer,`data` blob,PRIMARY KEY (`idx`));
        CREATE TABLE `parent_references` (`idx` integer,`data` blob,PRIMARY KEY (`idx`));
        CREATE TABLE `trajectory_metadata_blob` (`id` text DEFAULT "main",`data` blob,
            PRIMARY KEY (`id`));
        CREATE TABLE `battle_mode_infos` (`idx` integer,`data` blob,PRIMARY KEY (`idx`));
        """

    static let summariesSchema = """
        CREATE TABLE `conversation_summaries` (`conversation_id` text,
            `title` text NOT NULL DEFAULT "",`preview` text NOT NULL DEFAULT "",
            `step_count` integer NOT NULL DEFAULT 0,`last_modified_time` datetime NOT NULL,
            `workspace_uris` text NOT NULL,`status` text NOT NULL DEFAULT "",
            `source` text NOT NULL DEFAULT "",`project_id` text NOT NULL DEFAULT "",
            `agent_name` text NOT NULL DEFAULT "",
            `parent_conversation_id` text NOT NULL DEFAULT "",
            `nesting_depth` integer NOT NULL DEFAULT 0,`battle_id` text NOT NULL DEFAULT "",
            `winning_conversation_id` text NOT NULL DEFAULT "",
            `not_fully_idle` numeric NOT NULL DEFAULT false,
            `killed` numeric NOT NULL DEFAULT false,`last_user_input_time` datetime NOT NULL,
            `last_user_input_step_index` integer NOT NULL DEFAULT -1,
            `app_data_dir` text NOT NULL DEFAULT "");
        """

    enum FixtureError: Error { case sqlite(String) }

    /// SQLITE_TRANSIENT: tell SQLite to copy the bound bytes.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func open(_ url: URL) throws -> OpaquePointer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
            let handle
        else { throw FixtureError.sqlite("open \(url.lastPathComponent)") }
        return handle
    }

    static func exec(_ handle: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// A conversation database with the given rows.
    ///
    /// - Parameter walMode: Leaves a live `-wal` sibling behind, which is what
    ///   every real conversation has and what the reader's snapshot path
    ///   exists for.
    static func writeConversation(
        at url: URL,
        steps: [AntigravityStepFixture],
        trajectoryType: AntigravityTrajectoryType = .cascade,
        source: AntigravityTrajectorySource = .cli,
        walMode: Bool = false
    ) throws {
        let handle = try open(url)
        defer { sqlite3_close_v2(handle) }
        if walMode { try exec(handle, "PRAGMA journal_mode=WAL") }
        try exec(handle, conversationSchema)
        try exec(handle, """
            INSERT INTO trajectory_meta(trajectory_id, cascade_id, trajectory_type, source)
            VALUES ('\(trajectoryID)', '\(cascadeID)', \(trajectoryType.rawValue), \(source.rawValue))
            """)
        for step in steps { try insert(handle, step) }
    }

    static func insert(_ handle: OpaquePointer, _ step: AntigravityStepFixture) throws {
        var statement: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO steps(idx, step_type, status, has_subtrajectory, step_payload)
            VALUES (?, ?, ?, ?, ?)
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw FixtureError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(step.idx))
        sqlite3_bind_int64(statement, 2, sqlite3_int64(step.type.rawValue))
        sqlite3_bind_int64(statement, 3, sqlite3_int64(step.status.rawValue))
        sqlite3_bind_int64(statement, 4, step.hasSubtrajectory ? 1 : 0)
        let payload = step.payload
        _ = payload.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, 5, raw.baseAddress, Int32(payload.count), transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FixtureError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Rewrites one row in place, which is what AntiGravity itself does as a
    /// call proceeds.
    static func update(at url: URL, step: AntigravityStepFixture) throws {
        let handle = try open(url)
        defer { sqlite3_close_v2(handle) }
        try insert(handle, step)
    }

    // MARK: - gen_metadata

    /// One `gen_metadata` row: the usage record AntiGravity writes per model
    /// turn, and the only place in the store the model is named.
    struct GenMetadataFixture: Sendable {
        var idx: Int
        var seconds: UInt64
        /// Field 21, the precise label — `Gemini 3.5 Flash (High)`.
        var model: String?
        /// Field 19, the router alias — `gemini-default`.
        var routedModel: String?
        /// Field 20's `model_enum` — `MODEL_PLACEHOLDER_M298`.
        var modelEnum: String?
        var inputTokens: UInt64 = 0
        var outputTokens: UInt64 = 0
        /// Leaves out `9.4`, which is what AntiGravity builds from 2026-08 do
        /// — and what makes the record undecodable as a whole turn.
        var omitTimestamp = false

        init(
            idx: Int,
            seconds: UInt64,
            model: String? = nil,
            routedModel: String? = nil,
            modelEnum: String? = nil,
            inputTokens: UInt64 = 0,
            outputTokens: UInt64 = 0,
            omitTimestamp: Bool = false
        ) {
            self.idx = idx
            self.seconds = seconds
            self.model = model
            self.routedModel = routedModel
            self.modelEnum = modelEnum
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.omitTimestamp = omitTimestamp
        }

        /// `1{4{2,3}, 9{4{1,2}}, 19, 20{1,2}, 21}` — the fields the reader
        /// decodes and nothing it does not.
        var blob: Data {
            var inner = AntigravityProto.message(
                4,
                AntigravityProto.varintField(2, inputTokens)
                    + AntigravityProto.varintField(3, outputTokens))
            inner += omitTimestamp
                ? AntigravityProto.message(9, AntigravityProto.varintField(2, 7))
                : AntigravityProto.message(9, AntigravityProto.timestamp(4, seconds))
            if let routedModel { inner += AntigravityProto.string(19, routedModel) }
            if let modelEnum {
                inner += AntigravityProto.message(
                    20,
                    AntigravityProto.string(1, "model_enum")
                        + AntigravityProto.string(2, modelEnum))
            }
            if let model { inner += AntigravityProto.string(21, model) }
            return Data(AntigravityProto.message(1, inner))
        }
    }

    /// Adds `gen_metadata` rows to a conversation database that already exists.
    static func writeGenMetadata(at url: URL, turns: [GenMetadataFixture]) throws {
        let handle = try open(url)
        defer { sqlite3_close_v2(handle) }
        for turn in turns {
            var statement: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO gen_metadata(idx, data, size) VALUES (?, ?, ?)"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw FixtureError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(statement) }
            let blob = turn.blob
            sqlite3_bind_int64(statement, 1, sqlite3_int64(turn.idx))
            _ = blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(blob.count), transient)
            }
            sqlite3_bind_int64(statement, 3, sqlite3_int64(blob.count))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw FixtureError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// One `conversation_summaries` row.
    struct SummaryFixture: Sendable {
        var id: String
        var title = ""
        var preview = ""
        var stepCount = 0
        var lastModified = "2026-07-16 08:18:19.171238+00:00"
        var workspaces = ""
        var parent = ""
        var nestingDepth = 0
        var notFullyIdle = false
        var killed = false
        var agentName = "agy"

        init(
            id: String,
            title: String = "",
            preview: String = "",
            stepCount: Int = 0,
            lastModified: String = "2026-07-16 08:18:19.171238+00:00",
            workspaces: String = "",
            parent: String = "",
            nestingDepth: Int = 0,
            notFullyIdle: Bool = false,
            killed: Bool = false,
            agentName: String = "agy"
        ) {
            self.id = id
            self.title = title
            self.preview = preview
            self.stepCount = stepCount
            self.lastModified = lastModified
            self.workspaces = workspaces
            self.parent = parent
            self.nestingDepth = nestingDepth
            self.notFullyIdle = notFullyIdle
            self.killed = killed
            self.agentName = agentName
        }
    }

    static func writeSummaries(at url: URL, rows: [SummaryFixture]) throws {
        let handle = try open(url)
        defer { sqlite3_close_v2(handle) }
        try exec(handle, summariesSchema)
        for row in rows {
            var statement: OpaquePointer?
            let sql = """
                INSERT INTO conversation_summaries
                    (conversation_id, title, preview, step_count, last_modified_time,
                     workspace_uris, status, source, project_id, agent_name,
                     parent_conversation_id, nesting_depth, battle_id, winning_conversation_id,
                     not_fully_idle, killed, last_user_input_time, last_user_input_step_index,
                     app_data_dir)
                VALUES (?, ?, ?, ?, ?, ?, 'DONE', 'CLI', '', ?, ?, ?, '', '', ?, ?, ?, -1, '')
                """
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw FixtureError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, row.id, -1, transient)
            sqlite3_bind_text(statement, 2, row.title, -1, transient)
            sqlite3_bind_text(statement, 3, row.preview, -1, transient)
            sqlite3_bind_int64(statement, 4, sqlite3_int64(row.stepCount))
            sqlite3_bind_text(statement, 5, row.lastModified, -1, transient)
            sqlite3_bind_text(statement, 6, row.workspaces, -1, transient)
            sqlite3_bind_text(statement, 7, row.agentName, -1, transient)
            sqlite3_bind_text(statement, 8, row.parent, -1, transient)
            sqlite3_bind_int64(statement, 9, sqlite3_int64(row.nestingDepth))
            sqlite3_bind_int64(statement, 10, row.notFullyIdle ? 1 : 0)
            sqlite3_bind_int64(statement, 11, row.killed ? 1 : 0)
            sqlite3_bind_text(statement, 12, row.lastModified, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw FixtureError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}

// MARK: - A synthetic home

/// A `~/.gemini` tree with both AntiGravity roots in it.
struct AntigravityHome {
    let tree: TemporaryTree

    init(_ label: String = #function) {
        tree = TemporaryTree(label)
    }

    var path: String { tree.path }

    func conversation(id: String, root: String = AntigravityLiveAdapter.cliRoot) -> URL {
        AntigravityLiveAdapter.conversationsPath(home: path, root: root)
            .appendingPathComponent("\(id).db")
    }

    var summariesURL: URL { AntigravityLiveAdapter.summariesPath(home: path) }

    @discardableResult
    func write(
        id: String,
        root: String = AntigravityLiveAdapter.cliRoot,
        steps: [AntigravityStepFixture],
        source: AntigravityTrajectorySource = .cli,
        walMode: Bool = false
    ) throws -> URL {
        let url = conversation(id: id, root: root)
        try AntigravityDatabaseFixture.writeConversation(
            at: url, steps: steps, source: source, walMode: walMode)
        return url
    }

    func writeSummaries(_ rows: [AntigravityDatabaseFixture.SummaryFixture]) throws {
        try AntigravityDatabaseFixture.writeSummaries(at: summariesURL, rows: rows)
    }

    func writeGenMetadata(
        id: String,
        root: String = AntigravityLiveAdapter.cliRoot,
        turns: [AntigravityDatabaseFixture.GenMetadataFixture]
    ) throws {
        try AntigravityDatabaseFixture.writeGenMetadata(
            at: conversation(id: id, root: root), turns: turns)
    }

    // MARK: - The CLI's side files

    /// One `log/cli-<stamp>.log`, in the shape `agy`'s Go server writes: a
    /// startup banner naming the launch directories, then one line per
    /// conversation the run touched.
    @discardableResult
    func writeLog(
        name: String,
        workspace: String?,
        conversations: [String],
        modified: Date? = nil
    ) throws -> URL {
        let directory = AntigravityWorkspaceIndex.logDirectory(
            home: path, root: AntigravityLiveAdapter.cliRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines = ["ERROR: logging before google.Init: I0821 16:12:26.499301 1 flags.go:12] starting"]
        if let workspace {
            lines.append(
                "ERROR: logging before google.Init: I0821 16:12:26.529709 1 server.go:270] "
                    + "Creating CLI server backend: product=antigravity workspaceDirs=[\(workspace)] "
                    + "appDataDir=\(path)/.gemini/antigravity-cli cascadeManager=true")
        }
        for id in conversations {
            lines.append(
                "ERROR: logging before google.Init: I0821 16:12:33.493865 1 server.go:1074] "
                    + "Created conversation \(id)")
        }
        let url = directory.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try? FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    /// `history.jsonl`: one object per prompt a person submitted.
    func writeHistory(_ rows: [(id: String?, workspace: String?, display: String)]) throws {
        let url = AntigravityWorkspaceIndex.historyPath(
            home: path, root: AntigravityLiveAdapter.cliRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = rows.map { row -> String in
            var object: [String] = ["\"display\":\"\(row.display)\"", "\"timestamp\":1779249577634"]
            if let workspace = row.workspace { object.append("\"workspace\":\"\(workspace)\"") }
            if let id = row.id { object.append("\"conversationId\":\"\(id)\"") }
            return "{\(object.joined(separator: ","))}"
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Creates the presence file for a conversation and returns its path.
    @discardableResult
    func presence(
        id: String,
        root: String = AntigravityLiveAdapter.cliRoot,
        modified: Date? = nil
    ) -> String {
        let path = AntigravityLiveAdapter.presencePath(home: path, root: root, conversationID: id)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data())
        if let modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        }
        return path
    }

    /// Backdates a conversation store so a discovery cutoff can be exercised.
    func backdate(id: String, root: String = AntigravityLiveAdapter.cliRoot, to date: Date) {
        let url = conversation(id: id, root: root)
        for path in [url.path, url.path + "-wal", url.path + "-shm"]
        where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }
}

// MARK: - Event helpers

/// A stable label per event case, for counting a whole poll at once.
func antigravityLabel(_ kind: AgentEventKind) -> String {
    switch kind {
    case .sessionStarted: "sessionStarted"
    case .identityUpdated: "identityUpdated"
    case .userPrompt: "userPrompt"
    case .turnStarted: "turnStarted"
    case .thinking: "thinking"
    case .assistantText: "assistantText"
    case .toolCallStarted: "toolCallStarted"
    case .toolCallFinished: "toolCallFinished"
    case .permissionRequested: "permissionRequested"
    case .permissionResolved: "permissionResolved"
    case .subagentStarted: "subagentStarted"
    case .subagentFinished: "subagentFinished"
    case .turnEnded(let reason): "turnEnded.\(reason.rawValue)"
    case .usage: "usage"
    case .compaction: "compaction"
    case .sessionEnded(let reason): "sessionEnded.\(reason.rawValue)"
    case .liveness: "liveness"
    case .note: "note"
    case .textBody(let role, _, _): "textBody.\(role.rawValue)"
    }
}

func antigravityLabels(_ events: [AgentEvent]) -> [String] {
    events.map { antigravityLabel($0.kind) }
}

/// Resolves `/var` against `/private/var` and friends, so a path a directory
/// walk returned compares equal to the one a test constructed.
func canonical(_ path: String?) -> String? {
    guard let path else { return nil }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}
