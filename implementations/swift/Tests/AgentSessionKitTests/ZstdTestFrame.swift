import Foundation

/// Builds a valid Zstandard frame out of *raw* (stored, uncompressed)
/// blocks, so tests can produce `.zst` inputs of any content and size
/// without a compressor in the package. The decoder treats raw blocks
/// like any other, which is what makes the frame-level code paths —
/// chunking, seeking, truncation, end-of-stream — testable this way.
///
/// Layout (RFC 8878): magic `0xFD2FB528`, a frame header with
/// `Single_Segment_flag` set and an 8-byte `Frame_Content_Size`, then raw
/// blocks of at most 128 KiB, the last one flagged.
enum ZstdTestFrame {
    static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
    static let maxBlockSize = 128 * 1024

    static func wrap(_ content: Data) -> Data {
        var out = Data(magic)
        // Frame_Content_Size_flag = 3 (8 bytes) | Single_Segment_flag.
        out.append(0xE0)
        var size = UInt64(content.count).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }

        let bytes = [UInt8](content)
        var cursor = 0
        repeat {
            let length = min(maxBlockSize, bytes.count - cursor)
            let isLast = cursor + length >= bytes.count
            // 3-byte little-endian header: bit 0 Last_Block, bits 1–2
            // Block_Type (0 = Raw_Block), bits 3+ Block_Size.
            let header = UInt32(length) << 3 | (isLast ? 1 : 0)
            out.append(UInt8(header & 0xFF))
            out.append(UInt8((header >> 8) & 0xFF))
            out.append(UInt8((header >> 16) & 0xFF))
            out.append(contentsOf: bytes[cursor..<cursor + length])
            cursor += length
        } while cursor < bytes.count
        return out
    }

    static func write(_ content: Data, to url: URL) throws {
        try wrap(content).write(to: url)
    }

    /// A rollout fixture compressed by the zstd 1.5.7 CLI at level 19:
    /// three lines, a `session_meta` and two `response_item` messages,
    /// 619 bytes decompressed. Exercises real compressed blocks.
    static let cliCompressedRollout = Data(base64Encoded: """
    KLUv/WRrAXUJAKaUPh8wj3Uj7KPgugsqqC6wIHG3HhaVmdl8wxlTiZcRhBQVNQA5ADIAUyRof6fi\
    M+8UnBUG0rPDXkuSMzIv/30pps/OcBDhEUDvAD2oJQbNcc0puOb+Ti3YvFbsZwLVJF2WmtPf62wo\
    IyTWeXbJrDSwFbXgZQNclxWBv1OWiT06QFFz0yGCXOQMNjo4zvAwONPg0RxI4FzVrGdfCGRey9qO\
    0rKclLe21h4HuK5HKJfOv9elYmVWKlVLTevs7ztVyuSzP3UrZ+cqxYDrclx/OjZyNhAZJ3UumjJb\
    wubIDAeO682xapqNdENRiL+z92VbagqVsfHeclvO6ex1mRISADTzxswod5AulxEeuByiIn6naqEZ\
    vigRZKzzwdBiLHRCsZ4DXywsy8RAVgD1uwxnwAm9mQ==
    """)!

    static let cliCompressedRolloutLines: [String] = [
        #"{"timestamp":"2026-02-03T05:58:51.452Z","type":"session_meta","payload":{"id":"019c2215-0f3c-7f72-89e3-92598c209589","timestamp":"2026-02-03T05:58:51.452Z","cwd":"/Users/example/proj","originator":"codex_cli_rs","cli_version":"0.0.0","source":"cli","model_provider":"openai"}}"#,
        #"{"timestamp":"2026-02-03T05:58:52.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add the session list"}]}}"#,
        #"{"timestamp":"2026-02-03T05:58:53.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Working on it."}]}}"#
    ]
}
