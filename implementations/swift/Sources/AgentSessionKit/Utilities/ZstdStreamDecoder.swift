import CZstd
import Foundation

/// Streaming Zstandard decoder over a file, one frame sequence in, plain
/// bytes out.
///
/// Codex's `local_thread_store_compression` rewrites a rollout it has not
/// touched for a week as `rollout-<stamp>-<uuid>.jsonl.zst` — the same
/// JSONL, zstd-framed. The decoder pulls compressed chunks through
/// `ZSTD_decompressStream` on demand, so memory stays bounded by the two
/// recommended buffer sizes (~128 KiB each) no matter how large the
/// decompressed transcript is. It never writes anything.
///
/// Not thread-safe: one decoder serves one reader on one thread.
public final class ZstdStreamDecoder {
    public enum DecodeError: Error, Equatable {
        case cannotOpen
        case streamInitFailed
        /// `ZSTD_getErrorName` of the failing step.
        case corrupt(String)
        /// The file ended inside a frame.
        case truncated
    }

    private let handle: FileHandle
    private let stream: OpaquePointer
    private let inputCapacity: Int
    private var input: [UInt8]
    /// Bytes of `input` not yet consumed by the decoder: `[inputPos, inputEnd)`.
    private var inputPos = 0
    private var inputEnd = 0
    private var reachedInputEnd = false
    /// Decompressed bytes handed out so far — the offset a reader sits at.
    public private(set) var offset: Int64 = 0
    private var isClosed = false

    public init(url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw DecodeError.cannotOpen }
        guard let stream = ZSTD_createDStream() else {
            try? handle.close()
            throw DecodeError.streamInitFailed
        }
        let initResult = ZSTD_initDStream(stream)
        if ZSTD_isError(initResult) != 0 {
            ZSTD_freeDStream(stream)
            try? handle.close()
            throw DecodeError.streamInitFailed
        }
        self.handle = handle
        self.stream = stream
        self.inputCapacity = ZSTD_DStreamInSize()
        self.input = [UInt8](repeating: 0, count: inputCapacity)
    }

    deinit { close() }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        ZSTD_freeDStream(stream)
        try? handle.close()
    }

    /// Size the decoder would like to produce per call.
    public static var recommendedOutputSize: Int { ZSTD_DStreamOutSize() }

    /// Up to `count` decompressed bytes; `nil` once the stream is exhausted.
    ///
    /// A short result is not end-of-stream — only `nil` is. A frame that
    /// ends mid-way through the file throws `truncated`; damaged input
    /// throws `corrupt` with zstd's own description.
    public func read(upToCount count: Int) throws -> Data? {
        guard !isClosed, count > 0 else { return nil }
        var output = [UInt8](repeating: 0, count: count)
        var produced = 0
        while produced < count {
            if inputPos >= inputEnd {
                guard try refill() else {
                    // The file is spent. A frame still open means the
                    // writer never finished (or the file was cut).
                    if inFrame { throw DecodeError.truncated }
                    break
                }
            }
            let positionBefore = (inputPos, produced)
            var inBuffer = ZSTD_inBuffer(src: nil, size: 0, pos: 0)
            var outBuffer = ZSTD_outBuffer(dst: nil, size: 0, pos: 0)
            let result: Int = input.withUnsafeMutableBytes { inRaw in
                output.withUnsafeMutableBytes { outRaw in
                    inBuffer = ZSTD_inBuffer(src: inRaw.baseAddress, size: inputEnd, pos: inputPos)
                    outBuffer = ZSTD_outBuffer(dst: outRaw.baseAddress, size: count, pos: produced)
                    return ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
                }
            }
            if ZSTD_isError(result) != 0 {
                throw DecodeError.corrupt(String(cString: ZSTD_getErrorName(result)))
            }
            inputPos = inBuffer.pos
            produced = outBuffer.pos
            inFrame = result != 0
            // zstd always advances one side when output has room; a call
            // that moves neither would spin forever, so treat it as damage.
            if positionBefore == (inputPos, produced), inputPos < inputEnd {
                throw DecodeError.corrupt("decoder made no progress")
            }
        }
        guard produced > 0 else { return nil }
        offset += Int64(produced)
        return Data(output[0..<produced])
    }

    /// Whether the last `ZSTD_decompressStream` call left a frame open.
    private var inFrame = false

    /// Discard decompressed bytes until `offset` reaches `target`.
    /// Returns `false` when the stream ends first.
    @discardableResult
    public func skip(toOffset target: Int64) throws -> Bool {
        let chunk = Self.recommendedOutputSize
        while offset < target {
            let want = Int(min(Int64(chunk), target - offset))
            guard try read(upToCount: want) != nil else { return false }
        }
        return true
    }

    /// Pulls the next compressed chunk. `false` at end of file.
    private func refill() throws -> Bool {
        guard !reachedInputEnd else { return false }
        let chunk: Data? = try autoreleasepool { try handle.read(upToCount: inputCapacity) }
        guard let chunk, !chunk.isEmpty else {
            reachedInputEnd = true
            return false
        }
        inputEnd = chunk.count
        inputPos = 0
        input.withUnsafeMutableBytes { raw in
            chunk.copyBytes(to: raw.bindMemory(to: UInt8.self), count: chunk.count)
        }
        return true
    }
}
