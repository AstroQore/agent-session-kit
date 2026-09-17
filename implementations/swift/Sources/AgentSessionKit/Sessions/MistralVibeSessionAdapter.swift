import Foundation

/// Mistral Vibe sessions: a directory per conversation at
/// `~/.vibe/logs/session/session_<UTC YYYYMMDD_HHMMSS>_<first 8 of id>/`,
/// holding two files the `vibe` CLI writes on every save:
///
/// - `meta.json` — rewritten atomically: `session_id`, `start_time` /
///   `end_time` (ISO-8601, µs, `+00:00`), `environment.working_directory`,
///   `title` (often `null`: titling is opt-in), and a `config` snapshot whose
///   `models[active_model].name` is the model id the session calls.
/// - `messages.jsonl` — one message per line, never the system prompt:
///   `role` (`user` / `assistant` / `tool`), `content` (a string or a chunk
///   list), `injected`, `tool_calls[].function.{name, arguments}`. Appended,
///   or rewritten whole on a rewind. No line carries a timestamp.
///
/// A session's file is its `messages.jsonl`, so head / tail reads and host
/// byte bounds work as they do for every other JSONL provider; its
/// `changeFingerprint` folds `meta.json` in, because a rename or a model
/// switch rewrites only that file.
///
/// Discovery lists the top-level `session_*` directories and nothing under
/// them. A sub-agent's session is nested in its parent's directory
/// (`<parent>/agents/<agent>_…/`) and linked from the parent's
/// `child_sessions`; like Muse Code's reminder children it belongs to the
/// parent's conversation, and Vibe's own resume list skips it too. `active/`
/// holds lease files and `.session_index.json` is Vibe's listing cache —
/// neither is a session.
///
/// Read-only: Vibe caches its listing in `.session_index.json`, leases a
/// running session under `active/`, nests sub-agent sessions inside the
/// parent's directory, and sweeps worktrees that no listed session resumes
/// into — a session removed underneath it can cost the user a worktree.
public struct MistralVibeSessionAdapter: SessionProviderAdapter {
    public let provider: SessionProvider = .mistralVibe

    public init() {}

    static let rootDirectory = ".vibe/logs/session"
    static let sessionDirectoryPrefix = "session_"
    static let metadataFileName = "meta.json"
    static let messagesFileName = "messages.jsonl"

    /// `meta.json` carries the system prompt and every tool schema, but does
    /// not grow with the conversation; anything past this is not one.
    static let maxMetadataBytes: Int64 = 16 * 1024 * 1024
    static let headLineCount = 40
    static let tailLineCount = 40

    public func roots(homeDirectory: String) -> [URL] {
        [URL(fileURLWithPath: homeDirectory).appendingPathComponent(Self.rootDirectory, isDirectory: true)]
    }

    // MARK: - Discovery

    public func discoverSessionFiles(homeDirectory: String) -> [URL] {
        roots(homeDirectory: homeDirectory).flatMap { root -> [URL] in
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return children.compactMap { directory -> URL? in
                guard directory.lastPathComponent.hasPrefix(Self.sessionDirectoryPrefix) else { return nil }
                let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink == false, values?.isDirectory == true else { return nil }
                let messages = directory.appendingPathComponent(Self.messagesFileName)
                guard Self.isRegularFile(messages),
                      Self.isRegularFile(directory.appendingPathComponent(Self.metadataFileName))
                else { return nil }
                return messages
            }
            .sorted { $0.path < $1.path }
        }
    }

    /// Not a symlink, and a regular file.
    static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        return values?.isSymbolicLink == false && values?.isRegularFile == true
    }

    static func metadataURL(forMessages url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(metadataFileName)
    }

    // MARK: - Change fingerprint

    /// `messages.jsonl` with `meta.json` folded in: a turn moves the first, a
    /// rename, a model switch, or a generated title moves only the second.
    public func changeFingerprint(fileURL: URL) -> SessionChangeFingerprint? {
        guard let messages = SessionChangeFingerprint.file(at: fileURL) else { return nil }
        return messages.folding(SessionChangeFingerprint.file(at: Self.metadataURL(forMessages: fileURL)))
    }

    // MARK: - Metadata

    public func extractMetadata(fileURL: URL) throws -> SessionSummary {
        guard fileURL.lastPathComponent == Self.messagesFileName else {
            throw SessionParseError.invalidFormat("\(fileURL.lastPathComponent): not a messages log")
        }
        let directory = fileURL.deletingLastPathComponent()
        let meta = try Self.metadata(forMessages: fileURL)

        guard let sessionID = SessionParsing.string(meta["session_id"]) else {
            throw SessionParseError.invalidFormat("\(Self.metadataFileName): no session id")
        }
        guard Self.directory(directory.lastPathComponent, matches: sessionID) else {
            throw SessionParseError.invalidFormat(
                "\(directory.lastPathComponent): directory is not named after the session id"
            )
        }

        // Vibe lists an empty log only when the session recorded no messages;
        // otherwise it is an interrupted write it refuses to load.
        let size = SessionParsing.fileSize(fileURL)
        if size == 0, SessionParsing.int(meta["total_messages"]) != 0 {
            throw SessionParseError.invalidFormat("\(Self.messagesFileName): empty log")
        }

        var firstPrompt: String?
        if SessionParsing.string(meta["title"]) == nil {
            for line in JSONLHeadTail.headLines(url: fileURL, count: Self.headLineCount) {
                guard let message = Self.message(line), message.role == "user" else { continue }
                if let text = SessionParsing.string(message.text) {
                    firstPrompt = text
                    break
                }
            }
        }

        var lastReply: String?
        for line in JSONLHeadTail.tailLines(url: fileURL, count: Self.tailLineCount).reversed() {
            guard let message = Self.message(line), message.role == "assistant" else { continue }
            if let text = SessionParsing.string(message.text) {
                lastReply = text
                break
            }
        }

        let environment = meta["environment"] as? [String: Any]
        return SessionSummary(
            provider: .mistralVibe,
            sessionID: sessionID,
            harness: .mistralVibe,
            model: Self.model(in: meta["config"]),
            title: SessionParsing.display(
                SessionParsing.string(meta["title"]) ?? firstPrompt,
                limit: SessionParsing.titleLimit
            ),
            summary: SessionParsing.display(lastReply, limit: SessionParsing.summaryLimit),
            projectDir: SessionParsing.firstString(environment?["working_directory"], meta["origin_directory"]),
            createdAt: SessionParsing.date(meta["start_time"]) ?? SessionParsing.creationDate(directory),
            lastActiveAt: SessionParsing.date(meta["end_time"]) ?? SessionParsing.modificationDate(fileURL),
            sourcePath: fileURL.path,
            sizeBytes: max(0, size)
        )
    }

    /// `meta.json` beside a messages log, bounded and never through a link.
    static func metadata(forMessages url: URL) throws -> [String: Any] {
        let metaURL = metadataURL(forMessages: url)
        guard isRegularFile(metaURL), SessionParsing.fileSize(metaURL) <= maxMetadataBytes,
              let object = SessionParsing.jsonObject(at: metaURL)
        else { throw SessionParseError.unreadable(metadataFileName) }
        return object
    }

    /// `session_20260101_000000_5c0ffee1` belongs to a session whose id starts
    /// `5c0ffee1`.
    static func directory(_ name: String, matches sessionID: String) -> Bool {
        guard name.hasPrefix(sessionDirectoryPrefix), sessionID.count >= 8 else { return false }
        return name.hasSuffix("_" + String(sessionID.prefix(8)))
    }

    /// `config.models[config.active_model].name` — the model id the alias
    /// resolves to (`mistral-medium-3.5` → `mistral-vibe-cli-latest`). A
    /// `models` list whose entries carry their own `alias` is read the same
    /// way. No entry for the active alias means no model, not the alias.
    static func model(in config: Any?) -> String? {
        guard let config = config as? [String: Any],
              let active = SessionParsing.string(config["active_model"])
        else { return nil }
        if let models = config["models"] as? [String: Any] {
            return SessionParsing.string((models[active] as? [String: Any])?["name"])
        }
        if let models = config["models"] as? [[String: Any]] {
            let entry = models.first { SessionParsing.string($0["alias"]) == active }
            return SessionParsing.string(entry?["name"])
        }
        return nil
    }

    // MARK: - Transcript

    public func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        var messages: [SessionMessage] = []
        func append(_ role: SessionRole, _ text: String) {
            guard !text.isEmpty else { return }
            messages.append(SessionMessage(seq: messages.count, role: role, text: text, timestamp: nil))
        }

        let didRead = JSONLLineScanner.forEachLine(in: fileURL) { line in
            guard let message = Self.message(line) else { return }
            switch message.role {
            case "user":
                append(.user, message.text)
            case "assistant":
                append(.assistant, message.text)
                for call in (message.object["tool_calls"] as? [[String: Any]]) ?? [] {
                    append(.tool, Self.toolCallText(call))
                }
            case "tool":
                append(.tool, message.text)
            default:
                break
            }
        }
        guard didRead else { throw SessionParseError.unreadable(fileURL.lastPathComponent) }
        return SessionTranscriptSlicing.document(messages: messages, range: range)
    }

    /// One log line, or `nil` for a malformed line or one Vibe injected — a
    /// compaction summary, a hook's message, a resumed plan — rather than a
    /// person or the model wrote. Reasoning is dropped.
    static func message(_ line: Data) -> (role: String?, text: String, object: [String: Any])? {
        guard let object = SessionParsing.json(line), !SessionParsing.bool(object["injected"]) else {
            return nil
        }
        return (object["role"] as? String, SessionParsing.extractText(object["content"]), object)
    }

    /// `[Tool: name]` and the call's JSON arguments string.
    static func toolCallText(_ call: [String: Any]) -> String {
        let function = call["function"] as? [String: Any]
        let name = SessionParsing.firstString(function?["name"], call["name"]) ?? "tool"
        let arguments = SessionParsing.firstString(function?["arguments"], call["arguments"])
            .map { SessionParsing.truncate($0, limit: 4_000) }
        return arguments.map { "[Tool: \(name)]\n\($0)" } ?? "[Tool: \(name)]"
    }

    // MARK: - Deletion

    public func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        throw SessionDeleteError.providerIsReadOnly(.mistralVibe)
    }
}
