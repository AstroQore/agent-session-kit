import Darwin
import Foundation

/// Failure modes shared by every adapter's read paths.
public enum SessionParseError: Error, Hashable, Sendable {
    /// The file could not be opened or contained nothing usable.
    case unreadable(String)
    /// The file was readable but is not a session of this provider's
    /// shape — a rollout whose filename id contradicts its header, a
    /// Grok summary sitting in a directory named after a different
    /// session, and so on. Discovery treats this as "skip", not "fail".
    case invalidFormat(String)
}

extension SessionParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unreadable(detail): return "Unreadable session file: \(detail)"
        case let .invalidFormat(detail): return "Unrecognized session file: \(detail)"
        }
    }
}

/// One file-based CLI's view of its own session store.
///
/// Every method is deliberately per-file and side-effect free so an
/// indexer can fan out across providers, and so a second stage can add
/// a provider (AntiGravity) or a consumer (a full-text index) without
/// touching the existing adapters.
///
/// `homeDirectory` is threaded through the discovery methods rather
/// than captured: tests point it at a
/// synthetic temp tree, production leaves it at `RealHomeDirectory.path`.
public protocol SessionProviderAdapter: Sendable {
    var provider: SessionProvider { get }

    /// Directories this provider owns. Also the containment fence the
    /// deleter checks every removal target against, so a root must
    /// never be broader than the provider's own session store.
    func roots(homeDirectory: String) -> [URL]

    /// Session files under `roots`. Missing directories yield `[]`;
    /// symlinks are skipped.
    func discoverSessionFiles(homeDirectory: String) -> [URL]

    /// Cheap metadata for a list row. Reads only the head / tail of
    /// large files and never throws on individual malformed lines.
    func extractMetadata(fileURL: URL) throws -> SessionSummary

    /// Full transcript, optionally sliced by message index.
    func parseTranscript(fileURL: URL, range: Range<Int>?) throws -> TranscriptDocument

    /// What removing this session means on disk, plus the inputs the
    /// deleter re-asserts before it removes anything.
    func deletionPlan(for summary: SessionSummary, homeDirectory: String) throws -> SessionDeletionPlan

    /// What the incremental index compares to decide whether `fileURL` must be
    /// re-read; `nil` skips it for this pass and retries on the next.
    ///
    /// The default is the file's own fingerprint
    /// (`SessionChangeFingerprint.file(at:)`). An adapter overrides it when
    /// the file alone is the wrong answer: Mistral Vibe renames a session by
    /// rewriting a sibling `meta.json`, and Devin keeps every session as rows
    /// in one shared database, where the file's fingerprint would re-read all
    /// of them after a turn in any one.
    func changeFingerprint(fileURL: URL) -> SessionChangeFingerprint?
}

public extension SessionProviderAdapter {
    func parseTranscript(fileURL: URL) throws -> TranscriptDocument {
        try parseTranscript(fileURL: fileURL, range: nil)
    }

    func changeFingerprint(fileURL: URL) -> SessionChangeFingerprint? {
        SessionChangeFingerprint.file(at: fileURL)
    }

    /// Discover + describe in one pass, dropping files that do not
    /// parse. Adapters that reject a file (`invalidFormat`) drop out
    /// here rather than failing the whole sweep.
    func discoverSessions(homeDirectory: String) -> [SessionSummary] {
        discoverSessionFiles(homeDirectory: homeDirectory).compactMap {
            try? extractMetadata(fileURL: $0)
        }
    }
}

/// Two numbers the incremental index stores per discovered session and
/// compares for equality on the next pass. They are never interpreted, so an
/// adapter whose session is not one file may fill them with whatever moves
/// exactly when the session does.
public struct SessionChangeFingerprint: Hashable, Sendable {
    public let mtimeNanos: Int64
    public let size: Int64

    public init(mtimeNanos: Int64, size: Int64) {
        self.mtimeNanos = mtimeNanos
        self.size = size
    }

    /// Nanosecond mtime + size. Second-resolution timestamps are too coarse:
    /// a session file appended to twice inside the same second is exactly the
    /// case an incremental index has to notice.
    ///
    /// A live SQLite store in WAL mode commits into `<file>-wal` and leaves
    /// the main file untouched until a checkpoint, so the journal sibling is
    /// folded in (latest mtime, summed size) or an active Cursor / AntiGravity
    /// conversation would look unchanged for as long as it is being written.
    ///
    /// A locator that names a session *inside* a store file —
    /// `<store>/<session id>`, the shape Devin's session URLs take — answers
    /// with the store's own fingerprint. That is coarse (every session in the
    /// store moves together), and it is only reached by a wrapper adapter that
    /// does not forward `changeFingerprint`; without it such a wrapper would
    /// silently index none of those sessions.
    public static func file(at url: URL) -> SessionChangeFingerprint? {
        switch statFingerprint(url.path) {
        case let .success(own):
            return own.folding(try? statFingerprint(url.path + "-wal").get())
        case .failure(let failure) where failure.code == ENOTDIR:
            let store = url.deletingLastPathComponent().path
            var info = stat()
            guard lstat(store, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  let parent = try? statFingerprint(store).get()
            else { return nil }
            return parent.folding(try? statFingerprint(store + "-wal").get())
        case .failure:
            return nil
        }
    }

    /// `self` with another file's fingerprint folded in the way a WAL sibling
    /// is: the later mtime, the summed size.
    public func folding(_ other: SessionChangeFingerprint?) -> SessionChangeFingerprint {
        guard let other else { return self }
        return SessionChangeFingerprint(
            mtimeNanos: max(mtimeNanos, other.mtimeNanos),
            size: size &+ other.size
        )
    }

    struct StatFailure: Error {
        let code: Int32
    }

    /// `stat(2)` with its `errno` captured at the call, not read back later.
    static func statFingerprint(_ path: String) -> Result<SessionChangeFingerprint, StatFailure> {
        var info = stat()
        guard stat(path, &info) == 0 else { return .failure(StatFailure(code: errno)) }
        let seconds = Int64(info.st_mtimespec.tv_sec)
        let nanos = Int64(info.st_mtimespec.tv_nsec)
        return .success(SessionChangeFingerprint(
            mtimeNanos: seconds * 1_000_000_000 + nanos,
            size: Int64(info.st_size)
        ))
    }
}

/// Provider → adapter lookup, with a stable iteration order.
public struct SessionProviderRegistry: Sendable {
    public let adapters: [any SessionProviderAdapter]
    private let byProvider: [SessionProvider: any SessionProviderAdapter]

    public init(adapters: [any SessionProviderAdapter]) {
        self.adapters = adapters
        var map: [SessionProvider: any SessionProviderAdapter] = [:]
        for adapter in adapters where map[adapter.provider] == nil {
            map[adapter.provider] = adapter
        }
        self.byProvider = map
    }

    /// The adapters shipped today, one per `SessionProvider`.
    ///
    /// AntiGravity, Claude Cowork, Cursor, Grok Bot, Muse Code, Devin,
    /// Mistral Vibe, and Muse list and read like the rest but refuse to plan a
    /// delete, because another running app owns those stores — see
    /// `SessionProvider.supportsDeletion`.
    public static func standard(homeDirectory: String = RealHomeDirectory.path) -> SessionProviderRegistry {
        SessionProviderRegistry(adapters: [
            ClaudeSessionAdapter(),
            ClaudeCoworkSessionAdapter(),
            CodexSessionAdapter(homeDirectory: homeDirectory),
            GrokSessionAdapter(),
            CursorSessionAdapter(),
            GeminiSessionAdapter(),
            AntigravitySessionAdapter(),
            GrokBotSessionAdapter(),
            MuseSessionAdapter(),
            DevinSessionAdapter(),
            MistralVibeSessionAdapter(),
            MuseAgentSessionAdapter()
        ])
    }

    public func adapter(for provider: SessionProvider) -> (any SessionProviderAdapter)? {
        byProvider[provider]
    }

    public var providers: [SessionProvider] { adapters.map(\.provider) }
}
