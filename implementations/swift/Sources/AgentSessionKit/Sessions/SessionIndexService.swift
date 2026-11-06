import Darwin
import Foundation

/// Limits a refresh batch's source reads. Byte limits are admission estimates
/// from on-disk source sizes, not measurements of physical I/O. Adapters may
/// read a source more than once, consult side indexes, or see a file grow.
/// A compressed rollout requires an adapter-provided decoded read budget.
/// The duration is checked between files.
public struct SessionIndexRefreshBudget: Sendable {
    public let maxFiles: Int
    public let maxBytes: Int64
    public let maxFileBytes: Int64
    public let maxChecked: Int
    public let maxDuration: Duration?

    public init(
        maxFiles: Int,
        maxBytes: Int64,
        maxFileBytes: Int64,
        maxChecked: Int = 512,
        maxDuration: Duration? = nil
    ) {
        self.maxFiles = max(1, maxFiles)
        self.maxBytes = max(1, maxBytes)
        self.maxFileBytes = min(self.maxBytes, max(1, maxFileBytes))
        self.maxChecked = max(1, maxChecked)
        self.maxDuration = maxDuration
    }
}

/// The source-byte estimate for an adapter's bounded metadata read and its
/// existing transcript read. Set `requiresFullRefresh` when the bounded
/// metadata is intentionally partial. A full pass then revisits the source
/// once, even when its fingerprint has not moved.
public struct SessionIndexReadPlan: Sendable {
    public let estimatedBytes: Int64
    let requiresFullRefresh: Bool
    let extractMetadata: @Sendable () throws -> SessionSummary

    public init(
        estimatedBytes: Int64,
        requiresFullRefresh: Bool = false,
        extractMetadata: @escaping @Sendable () throws -> SessionSummary
    ) {
        self.estimatedBytes = estimatedBytes
        self.requiresFullRefresh = requiresFullRefresh
        self.extractMetadata = extractMetadata
    }
}

/// A bounded metadata window could not safely reproduce the session's metadata.
public struct SessionIndexReadDeferred: Error, Sendable {
    public init() {}
}

/// A trusted source locator from this service's discovery scope or index.
/// Put recent sources first to prioritize them under a budget.
public struct SessionIndexCandidate: Hashable, Sendable {
    public let provider: SessionProvider
    public let url: URL

    public init(provider: SessionProvider, url: URL) {
        self.provider = provider
        self.url = url
    }
}

public struct SessionIndexRefreshResult: Sendable {
    /// Candidates advanced. A candidate that does not fit the remaining
    /// byte budget stays at the cursor for the next batch.
    public internal(set) var checked = 0
    public internal(set) var changed = 0
    public internal(set) var parsed = 0
    public internal(set) var written = 0
    public internal(set) var pruned = 0
    /// The persisted privacy mode switched, possibly clearing body results.
    public internal(set) var modeChanged = false
    /// Changed sources whose size or incomplete metadata exceeded the
    /// background read budget. A full pass can revisit them.
    public internal(set) var deferred = 0
    /// Estimated source bytes admitted, including reads that failed.
    public internal(set) var bytes: Int64 = 0
    public internal(set) var hasMore = false
    public internal(set) var cancelled = false
    /// A cursor query, body mode change, batch transaction or prune failed.
    public internal(set) var failed = false
    /// Another refresh owns the index. Retry this batch without advancing.
    public internal(set) var busy = false
    public internal(set) var completedDiscovery = false
    /// Pass this offset with the same candidate array to resume a batch.
    public internal(set) var nextCandidateOffset = 0
}

/// Keeps `SessionIndexStore` in step with what is actually on disk.
///
/// One pass walks every adapter's session files, fingerprints each one
/// (`SessionProviderAdapter.changeFingerprint` — for most providers the
/// file's modification time in nanoseconds + size), and re-reads only the
/// files whose fingerprint moved. Metadata is always indexed; message
/// bodies are indexed only while `bodyIndexing()` says so, and turning
/// that off drops the bodies on the next pass.
///
/// Nothing here hops to the main actor and nothing here throws: a file
/// that fails to parse is logged and skipped, because one unreadable
/// rollout must not cost the user every other session in the list.
public actor SessionIndexService {
    private let homeDirectory: String
    private let store: SessionIndexStore
    private let registry: SessionProviderRegistry
    private let bodyIndexing: @Sendable () -> Bool

    private struct Source: Sendable {
        let adapter: any SessionProviderAdapter
        let url: URL
        let hash: String
        let candidateRoots: [[String]]?

        init(adapter: any SessionProviderAdapter, url: URL, candidateRoots: [[String]]? = nil) {
            self.adapter = adapter
            self.url = url
            self.hash = SessionIndexService.pathHash(url.path)
            self.candidateRoots = candidateRoots
        }

        func canRead() -> Bool {
            guard let candidateRoots else { return true }
            guard url.isFileURL, !url.pathComponents.contains("..") else { return false }
            let physical: URL
            if adapter.provider == .devin {
                guard let locator = DevinSessionAdapter.locate(url) else { return false }
                physical = locator.database
            } else {
                physical = url
            }
            let components = SessionIndexService.pathComponents(physical)
            guard candidateRoots.contains(where: {
                components.count > $0.count && components.starts(with: $0)
            }) else { return false }

            var path = ""
            var info = stat()
            for (offset, component) in components.dropFirst().enumerated() {
                path += "/" + component
                let leaf = offset == components.count - 2
                guard lstat(path, &info) == 0,
                      info.st_mode & S_IFMT == (leaf ? S_IFREG : S_IFDIR) else { return false }
            }
            return true
        }
    }

    private struct Round {
        let sources: [Source?]
        let indexBodies: Bool
        var nextOffset = 0
    }

    private enum Request: Sendable {
        case full
        case batch(SessionIndexRefreshBudget)
        case candidates([SessionIndexCandidate], offset: Int, budget: SessionIndexRefreshBudget)

        var isFull: Bool {
            if case .full = self { return true }
            return false
        }
    }

    private var round: Round?
    private var activeRefresh: (full: Bool, task: Task<SessionIndexRefreshResult, Never>)?

    /// Body bytes committed in one SQLite/FTS5 transaction. The cap is on
    /// source excerpt bytes (not session count), so a batch remains bounded
    /// even when several sessions hit the existing 512 KiB per-session cap.
    static let indexBatchExcerptByteLimit = 4 * 1024 * 1024
    static let indexBatchEntryLimit = 128

    public init(
        homeDirectory: String = RealHomeDirectory.path,
        store: SessionIndexStore,
        registry: SessionProviderRegistry,
        bodyIndexing: @escaping @Sendable () -> Bool
    ) {
        self.homeDirectory = homeDirectory
        self.store = store
        self.registry = registry
        self.bodyIndexing = bodyIndexing
    }

    /// Bring the index up to date. `progress` is called after each file
    /// with `(filesDone, filesTotal)`.
    public func refreshIndex(progress: (@Sendable (Int, Int) -> Void)? = nil) async {
        await refreshIndexFully(progress: progress)
    }

    /// Complete a discovery round without a source-read budget. A full pass
    /// starts fresh so it can pick up any sources a background round skipped.
    @discardableResult
    public func refreshIndexFully(
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> SessionIndexRefreshResult {
        await run(.full, progress: progress)
    }

    /// Discover once and advance the current round within the budget. While
    /// `hasMore` is true the next call resumes from the last committed batch.
    public func refreshIndexBatch(
        budget: SessionIndexRefreshBudget,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> SessionIndexRefreshResult {
        await run(.batch(budget), progress: progress)
    }

    /// Recheck selected sources without discovery or pruning. Use the same
    /// array and the returned offset while `hasMore` is true.
    public func refreshIndexCandidates(
        _ candidates: [SessionIndexCandidate],
        budget: SessionIndexRefreshBudget,
        offset: Int = 0
    ) async -> SessionIndexRefreshResult {
        await run(.candidates(candidates, offset: offset, budget: budget), progress: nil)
    }

    private func run(
        _ request: Request,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async -> SessionIndexRefreshResult {
        while let activeRefresh {
            guard request.isFull else {
                var result = SessionIndexRefreshResult()
                result.busy = true
                result.hasMore = true
                if case let .candidates(_, offset, _) = request {
                    result.nextCandidateOffset = offset
                }
                return result
            }
            let result = await activeRefresh.task.value
            if activeRefresh.full, !result.cancelled || Task.isCancelled { return result }
        }

        let task = Task {
            let result = await perform(request, progress: progress)
            activeRefresh = nil
            return result
        }
        activeRefresh = (request.isFull, task)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func perform(
        _ request: Request,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async -> SessionIndexRefreshResult {
        var result = SessionIndexRefreshResult()
        if case let .candidates(candidates, offset, _) = request {
            result.nextCandidateOffset = min(max(offset, 0), candidates.count)
            result.hasMore = result.nextCandidateOffset < candidates.count
        }
        let indexBodies = bodyIndexing()
        guard !Task.isCancelled else {
            result.cancelled = true
            return result
        }
        do {
            result.modeChanged = try await store.applyBodyIndexingMode(indexBodies)
        } catch {
            result.cancelled = Task.isCancelled
            result.failed = !result.cancelled
            if result.failed { KitLog.warn("Session index: applying the body-indexing mode failed.") }
            return result
        }
        if round?.indexBodies != indexBodies { round = nil }

        let budget: SessionIndexRefreshBudget?
        if case let .candidates(candidates, offset, limits) = request {
            // Only build locators for this batch, not for the entire input
            // array on every continuation. The original offsets stay stable.
            let start = min(max(offset, 0), candidates.count)
            let end = start + min(candidates.count - start, limits.maxChecked)
            let registry = registry
            let home = homeDirectory
            let sources = await Self.offActor {
                var roots: [SessionProvider: [[String]]] = [:]
                return candidates[start..<end].map { candidate -> Source? in
                    guard let adapter = registry.adapter(for: candidate.provider) else { return nil }
                    let paths = roots[candidate.provider] ?? adapter.roots(homeDirectory: home)
                        .map(Self.pathComponents)
                    roots[candidate.provider] = paths
                    return Source(adapter: adapter, url: candidate.url, candidateRoots: paths)
                }
            }
            var next = 0
            result = await process(
                sources: sources, offset: &next, budget: limits, indexBodies: indexBodies, progress: nil,
                result: result
            )
            result.nextCandidateOffset = start + next
            result.hasMore = result.nextCandidateOffset < candidates.count
            return result
        }

        switch request {
        case .full:
            budget = nil
            round = nil
        case let .batch(limits): budget = limits
        case .candidates: return result // handled above
        }

        if round == nil {
            let registry = registry
            let home = homeDirectory
            let sources = await Self.offActor {
                Self.discover(
                    registry: registry, home: home, newestFirst: budget != nil
                )
            }
            guard !Task.isCancelled else {
                result.cancelled = true
                result.hasMore = true
                return result
            }
            round = Round(sources: sources, indexBodies: indexBodies)
        }
        guard var current = round else { return result }
        result = await process(
            sources: current.sources, offset: &current.nextOffset,
            budget: budget, indexBodies: indexBodies, progress: progress, result: result
        )
        round = current
        if result.cancelled || result.failed || result.hasMore { return result }

        let seen = await Self.offActor { [sources = current.sources] in Set(sources.compactMap { $0?.hash }) }
        guard !Task.isCancelled else {
            result.cancelled = true
            result.hasMore = true
            return result
        }
        do {
            result.pruned = try await store.pruneConfirmedMissing(
                existingPathHashes: seen, providers: Set(registry.providers)
            )
            result.completedDiscovery = true
            round = nil
        } catch {
            result.cancelled = Task.isCancelled
            result.failed = !result.cancelled
            result.hasMore = true
            if result.failed { KitLog.warn("Session index: pruning vanished sessions failed.") }
        }
        return result
    }

    public nonisolated func allSummaries() async throws -> [SessionSummary] {
        try await store.allSummaries()
    }

    public nonisolated func summaryPage(
        providers: [SessionProvider]? = nil,
        harnesses: [Harness]? = nil,
        since: Date? = nil,
        projectIncludes: [String] = [],
        projectExcludes: [String] = [],
        excludingProviderVariantPrefix: String? = nil,
        order: SessionSummaryOrder = .recentFirst,
        offset: Int = 0,
        limit: Int = 250
    ) async throws -> SessionSummaryPage {
        try await store.summaryPage(
            providers: providers,
            harnesses: harnesses,
            since: since,
            projectIncludes: projectIncludes,
            projectExcludes: projectExcludes,
            excludingProviderVariantPrefix: excludingProviderVariantPrefix,
            order: order,
            offset: offset,
            limit: limit
        )
    }

    public nonisolated func providerCounts() async throws -> [SessionProvider: Int] {
        try await store.providerCounts()
    }

    public nonisolated func harnessCounts() async throws -> [Harness: Int] {
        try await store.harnessCounts()
    }

    public nonisolated func search(
        _ text: String,
        providers: [SessionProvider]? = nil,
        harnesses: [Harness]? = nil,
        scopes: Set<SessionSearchScope> = SessionSearchScope.defaultScopes,
        projectIncludes: [String] = [],
        projectExcludes: [String] = [],
        limit: Int = 50
    ) async throws -> [SessionSearchHit] {
        try await store.search(
            text: text,
            providers: providers,
            harnesses: harnesses,
            scopes: scopes,
            projectIncludes: projectIncludes,
            projectExcludes: projectExcludes,
            limit: limit
        )
    }

    public nonisolated func summary(provider: SessionProvider, sessionID: String) async throws -> SessionSummary? {
        try await store.summary(provider: provider, sessionID: sessionID)
    }

    public nonisolated func summaries(
        provider: SessionProvider,
        providerVariantPrefix: String,
        limit: Int = 2_000
    ) async throws -> [SessionSummary] {
        try await store.summaries(
            provider: provider,
            providerVariantPrefix: providerVariantPrefix,
            limit: limit
        )
    }

    // MARK: - Bounded rebuild batches

    private static func discover(
        registry: SessionProviderRegistry, home: String, newestFirst: Bool
    ) -> [Source?] {
        var sources: [(source: Source, mtime: Int64)] = []
        for adapter in registry.adapters {
            guard !Task.isCancelled else { break }
            for url in adapter.discoverSessionFiles(homeDirectory: home) {
                guard !Task.isCancelled else { break }
                // Virtual locators retain their adapter's existing order.
                // A bounded cold pass puts recent filesystem sources first;
                // its later slices reuse this one priority snapshot.
                let mtime: Int64
                if newestFirst, adapter.provider != .devin {
                    mtime = (try? SessionChangeFingerprint.statFingerprint(url.path).get())?.mtimeNanos ?? .min
                } else {
                    mtime = .min
                }
                sources.append((Source(adapter: adapter, url: url), mtime))
            }
        }
        if newestFirst { sources.sort { $0.mtime > $1.mtime } }
        return sources.map(\.source)
    }

    private func process(
        sources: [Source?],
        offset: inout Int,
        budget: SessionIndexRefreshBudget?,
        indexBodies: Bool,
        progress: (@Sendable (Int, Int) -> Void)?,
        result: SessionIndexRefreshResult
    ) async -> SessionIndexRefreshResult {
        var result = result
        var filesRead = 0
        let deadline = budget?.maxDuration.map { ContinuousClock.now.advanced(by: $0) }
        while offset < sources.count, !Task.isCancelled {
            let checkRoom = (budget?.maxChecked ?? .max) - result.checked
            let readRoom = (budget?.maxFiles ?? .max) - filesRead
            guard checkRoom > 0, readRoom > 0,
                  result.checked == 0 || deadline.map({ ContinuousClock.now < $0 }) != false
            else { break }

            let end = offset + min(Self.indexBatchEntryLimit, checkRoom, sources.count - offset)
            let chunk = sources[offset..<end]
            do {
                let cursors = try await store.fileCursors(pathHashes: chunk.compactMap { $0?.hash })
                let processed = await Self.offActor { [start = offset, bytes = result.bytes, checked = result.checked] in
                    Self.prepare(
                        chunk: chunk,
                        cursors: cursors,
                        indexBodies: indexBodies,
                        budget: budget,
                        bytesUsed: bytes,
                        maxReads: readRoom,
                        deadline: deadline,
                        allowFirstFile: checked == 0,
                        report: { done in progress?(start + done, sources.count) }
                    )
                }
                result.checked += processed.checked
                result.changed += processed.changed
                result.parsed += processed.parsed
                result.deferred += processed.deferred
                result.bytes += processed.bytes
                filesRead += processed.filesRead

                guard !Task.isCancelled else { break }
                guard bodyIndexing() == indexBodies else {
                    result.cancelled = true
                    result.hasMore = true
                    return result
                }
                if !processed.entries.isEmpty {
                    try await store.applyIndexBatch(processed.entries)
                    result.written += processed.entries.count
                    if budget == nil {
                        await store.releaseTransientMemory()
                        _ = malloc_zone_pressure_relief(nil, 0)
                    }
                }
                offset += processed.checked
                if processed.budgetExhausted { break }
            } catch {
                KitLog.warn("Session index: processing a bounded batch failed.")
                result.failed = true
                break
            }
        }
        result.cancelled = Task.isCancelled
        result.hasMore = offset < sources.count
        return result
    }

    private struct PreparedChunk: Sendable {
        var checked = 0
        var changed = 0
        var filesRead = 0
        var parsed = 0
        var deferred = 0
        var bytes: Int64 = 0
        var entries: [SessionIndexStore.IndexBatchEntry] = []
        var budgetExhausted = false
    }

    private static func prepare(
        chunk: ArraySlice<Source?>,
        cursors: [String: SessionIndexStore.FileCursor],
        indexBodies: Bool,
        budget: SessionIndexRefreshBudget?,
        bytesUsed: Int64,
        maxReads: Int,
        deadline: ContinuousClock.Instant?,
        allowFirstFile: Bool,
        report: (Int) -> Void
    ) -> PreparedChunk {
        var result = PreparedChunk()
        var excerptBytes = 0
        for source in chunk {
            guard !Task.isCancelled else { break }
            guard result.filesRead < maxReads,
                  (allowFirstFile && result.checked == 0)
                    || deadline.map({ ContinuousClock.now < $0 }) != false else {
                result.budgetExhausted = true
                break
            }

            guard let source,
                  source.canRead(),
                  let before = source.adapter.changeFingerprint(fileURL: source.url),
                  !cursors[source.hash].matches(before, acceptingPartial: budget != nil) else {
                result.checked += 1
                report(result.checked)
                continue
            }
            let plan: SessionIndexReadPlan?
            if let budget {
                let sourceBytes = sourceSize(for: source)
                plan = sourceBytes.flatMap {
                    source.adapter.boundedIndexReadPlan(
                        fileURL: source.url, sourceBytes: $0, indexBodies: indexBodies
                    )
                }
                let fallbackBytes = SessionLogByteReader.isCompressedName(source.url.lastPathComponent)
                    ? nil : sourceBytes
                guard let bytes = plan?.estimatedBytes ?? fallbackBytes,
                      bytes >= 0, bytes <= budget.maxFileBytes else {
                    result.checked += 1
                    result.changed += 1
                    result.deferred += 1
                    report(result.checked)
                    continue
                }
                guard bytes <= budget.maxBytes - bytesUsed - result.bytes else {
                    result.budgetExhausted = true
                    break
                }
                result.bytes += bytes
            } else {
                plan = nil
            }

            result.checked += 1
            result.changed += 1
            result.filesRead += 1
            do {
                guard source.canRead() else {
                    report(result.checked)
                    continue
                }
                let entry = try autoreleasepool {
                    let summary = try plan?.extractMetadata()
                        ?? source.adapter.extractMetadata(fileURL: source.url)
                    let excerpts: [SessionIndexStore.MessageExcerpt]?
                    if indexBodies {
                        guard source.canRead() else { throw SessionIndexReadDeferred() }
                        result.parsed += 1
                        let document = try source.adapter.parseTranscript(fileURL: source.url, range: nil)
                        excerpts = Self.excerpts(from: document, provider: summary.provider)
                    } else {
                        excerpts = nil
                    }
                    var entry = SessionIndexStore.IndexBatchEntry(
                        summary: summary, pathHash: source.hash, path: source.url.path,
                        provider: source.adapter.provider, mtimeNanos: before.mtimeNanos,
                        size: before.size, excerpts: excerpts
                    )
                    entry.requiresFullRefresh = plan?.requiresFullRefresh == true
                    entry.clearsPartial = cursors[source.hash]?.requiresFullRefresh == true
                    return entry
                }
                // If it changed during the read, leave the old cursor and
                // retry on a later refresh. A partial read never marks newer
                // contents as indexed.
                if !Task.isCancelled, source.canRead(), source.adapter.changeFingerprint(fileURL: source.url) == before {
                    result.entries.append(entry)
                    excerptBytes += entry.excerpts?.reduce(0) { $0 + $1.excerpt.utf8.count } ?? 0
                }
            } catch is SessionIndexReadDeferred {
                result.deferred += 1
            } catch {
                KitLog.warn(
                    "Session index: skipped \(source.adapter.provider.rawValue) file "
                        + "\(KitLog.sanitize(source.url.lastPathComponent))."
                )
            }
            report(result.checked)
            if excerptBytes >= Self.indexBatchExcerptByteLimit { break }
        }
        return result
    }

    private static func sourceIsRegularFile(_ source: Source) -> Bool {
        let url = source.adapter.provider == .devin ? source.url.deletingLastPathComponent() : source.url
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    private static func sourceSize(for source: Source) -> Int64? {
        if source.adapter.provider == .codex, CodexRolloutFile.isCompressed(source.url) {
            // A transcode may be in progress while both spellings exist.
            // Keep the authoritative plain row until the replacement is ready.
            let plain = CodexRolloutFile.canonicalPath(source.url.path)
            var info = stat()
            if lstat(plain, &info) == 0, info.st_mode & S_IFMT == S_IFREG { return nil }
        }
        guard sourceIsRegularFile(source),
              let physical = SessionChangeFingerprint.file(at: source.url) else { return nil }
        switch source.adapter.provider {
        case .grok:
            let history = source.url.deletingLastPathComponent()
                .appendingPathComponent(GrokSessionAdapter.chatHistoryFileName)
            return physical.folding(SessionChangeFingerprint.file(at: history)).size
        case .mistralVibe:
            let metadata = MistralVibeSessionAdapter.metadataURL(forMessages: source.url)
            return physical.folding(SessionChangeFingerprint.file(at: metadata)).size
        default:
            return physical.size
        }
    }

    private static func offActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: Task.currentPriority, operation: work)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func pathComponents(_ url: URL) -> [String] {
        var components = url.standardizedFileURL.pathComponents
        // Darwin's standard top-level aliases are trusted platform paths.
        // Do not resolve a link within a provider's or a user's directory.
        if components.count > 1, ["var", "tmp", "etc"].contains(components[1]) {
            components.insert("private", at: 1)
        }
        return components
    }

    static func pathHash(_ path: String) -> String {
        PrivacyPreservingHash.fileComponent(prefix: "session-path-v1", rawValue: path)
    }

    // MARK: - Excerpt policy

    /// Per-message cap. Long enough to keep a paragraph of context around
    /// a match, short enough that a pasted file does not become the
    /// index.
    static let maxExcerptCharacters = 2_000
    /// Per-session cap on indexed text. A transcript past this is
    /// indexed from the top and truncated.
    static let maxSessionExcerptBytes = 512 * 1024

    /// Every semantic message role is indexed so the caller can choose the
    /// exact search surface. Machine envelopes are still removed before the
    /// text reaches SQLite; a system/tool-only search should find intentional
    /// content, not the identical harness bootstrap copied into every log.
    static func excerpts(
        from document: TranscriptDocument,
        provider: SessionProvider
    ) -> [SessionIndexStore.MessageExcerpt] {
        var out: [SessionIndexStore.MessageExcerpt] = []
        var budget = maxSessionExcerptBytes
        for message in document.messages {
            guard let text = normalize(message.text, role: message.role, provider: provider) else { continue }
            var parts: [(role: SessionRole, text: String)] = []
            if message.role == .assistant {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                if let marker = lines.firstIndex(where: {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("[Tool: ")
                }) {
                    let prose = lines[..<marker].joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let tool = lines[marker...].joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !prose.isEmpty { parts.append((.assistant, prose)) }
                    if !tool.isEmpty { parts.append((.tool, tool)) }
                } else {
                    parts.append((.assistant, text))
                }
            } else {
                parts.append((message.role == .other ? .system : message.role, text))
            }
            for part in parts {
                let cost = part.text.utf8.count
                guard cost <= budget else { return out }
                budget -= cost
                out.append(SessionIndexStore.MessageExcerpt(
                    seq: message.seq,
                    role: part.role,
                    excerpt: part.text
                ))
            }
        }
        return out
    }

    static func normalize(_ raw: String, role: SessionRole, provider: SessionProvider) -> String? {
        var text = raw
        if provider == .codex {
            text = CodexSessionAdapter.strippingIDEEnvelope(text)
            if role == .user {
                guard let instruction = HumanPromptText.instruction(text) else { return nil }
                text = instruction
            }
        }
        guard !ClaudeSessionAdapter.isEnvelopeText(text) else { return nil }

        let kept = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty else { return nil }
        return SessionParsing.truncate(kept, limit: maxExcerptCharacters)
    }
}

private extension Optional where Wrapped == SessionIndexStore.FileCursor {
    func matches(_ fingerprint: SessionChangeFingerprint, acceptingPartial: Bool) -> Bool {
        guard let self, acceptingPartial || !self.requiresFullRefresh,
              self.mtimeNanos != .min || self.size != .min else { return false }
        return self.mtimeNanos == fingerprint.mtimeNanos && self.size == fingerprint.size
    }
}
