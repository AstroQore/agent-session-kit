import Foundation

/// Muse Code sessions: a directory per conversation at
/// `~/.local/share/muse/sessions/YYYY/MM/DD/<session-id>/`, whose
/// `session.jsonl` is an append-only record log.
///
/// Every line is one record — `{schema_version, id, stream, sequence,
/// recorded_at, record_type, payload_type, payload}` with `recorded_at` in
/// microseconds — or a `retained_frame` wrapping several such records as
/// `children[].record_json` strings. Conversation turns are the `run` events
/// inside `payload_type == "runtime.session"` records:
///
/// - `started` carries the user's `prompt`;
/// - `assistant_message_committed` carries the reply `text`;
/// - `assistant_tool_calls_committed` / `tool_result_batch_committed` carry
///   the tool round-trips.
///
/// Reminder and verifier children the CLI runs alongside a turn keep their
/// own logs under `<session-id>/subagent/<child-id>/`; they are part of the
/// parent's conversation, not sessions of their own, so discovery skips them.
///
/// Read-only: the CLI's own `session-index.db` references each log path and a
/// running `muse` holds locks and sockets inside the directory.
public struct MuseSessionAdapter: SessionProviderAdapter {
    public let provider: SessionProvider = .muse

    public init() {}

    public func roots(homeDirectory: String) -> [URL] {
        [URL(fileURLWithPath: homeDirectory).appendingPathComponent(".local/share/muse/sessions")]
    }

    public func discoverSessionFiles(homeDirectory: String) -> [URL] {
        roots(homeDirectory: homeDirectory).flatMap { root in
            SessionParsing.collectFiles(under: root) { url in
                url.lastPathComponent == Self.logFileName && !Self.isSubagentLog(url)
            }
        }
    }

    static let logFileName = "session.jsonl"
    static let subagentDirectoryName = "subagent"

    /// `…/<parent>/subagent/<child>/session.jsonl` belongs to its parent.
    static func isSubagentLog(_ url: URL) -> Bool {
        url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            == subagentDirectoryName
    }

    /// Enough of the head to reach the first prompt past the permission,
    /// metadata, and request-configuration records a turn opens with.
    static let headLineCount = 80
    static let tailLineCount = 60

    // MARK: - Metadata

    public func extractMetadata(fileURL: URL) throws -> SessionSummary {
        let head = JSONLHeadTail.headLines(url: fileURL, count: Self.headLineCount)
        guard !head.isEmpty else { throw SessionParseError.unreadable(fileURL.path) }

        var sessionID: String?
        var projectDir: String?
        var model: String?
        var firstPrompt: String?
        var sessionName: String?
        var createdAt: Date?

        for record in head.flatMap(Self.records(in:)) {
            if createdAt == nil { createdAt = SessionParsing.date(record["recorded_at"]) }
            if sessionID == nil,
               let stream = record["stream"] as? [String: Any],
               stream["kind"] as? String == "session" {
                sessionID = SessionParsing.string(stream["id"])
            }
            let payload = record["payload"] as? [String: Any]
            switch record["payload_type"] as? String {
            case "runtime.session.metadata":
                let inner = payload?["record"] as? [String: Any]
                projectDir = projectDir ?? SessionParsing.string(inner?["workspace_root"])
                model = SessionParsing.string(inner?["model_id"]) ?? model
            case "run.model.configured":
                let inner = payload?["record"] as? [String: Any]
                model = SessionParsing.string(inner?["model_id"]) ?? model
            case "runtime.session.route_facts":
                let inner = payload?["record"] as? [String: Any]
                projectDir = projectDir ?? SessionParsing.string(inner?["cwd"])
            case "session.name.changed":
                sessionName = SessionParsing.string(payload?["new_name"]) ?? sessionName
            default:
                break
            }
            if let event = Self.runEvent(record) {
                switch event["kind"] as? String {
                case "started":
                    if firstPrompt == nil { firstPrompt = SessionParsing.string(event["prompt"]) }
                case "model_completed":
                    model = SessionParsing.string(event["model"]) ?? model
                default:
                    break
                }
            }
        }

        guard let sessionID else {
            throw SessionParseError.invalidFormat("\(fileURL.path): no session stream id")
        }
        guard fileURL.deletingLastPathComponent().lastPathComponent == sessionID else {
            throw SessionParseError.invalidFormat(
                "\(fileURL.path): parent directory is not named after the session id"
            )
        }

        var lastActiveAt: Date?
        var lastReply: String?
        for record in JSONLHeadTail.tailLines(url: fileURL, count: Self.tailLineCount)
            .flatMap(Self.records(in:)) {
            if let date = SessionParsing.date(record["recorded_at"]) { lastActiveAt = date }
            guard let event = Self.runEvent(record) else { continue }
            switch event["kind"] as? String {
            case "model_completed":
                model = SessionParsing.string(event["model"]) ?? model
            case "assistant_message_committed":
                lastReply = SessionParsing.string(event["text"]) ?? lastReply
            default:
                break
            }
        }

        return SessionSummary(
            provider: .muse,
            sessionID: sessionID,
            harness: .museCode,
            model: model,
            title: SessionParsing.display(firstPrompt ?? sessionName, limit: SessionParsing.titleLimit),
            summary: SessionParsing.display(lastReply, limit: SessionParsing.summaryLimit),
            projectDir: projectDir,
            createdAt: createdAt ?? SessionParsing.creationDate(fileURL),
            lastActiveAt: lastActiveAt ?? SessionParsing.modificationDate(fileURL),
            sourcePath: fileURL.path,
            sizeBytes: SessionParsing.fileSize(fileURL)
        )
    }

    // MARK: - Transcript

    public func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        var messages: [SessionMessage] = []
        func append(_ role: SessionRole, _ text: String, _ timestamp: Date?) {
            guard !text.isEmpty else { return }
            messages.append(SessionMessage(seq: messages.count, role: role, text: text, timestamp: timestamp))
        }

        let didRead = JSONLLineScanner.forEachLine(in: fileURL) { lineData in
            for record in Self.records(in: lineData) {
                guard let event = Self.runEvent(record) else { continue }
                let timestamp = SessionParsing.date(record["recorded_at"])
                switch event["kind"] as? String {
                case "started":
                    // Task starts share the kind; only a turn start has a prompt.
                    if let prompt = event["prompt"] as? String { append(.user, prompt, timestamp) }
                case "assistant_message_committed":
                    append(.assistant, (event["text"] as? String) ?? "", timestamp)
                case "assistant_tool_calls_committed":
                    for call in (event["tool_calls"] as? [[String: Any]]) ?? [] {
                        let name = SessionParsing.string(call["name"]) ?? "tool"
                        let args = SessionParsing.string(call["args"])
                        append(.tool, args.map { "[Tool: \(name)]\n\($0)" } ?? "[Tool: \(name)]", timestamp)
                    }
                case "tool_result_batch_committed":
                    for result in (event["results"] as? [[String: Any]]) ?? [] {
                        append(.tool, SessionParsing.extractText(result["text"]), timestamp)
                    }
                default:
                    break
                }
            }
        }
        guard didRead else { throw SessionParseError.unreadable(fileURL.path) }
        return SessionTranscriptSlicing.document(messages: messages, range: range)
    }

    // MARK: - Deletion

    public func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        throw SessionDeleteError.providerIsReadOnly(.muse)
    }

    // MARK: - Record decoding

    /// The records one log line holds: itself, or the children of a
    /// `retained_frame`.
    static func records(in line: Data) -> [[String: Any]] {
        guard let object = SessionParsing.json(line) else { return [] }
        guard let children = object["children"] as? [[String: Any]] else { return [object] }
        return children.compactMap { child in
            guard let raw = child["record_json"] as? String else { return nil }
            return SessionParsing.json(Data(raw.utf8))
        }
    }

    /// The `event` of a `runtime.session` run record, or `nil` for anything
    /// else — task lifecycle, telemetry, permission bookkeeping.
    static func runEvent(_ record: [String: Any]) -> [String: Any]? {
        guard record["payload_type"] as? String == "runtime.session",
              let payload = record["payload"] as? [String: Any],
              payload["kind"] as? String == "run"
        else { return nil }
        return payload["event"] as? [String: Any]
    }
}
