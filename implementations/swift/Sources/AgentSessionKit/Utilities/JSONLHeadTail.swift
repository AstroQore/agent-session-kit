import Foundation

/// Byte-level head / tail line access for append-only JSONL logs.
///
/// Session metadata only needs the first and last handful of lines of a
/// rollout file. Reading a multi-megabyte transcript to learn its title
/// would make a session list unusable, so files above
/// `wholeFileThreshold` are seeked into instead: the tail window starts
/// at `length - wholeFileThreshold`, and the (almost certainly partial)
/// first line inside that window is discarded.
///
/// Everything works on raw bytes and splits on `0x0A`, which cannot
/// appear inside a multi-byte UTF-8 sequence, so a window boundary can
/// never cut a scalar in half.
///
/// A zstd-compressed log (`.jsonl.zst`) has no seekable tail, so its
/// last lines come from one streaming pass that keeps only the final
/// `count` lines in memory and gives up — returning nothing — once
/// `compressedReadBudget` decompressed bytes have gone by, so metadata
/// extraction stays bounded for a transcript of any size. `fileSize`
/// stays the on-disk (compressed) size.
public enum JSONLHeadTail {
    /// Files at or below this size are read whole.
    public static let wholeFileThreshold: Int64 = 16 * 1024

    /// Most decompressed bytes a tail or line-count pass over a compressed
    /// log will decode before giving up. A tail that needs more is reported
    /// as empty and a count as unknown; callers already fall back (to the
    /// file's modification date, to the "not counted" sentinel). 32 MiB
    /// decodes in well under a second and covers all but the largest
    /// rollouts; past that, bounded work matters more than the last line.
    public static let compressedReadBudget: Int64 = 32 * 1024 * 1024

    private static let chunkSize = 16 * 1024

    /// First `count` non-empty lines, reading only as far as needed.
    ///
    /// `maxBytes` caps how much of the file is read at all. A head whose
    /// lines run past it ends at the last complete line inside the budget,
    /// so one enormous (or newline-free) first record cannot pull a whole
    /// transcript into memory to learn a title.
    public static func headLines(url: URL, count: Int, maxBytes: Int? = nil) -> [Data] {
        guard count > 0 else { return [] }
        guard let handle = SessionLogByteReader(url: url) else { return [] }
        defer { handle.close() }

        var out: [Data] = []
        var buffer: [UInt8] = []
        var lineStart = 0
        var bytesRead = 0
        do {
            while out.count < count,
                  maxBytes.map({ bytesRead < $0 }) ?? true,
                  let chunk = try handle.read(upToCount: maxBytes.map { min(chunkSize, $0 - bytesRead) } ?? chunkSize),
                  !chunk.isEmpty {
                bytesRead += chunk.count
                buffer.append(contentsOf: chunk)
                let end = buffer.count
                var i = lineStart
                while i < end {
                    if buffer[i] == 0x0A {
                        if i > lineStart {
                            out.append(Data(buffer[lineStart..<i]))
                        }
                        lineStart = i + 1
                        if out.count >= count { return out }
                    }
                    i += 1
                }
                if lineStart > chunkSize {
                    buffer.removeFirst(lineStart)
                    lineStart = 0
                }
            }
            // An unterminated remainder is a whole last line only when the
            // file ended; a spent budget leaves it partial, so it is dropped.
            let exhausted = maxBytes.map { bytesRead >= $0 } ?? false
            if out.count < count, !exhausted, lineStart < buffer.count {
                let tail = Data(buffer[lineStart..<buffer.count])
                if !tail.isEmpty { out.append(tail) }
            }
        } catch {
            return out
        }
        return out
    }

    /// Last `count` non-empty lines.
    ///
    /// Files at or below `wholeFileThreshold` are read whole. Larger
    /// files are seeked to `length - wholeFileThreshold`; the byte just
    /// before that offset decides whether the window opens on a line
    /// boundary or mid-line, and a mid-line opening drops its first
    /// (partial) segment.
    ///
    /// The window is fixed, so a `count` larger than the number of
    /// lines inside `wholeFileThreshold` bytes returns fewer lines than
    /// asked for. That is the point: metadata extraction must stay
    /// bounded no matter how large the transcript grew.
    public static func tailLines(url: URL, count: Int) -> [Data] {
        guard count > 0 else { return [] }
        let size = fileSize(url)
        guard size > 0 else { return [] }
        if SessionLogByteReader.isCompressedName(url.lastPathComponent) {
            return streamedTailLines(url: url, count: count)
        }

        var segments: [Data]
        if size <= wholeFileThreshold {
            guard let whole = try? Data(contentsOf: url) else { return [] }
            segments = splitLines(whole)
        } else {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }
            // Seek one byte early so we can tell a boundary-aligned
            // window from one that opens in the middle of a line.
            let probe = UInt64(size - wholeFileThreshold) - 1
            var read: Data?
            do {
                try handle.seek(toOffset: probe)
                read = try handle.readToEnd()
            } catch {
                return []
            }
            guard let window = read, !window.isEmpty else { return [] }

            if window.first == 0x0A {
                segments = splitLines(Data(window.dropFirst()))
            } else {
                segments = splitLines(window)
                if !segments.isEmpty { segments.removeFirst() }
            }
        }

        segments.removeAll { $0.isEmpty }
        if segments.count > count {
            segments.removeFirst(segments.count - count)
        }
        return segments
    }

    /// Last `count` non-empty lines of a compressed log: one pass through
    /// a fixed ring of `count` slots, so the walk stays O(lines) whatever
    /// `count` is, and memory is those lines plus one read chunk. Empty when
    /// the log does not end within `compressedReadBudget` decompressed
    /// bytes or the stream cannot be read to its end.
    static func streamedTailLines(url: URL, count: Int, budget: Int64 = compressedReadBudget) -> [Data] {
        var ring = [Data](repeating: Data(), count: count)
        var next = 0
        var stored = 0
        var decoded: Int64 = 0
        var overBudget = false
        let completed = JSONLLineScanner.scanLines(in: url, while: { line in
            decoded += Int64(line.count) + 1
            if decoded > budget { overBudget = true; return false }
            ring[next] = line
            next = (next + 1) % count
            if stored < count { stored += 1 }
            return true
        })
        guard completed, !overBudget else { return [] }
        let start = stored < count ? 0 : next
        return (0..<stored).map { ring[(start + $0) % count] }
    }

    /// Non-empty line count, but only for files small enough that a
    /// whole-file read is free. Returns `nil` for anything larger so
    /// callers can record a "not counted" sentinel instead of paying
    /// for a full scan during metadata extraction. The bound is the
    /// on-disk size, so a compressed log is counted while its archive is
    /// small; its decoded output is counted as it streams and capped at
    /// `compressedReadBudget`, since a small archive can expand a lot.
    public static func lineCountIfSmall(url: URL, maxBytes: Int64 = wholeFileThreshold) -> Int? {
        let size = fileSize(url)
        guard size >= 0, size <= maxBytes else { return nil }
        if SessionLogByteReader.isCompressedName(url.lastPathComponent) {
            return streamedLineCount(url: url, budget: compressedReadBudget)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        var count = 0
        var segmentLength = 0
        for byte in data {
            if byte == 0x0A {
                if segmentLength > 0 { count += 1 }
                segmentLength = 0
            } else {
                segmentLength += 1
            }
        }
        if segmentLength > 0 { count += 1 }
        return count
    }

    /// Non-empty lines of a compressed log, streamed; `nil` past `budget`
    /// decompressed bytes or when the stream cannot be read to its end.
    static func streamedLineCount(url: URL, budget: Int64) -> Int? {
        var count = 0
        var decoded: Int64 = 0
        var overBudget = false
        let completed = JSONLLineScanner.scanLines(in: url, while: { line in
            decoded += Int64(line.count) + 1
            if decoded > budget { overBudget = true; return false }
            count += 1
            return true
        })
        return completed && !overBudget ? count : nil
    }

    public static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return -1
        }
        return (attrs[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// Split on `0x0A`, keeping empty segments so positional decisions
    /// (like "drop the first, partial line") stay accurate.
    private static func splitLines(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var out: [Data] = []
        var start = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                out.append(Data(bytes[start..<i]))
                start = i + 1
            }
            i += 1
        }
        if start < bytes.count {
            out.append(Data(bytes[start..<bytes.count]))
        }
        return out
    }
}
