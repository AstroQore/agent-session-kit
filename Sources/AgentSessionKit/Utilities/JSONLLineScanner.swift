import Foundation

/// Linear-time line walk over an append-only JSONL log.
///
/// Every adapter that reads a whole transcript goes through here rather
/// than splitting the file in memory. Session logs reach hundreds of
/// megabytes, and the naive `String(contentsOf:).split(separator: "\n")`
/// is both quadratic in allocation and holds the entire file resident.
public enum JSONLLineScanner {
    /// Bytes read per `read(upToCount:)`. Also the compaction threshold:
    /// the scratch buffer only shifts once a full chunk has been consumed.
    private static let chunkSize = 64 * 1024

    /// Call `body` once per non-empty line, without the trailing newline.
    ///
    /// - Returns: `true` when the file was opened and walked to the end,
    ///   `false` when it could not be opened or a read threw part-way. A
    ///   partial walk still delivers whatever lines it managed to read, so
    ///   callers that care about completeness must check the return value
    ///   rather than the number of lines they saw.
    @discardableResult
    public static func forEachLine(in file: URL, _ body: (Data) -> Void) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }

        // Linear-time JSONL scan via [UInt8]: walks a single moving cursor
        // and only compacts when the consumed prefix exceeds one chunk. We
        // intentionally avoid Data as the scratch buffer — Data.removeFirst
        // can leave heap-backed storage with a non-zero startIndex, after
        // which 0-based subscripting like `buffer[i]` trips a bounds
        // precondition under release optimization. Array<UInt8>.removeFirst
        // physically shifts bytes and keeps indices 0-based, so this loop
        // is safe and still O(n).
        var buffer: [UInt8] = []
        var lineStart = 0
        do {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                buffer.append(contentsOf: chunk)
                let end = buffer.count
                var i = lineStart
                while i < end {
                    if buffer[i] == 0x0A {
                        if i > lineStart {
                            body(Data(buffer[lineStart..<i]))
                        }
                        lineStart = i + 1
                    }
                    i += 1
                }
                if lineStart > chunkSize {
                    buffer.removeFirst(lineStart)
                    lineStart = 0
                }
            }
            if lineStart < buffer.count {
                let tail = Data(buffer[lineStart..<buffer.count])
                if !tail.isEmpty {
                    body(tail)
                }
            }
            return true
        } catch {
            return false
        }
    }
}
