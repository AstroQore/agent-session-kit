import Foundation

/// A minimal protobuf **wire-format** reader for undocumented payloads.
///
/// Cursor stores its agent history as content-addressed protobuf nodes with
/// no published schema, so the only thing that can be relied on is the wire
/// encoding itself: a varint key whose low three bits are the wire type and
/// whose remaining bits are the field number, followed by a value whose
/// length that wire type determines. This decodes exactly that, the way
/// `protoc --decode_raw` does, and leaves every interpretation to the caller.
///
/// Deliberately *not* shared with `AntigravityStepText`: that one is a
/// recursive, byte-budgeted walk fused with a prose filter, and flattening it
/// onto this iterator would change which runs it keeps. This reader is a flat
/// pass over one message's own fields.
/// Public because `AgentSessionLive` walks the same Cursor blob graph
/// incrementally. Reimplementing varint framing in a second module is how two
/// copies end up disagreeing about a truncated blob.
public enum ProtobufWireReader {
    /// Fields decoded from a single message. A malformed or truncated field
    /// ends the pass — everything before it is still returned, because these
    /// blobs come off another app's disk and a partial read beats none.
    public struct Field {
        /// The field number carried by the wire key.
        public let number: Int
        /// The payload, as its wire type describes it.
        public let value: Value
    }

    /// A field's payload, untyped — there is no schema to interpret it with.
    public enum Value {
        /// Wire type 0.
        case varint(UInt64)
        /// Wire type 1.
        case fixed64(UInt64)
        /// Wire type 2: a length-delimited run, which is a string, a blob
        /// reference, or a nested message depending on who wrote it.
        case bytes(ArraySlice<UInt8>)
        /// Wire type 5.
        case fixed32(UInt32)
    }

    /// Fields visited per message. Bounds the pass on a hostile or corrupt
    /// blob without needing to trust its declared lengths.
    public static let defaultFieldLimit = 4_096

    /// Every field of one message, in wire order.
    public static func fields(in bytes: [UInt8], limit: Int = defaultFieldLimit) -> [Field] {
        fields(in: bytes, range: bytes.startIndex..<bytes.endIndex, limit: limit)
    }

    /// Every field within `range` of `bytes`, in wire order.
    public static func fields(
        in bytes: [UInt8],
        range: Range<Int>,
        limit: Int = defaultFieldLimit
    ) -> [Field] {
        var out: [Field] = []
        var index = range.lowerBound
        let end = range.upperBound
        while index < end, out.count < limit {
            guard let key = varint(bytes, &index, end), key != 0 else { return out }
            let number = Int(key >> 3)
            switch key & 0x07 {
            case 0:
                guard let value = varint(bytes, &index, end) else { return out }
                out.append(Field(number: number, value: .varint(value)))
            case 1:
                guard index + 8 <= end else { return out }
                out.append(Field(number: number, value: .fixed64(littleEndian(bytes, index, 8))))
                index += 8
            case 2:
                guard let length = varint(bytes, &index, end),
                      length <= UInt64(end - index)
                else { return out }
                let stop = index + Int(length)
                out.append(Field(number: number, value: .bytes(bytes[index..<stop])))
                index = stop
            case 5:
                guard index + 4 <= end else { return out }
                out.append(Field(number: number, value: .fixed32(UInt32(littleEndian(bytes, index, 4)))))
                index += 4
            default:
                // Groups (3 / 4) were removed from proto3 and nothing we read
                // emits them; an unknown type means the cursor is no longer
                // on a key, so stop rather than guess a length.
                return out
            }
        }
        return out
    }

    /// Base-128 varint. Returns `nil` on a truncated or over-long encoding,
    /// which the callers treat as "stop reading this message".
    public static func varint(_ bytes: [UInt8], _ index: inout Int, _ end: Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < end, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func littleEndian(_ bytes: [UInt8], _ start: Int, _ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for offset in stride(from: count - 1, through: 0, by: -1) {
            value = (value << 8) | UInt64(bytes[start + offset])
        }
        return value
    }
}

extension ProtobufWireReader.Field {
    /// The length-delimited payload, or `nil` for any other wire type.
    public var bytes: ArraySlice<UInt8>? {
        guard case let .bytes(slice) = value else { return nil }
        return slice
    }

    /// The varint payload, or `nil` for any other wire type.
    public var unsigned: UInt64? {
        guard case let .varint(number) = value else { return nil }
        return number
    }

    /// The field's payload as UTF-8, or `nil` when it is not a
    /// length-delimited field or does not decode.
    public var text: String? {
        guard let bytes else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
}
