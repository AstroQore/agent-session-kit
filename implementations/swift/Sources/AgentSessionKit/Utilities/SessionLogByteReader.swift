import Foundation

/// Sequential byte access to a session log, plain or zstd-compressed.
///
/// Every reader in this package that walks a transcript — the line
/// scanner, head/tail extraction, a host's offset-aware turn reader — asks
/// for bytes through here instead of a `FileHandle`, so a Codex rollout
/// that has become `rollout-*.jsonl.zst` reads exactly like the `.jsonl`
/// it was. Offsets are always *decompressed* offsets: a turn recorded at
/// byte 4096 of the original file is still at 4096 after Codex compresses
/// it, which is what lets a cached outline survive the rename.
///
/// Seeking forward in a compressed log decodes and discards; seeking
/// backward restarts the stream. Both are linear in the distance, which is
/// the price of a format with no index — and a compressed rollout is, by
/// Codex's own rule, one nobody has touched for a week.
public final class SessionLogByteReader {
    private enum Backing {
        case plain(FileHandle)
        case compressed(ZstdStreamDecoder, URL)
    }

    private var backing: Backing
    public let url: URL
    /// Whether the bytes are being decoded from a zstd stream.
    public var isCompressed: Bool {
        if case .compressed = backing { return true }
        return false
    }

    /// `nil` when the file cannot be opened. The format is decided by the
    /// name: a `.zst` suffix means zstd, anything else is read as-is.
    public init?(url: URL) {
        self.url = url
        if Self.isCompressedName(url.lastPathComponent) {
            guard let decoder = try? ZstdStreamDecoder(url: url) else { return nil }
            backing = .compressed(decoder, url)
        } else {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            backing = .plain(handle)
        }
    }

    deinit { close() }

    /// `rollout-…jsonl.zst` and any other `.zst`-suffixed log.
    public static func isCompressedName(_ name: String) -> Bool {
        name.hasSuffix(".zst")
    }

    /// Up to `count` bytes, `nil` at end of file.
    public func read(upToCount count: Int) throws -> Data? {
        switch backing {
        case .plain(let handle):
            return try handle.read(upToCount: count)
        case .compressed(let decoder, _):
            return try decoder.read(upToCount: count)
        }
    }

    /// Position the next `read` at `offset` (a decompressed offset for a
    /// compressed log).
    public func seek(toOffset offset: Int64) throws {
        switch backing {
        case .plain(let handle):
            try handle.seek(toOffset: UInt64(max(0, offset)))
        case .compressed(let decoder, let url):
            if offset < decoder.offset {
                decoder.close()
                let fresh = try ZstdStreamDecoder(url: url)
                backing = .compressed(fresh, url)
                try fresh.skip(toOffset: offset)
            } else {
                try decoder.skip(toOffset: offset)
            }
        }
    }

    public func close() {
        switch backing {
        case .plain(let handle): try? handle.close()
        case .compressed(let decoder, _): decoder.close()
        }
    }

    /// Whole decompressed contents. Only for logs already known to be
    /// small (callers bound this by the on-disk size); streams otherwise.
    public static func contents(of url: URL) -> Data? {
        guard let reader = SessionLogByteReader(url: url) else { return nil }
        defer { reader.close() }
        var out = Data()
        do {
            while let chunk = try reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                out.append(chunk)
            }
        } catch {
            return nil
        }
        return out
    }
}
