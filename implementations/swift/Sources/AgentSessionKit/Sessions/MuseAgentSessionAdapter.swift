import Foundation

/// Muse conversations: the local cache Meta's desktop agent app, `Muse.app`
/// (muse.ai's Mac client), keeps at `~/Library/Caches/ConversationCache/`.
///
/// This is **not** Muse Code — that is Meta's `muse` terminal CLI, with its
/// own store and its own provider (`.muse`). The two share a company and a
/// word.
///
/// The directory's name is generic and carries no bundle id because it is
/// shared: `Muse.app` and the consumer `Meta AI.app` are built from the same
/// code and both write here. Muse's conversations — the "Hatch" product line —
/// are the files named `hatch-<identifier>.json` (today only `hatch-main.json`,
/// the main chat). The UUID-named files beside them are Meta AI's consumer
/// chats and are **not** Muse sessions; discovery never lists them. The
/// directory's dotfiles (`.cache_version`, `.user_id`) are the client's own
/// bookkeeping and are never opened.
///
/// Each file is one JSON array, one element per message: `id`, `isUser`,
/// `content` (plain text / markdown), `timestamp` (seconds since the Apple
/// reference date, 2001-01-01 UTC — *not* the Unix epoch), `sortSeq`,
/// `isStreaming`, and `contentBlocks` (`markdown`, `thinkingStatus`,
/// `optionWidget`, `unsupported`), plus fields this adapter ignores
/// (`sources`, `mentions`, `activeToolCalls`, `hatchVMName`,
/// `rawUnifiedResponse`, …).
///
/// **A cloud cache, so read-only and partial by nature.** The agent runs in a
/// VM on Meta's servers; this file is what the client happened to cache, which
/// means history may be incomplete and the running app rewrites it underneath
/// us. There is no model, no token count, no title, and no local project
/// directory to read. `deletionPlan` fails closed (AGENTS.md § 6) and there is
/// no resume command.
public struct MuseAgentSessionAdapter: SessionProviderAdapter {
    public let provider: SessionProvider = .museAgent

    public init() {}

    /// Deliberately not `FileManager.cachesDirectory`: every discovery entry
    /// point takes an explicit `homeDirectory` (AGENTS.md § 4), so tests point
    /// it at a temp tree and a host passes `RealHomeDirectory.path`.
    ///
    /// Public so a host or a future live layer reads the same directory
    /// without spelling it a second time.
    public static let storeRelativePath = "Library/Caches/ConversationCache"

    /// Muse's files, and only Muse's, start with this. Meta AI's share the
    /// directory under bare UUIDs.
    public static let sessionFilePrefix = "hatch-"
    public static let sessionFileExtension = "json"

    /// ``SessionSummary/providerVariant`` for every conversation in this
    /// store. There is only the one kind.
    public static let variant = "chat"

    /// Largest file we will read. Far above what the client writes (a few KB
    /// to ~100 KB) and exists so a junk file in the directory costs nothing.
    static let maxFileBytes: Int64 = 16 * 1024 * 1024

    public func roots(homeDirectory: String) -> [URL] {
        [URL(fileURLWithPath: homeDirectory).appendingPathComponent(Self.storeRelativePath)]
    }

    /// The store is flat, so this lists one directory rather than walking a
    /// tree: nothing below it is a Muse session. Symlinks and anything that is
    /// not a regular file are skipped.
    public func discoverSessionFiles(homeDirectory: String) -> [URL] {
        roots(homeDirectory: homeDirectory).flatMap { root -> [URL] in
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )) ?? []
            return contents.filter { url in
                guard Self.sessionID(at: url) != nil else { return false }
                let values = try? url.resourceValues(forKeys: Set(keys))
                return values?.isSymbolicLink != true && values?.isRegularFile == true
            }
            .sorted { $0.path < $1.path }
        }
    }

    // MARK: - Session ids

    /// The session id a cache file stands for — its filename stem, e.g.
    /// `hatch-main` — or `nil` when the file is not one of Muse's.
    public static func sessionID(at url: URL) -> String? {
        guard url.pathExtension == sessionFileExtension else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix(sessionFilePrefix),
              stem.count > sessionFilePrefix.count,
              isIdentifier(stem)
        else { return nil }
        return stem
    }

    static func isIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        return value.unicodeScalars.allSatisfy(identifierScalars.contains)
    }

    private static let identifierScalars = CharacterSet(charactersIn:
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-"
    )

    // MARK: - Metadata

    public func extractMetadata(fileURL: URL) throws -> SessionSummary {
        guard let sessionID = Self.sessionID(at: fileURL) else {
            throw SessionParseError.invalidFormat("\(fileURL.lastPathComponent): not a Muse conversation cache")
        }
        let transcript = try Self.transcript(at: fileURL)
        guard transcript.entryCount > 0 else {
            throw SessionParseError.unreadable("\(fileURL.lastPathComponent): no messages")
        }

        let firstPrompt = transcript.messages.first { $0.role == .user }?.text
        let lastText = transcript.messages.last?.text

        return SessionSummary(
            provider: .museAgent,
            sessionID: sessionID,
            providerVariant: Self.variant,
            harness: .museAgent,
            // Cloud-side inference: the cache never records which model
            // answered, and guessing one would be wrong at pricing time too.
            model: nil,
            title: SessionParsing.display(firstPrompt, limit: SessionParsing.titleLimit),
            summary: SessionParsing.display(lastText, limit: SessionParsing.summaryLimit),
            // The agent's working directory is inside a remote VM.
            projectDir: nil,
            createdAt: transcript.firstStamp ?? SessionParsing.creationDate(fileURL),
            lastActiveAt: transcript.lastStamp ?? SessionParsing.modificationDate(fileURL),
            sourcePath: fileURL.path,
            sizeBytes: SessionParsing.fileSize(fileURL),
            messageCount: transcript.entryCount
        )
    }

    // MARK: - Transcript

    public func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument {
        SessionTranscriptSlicing.document(
            messages: try Self.transcript(at: fileURL).messages,
            range: range
        )
    }

    struct Transcript {
        let messages: [SessionMessage]
        /// Message entries — anything with an `isUser` flag — whether or not
        /// they carried displayable text. This is what the list row counts,
        /// so a widget-only reply still registers as a turn.
        let entryCount: Int
        let firstStamp: Date?
        let lastStamp: Date?
    }

    /// The file's messages, or a parse error: `unreadable` for a file that is
    /// missing, oversized, or not JSON at all (the app may be mid-rewrite),
    /// `invalidFormat` for JSON that is not this store's array.
    static func transcript(at url: URL) throws -> Transcript {
        guard SessionParsing.fileSize(url) <= maxFileBytes,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { throw SessionParseError.unreadable(url.lastPathComponent) }
        guard let elements = root as? [Any] else {
            throw SessionParseError.invalidFormat("\(url.lastPathComponent): not a message array")
        }
        return transcript(from: elements)
    }

    static func transcript(from elements: [Any]) -> Transcript {
        let entries = ordered(elements.compactMap { element -> [String: Any]? in
            guard let entry = element as? [String: Any], entry["isUser"] is Bool else { return nil }
            return entry
        })

        var messages: [SessionMessage] = []
        var first: Date?
        var last: Date?
        for entry in entries {
            let stamp = date(entry["timestamp"])
            if let stamp {
                first = min(first ?? stamp, stamp)
                last = max(last ?? stamp, stamp)
            }
            // An empty text is a streaming placeholder or a widget-only
            // reply; it counts as a turn but is not a bubble.
            let body = text(of: entry)
            guard !body.isEmpty else { continue }
            let role: SessionRole = (entry["isUser"] as? Bool) == true ? .user : .assistant
            messages.append(SessionMessage(seq: messages.count, role: role, text: body, timestamp: stamp))
        }
        return Transcript(messages: messages, entryCount: entries.count, firstStamp: first, lastStamp: last)
    }

    /// `sortSeq` order when every entry has one, file order otherwise. A
    /// partial ordering key would interleave the unkeyed entries arbitrarily,
    /// and the array is already the client's own idea of the conversation.
    static func ordered(_ entries: [[String: Any]]) -> [[String: Any]] {
        let keys = entries.map { SessionParsing.int($0["sortSeq"]) }
        guard !keys.contains(where: { $0 == nil }) else { return entries }
        return entries.indices
            .sorted { (keys[$0]!, $0) < (keys[$1]!, $1) }
            .map { entries[$0] }
    }

    /// `content`, or — when that is empty — the text of the message's
    /// markdown blocks. Thinking, widget, and unsupported blocks carry no
    /// conversation text.
    static func text(of entry: [String: Any]) -> String {
        if let content = SessionParsing.string(entry["content"]) { return content }
        let blocks = entry["contentBlocks"] as? [Any] ?? []
        let parts = blocks.compactMap { block -> String? in
            guard let markdown = (block as? [String: Any])?["markdown"] as? [String: Any] else { return nil }
            return SessionParsing.string(markdown["text"])
        }
        return parts.joined(separator: "\n\n")
    }

    /// The client stamps messages in seconds since the Apple reference date
    /// (2001-01-01 UTC), which is `Date`'s own reference. Reading one as Unix
    /// seconds would land every conversation in 1995.
    static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds > 0, seconds < maxReferenceSeconds else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Past this a value is not reference-date seconds (it would be well into
    /// the 23rd century) — most likely milliseconds — and is ignored rather
    /// than turned into a wrong date.
    static let maxReferenceSeconds: Double = 10_000_000_000

    // MARK: - Deletion

    public func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan {
        throw SessionDeleteError.providerIsReadOnly(.museAgent)
    }
}
