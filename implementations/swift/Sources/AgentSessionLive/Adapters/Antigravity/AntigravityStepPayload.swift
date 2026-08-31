import AgentSessionKit
import Foundation

/// What a `steps.step_payload` blob gives up on a shallow, tolerant read.
///
/// The blob is an undocumented protobuf message and the only fixed points are
/// the ones the descriptors in the `agy` binary name (2026-08-19):
///
/// ```text
/// 1  step_type            (mirrors the steps.step_type column)
/// 4  status               (mirrors the steps.status column)
/// 5  StepMetadata
///    5.1  started    { 1: seconds, 2: nanos }
///    5.3  CORTEX_STEP_SOURCE_*
///    5.4  ToolCall   { 1: call_id, 2: tool_name, 3: args_json }
///    5.9  usage      { 1: prompt tokens, 11: request id }
///    5.11 prompt tokens
///    5.20 trajectory { 1: trajectory id, 2: sequence, 4: cascade id }
///    5.26 repeated   { 1: { 1: status, 2: { 1: seconds, 2: nanos } } }
///    5.32 ended      { 1: seconds, 2: nanos }
/// <n>   one type-specific submessage, `n` chosen by the step type
///       (14 → 19, 15 → 20, 17 → 24, 23 → 30, 33 → 42, 98 → 111, 132 → 140)
/// ```
///
/// Everything below that is guesswork, so nothing below that is decoded.
/// ``textPreview`` is the one exception and it is deliberately conservative:
/// it takes the shallowest string in the type-specific submessage that reads
/// like prose and leaves the rest alone. A payload that yields nothing is a
/// normal payload, not a parse failure.
///
/// Decoding never throws. A truncated or hostile blob yields whatever was
/// readable before the wire walk lost the thread, which is the same contract
/// `AgentSessionKit`'s parsers keep.
public struct AntigravityStepPayload: Hashable, Sendable {
    /// One `ToolCall` submessage — `5.4`, and the same shape at `20.7` inside
    /// a planner response.
    public struct ToolCall: Hashable, Sendable {
        /// AntiGravity's own id for the call. Short (`"tooluse_1"`-shaped),
        /// and unique only within a conversation.
        public let callID: String?
        /// The tool's real name, e.g. `search_web`. Matches
        /// ``AntigravityStepType/label`` for every tool observed.
        public let name: String?
        /// The call's arguments, as the JSON string AntiGravity stored.
        public let argsJSON: String?

        /// Creates a tool call.
        public init(callID: String?, name: String?, argsJSON: String?) {
            self.callID = callID
            self.name = name
            self.argsJSON = argsJSON
        }

        /// `true` when nothing at all was decoded.
        public var isEmpty: Bool { callID == nil && name == nil && argsJSON == nil }
    }

    /// One entry of the `5.26` status log: a status the row passed through and
    /// when it did.
    public struct Transition: Hashable, Sendable {
        /// The status the row moved to.
        public let status: AntigravityStepStatus?
        /// When it moved, when the entry carried a timestamp.
        public let at: Date?

        /// Creates a transition.
        public init(status: AntigravityStepStatus?, at: Date?) {
            self.status = status
            self.at = at
        }
    }

    /// `step_payload.1`, which mirrors the `step_type` column.
    public let stepType: AntigravityStepType?
    /// `step_payload.4`, which mirrors the `status` column.
    public let status: AntigravityStepStatus?
    /// `5.1`, the moment the step opened.
    public let startedAt: Date?
    /// `5.32`, the moment it closed.
    public let endedAt: Date?
    /// `5.3`, who caused the step.
    public let source: AntigravityStepSource?
    /// `5.4`, present on tool rows.
    public let toolCall: ToolCall?
    /// `5.26`, in the order the payload stored them.
    public let transitions: [Transition]
    /// `5.9.1`, falling back to `5.11`. Prompt tokens only — the payload
    /// records no completion count anywhere this decoder trusts.
    public let promptTokens: Int?
    /// `5.9.11`, the model request behind the step.
    public let requestID: String?
    /// `5.20.1`, the trajectory these rows belong to.
    public let trajectoryID: String?
    /// `5.20.4`.
    public let cascadeID: String?
    /// The shallowest prose-shaped string in the type-specific submessage, or
    /// `nil` when nothing in it read as text. Never a guess — see
    /// ``AntigravityStepText/readsAsText(_:)``.
    public let textPreview: String?

    /// Creates a payload. Every field is optional because every field is
    /// genuinely absent on some real row.
    public init(
        stepType: AntigravityStepType? = nil,
        status: AntigravityStepStatus? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        source: AntigravityStepSource? = nil,
        toolCall: ToolCall? = nil,
        transitions: [Transition] = [],
        promptTokens: Int? = nil,
        requestID: String? = nil,
        trajectoryID: String? = nil,
        cascadeID: String? = nil,
        textPreview: String? = nil
    ) {
        self.stepType = stepType
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.toolCall = toolCall
        self.transitions = transitions
        self.promptTokens = promptTokens
        self.requestID = requestID
        self.trajectoryID = trajectoryID
        self.cascadeID = cascadeID
        self.textPreview = textPreview
    }

    /// The last status the `5.26` log recorded, which on a live row is ahead
    /// of what the column says often enough to be worth asking for.
    public var latestTransition: Transition? { transitions.last }

    // MARK: - Field numbers

    /// Top-level and `StepMetadata` field numbers, named so the walk below
    /// reads as the layout it is decoding.
    enum Field {
        static let stepType = 1
        static let status = 4
        static let metadata = 5

        static let started = 1
        static let source = 3
        static let toolCall = 4
        static let usage = 9
        static let promptTokens = 11
        static let trajectory = 20
        static let transitions = 26
        static let ended = 32

        static let toolCallID = 1
        static let toolName = 2
        static let toolArgs = 3

        static let usagePromptTokens = 1
        static let usageRequestID = 11

        static let trajectoryID = 1
        static let cascadeID = 4

        static let transitionEntry = 1
        static let transitionStatus = 1
        static let transitionAt = 2

        static let timestampSeconds = 1
        static let timestampNanos = 2
    }

    /// The type-specific submessage each step type parks its content in.
    ///
    /// Only the pairings observed on a real corpus are listed. An unlisted
    /// type falls back to "the first length-delimited field that is neither
    /// `1`, `4`, nor `5`", which is what the layout implies and what every
    /// observed row obeys.
    static let typeSpecificField: [AntigravityStepType: Int] = [
        .userInput: 19,
        .plannerResponse: 20,
        .errorMessage: 24,
        .checkpoint: 30,
        .searchWeb: 42,
        .conversationHistory: 111,
        .generic: 140
    ]

    // MARK: - Decoding

    /// Decodes a `step_payload` blob. Returns `nil` only for a blob with no
    /// readable fields at all.
    public static func decode(_ blob: Data) -> AntigravityStepPayload? {
        let bytes = [UInt8](blob)
        let top = ProtobufWireReader.fields(in: bytes)
        guard !top.isEmpty else { return nil }

        var stepType: AntigravityStepType?
        var status: AntigravityStepStatus?
        var metadata: ArraySlice<UInt8>?
        var candidates: [Int: ArraySlice<UInt8>] = [:]

        for field in top {
            switch field.number {
            case Field.stepType:
                if let raw = field.unsigned { stepType = AntigravityStepType(rawValue: Int(raw)) }
            case Field.status:
                if let raw = field.unsigned { status = AntigravityStepStatus(rawValue: Int(raw)) }
            case Field.metadata:
                metadata = field.bytes ?? metadata
            default:
                if let bytes = field.bytes, candidates[field.number] == nil {
                    candidates[field.number] = bytes
                }
            }
        }

        let meta = metadata.map { decodeMetadata(bytes, $0) } ?? Metadata()
        let payloadSlice = typeSpecific(stepType, in: candidates)

        return AntigravityStepPayload(
            stepType: stepType,
            status: status,
            startedAt: meta.startedAt,
            endedAt: meta.endedAt,
            source: meta.source,
            toolCall: meta.toolCall,
            transitions: meta.transitions,
            promptTokens: meta.promptTokens,
            requestID: meta.requestID,
            trajectoryID: meta.trajectoryID,
            cascadeID: meta.cascadeID,
            textPreview: payloadSlice.flatMap { AntigravityStepText.shallowText(bytes, in: $0) }
        )
    }

    /// The type-specific submessage for a step type: the field the layout
    /// names, or the lowest-numbered candidate when the type is unknown.
    private static func typeSpecific(
        _ stepType: AntigravityStepType?,
        in candidates: [Int: ArraySlice<UInt8>]
    ) -> ArraySlice<UInt8>? {
        if let stepType, let field = typeSpecificField[stepType], let slice = candidates[field] {
            return slice
        }
        guard let lowest = candidates.keys.min() else { return nil }
        return candidates[lowest]
    }

    private struct Metadata {
        var startedAt: Date?
        var endedAt: Date?
        var source: AntigravityStepSource?
        var toolCall: ToolCall?
        var transitions: [Transition] = []
        var promptTokens: Int?
        var requestID: String?
        var trajectoryID: String?
        var cascadeID: String?
    }

    private static func decodeMetadata(_ bytes: [UInt8], _ range: ArraySlice<UInt8>) -> Metadata {
        var out = Metadata()
        for field in ProtobufWireReader.fields(in: bytes, range: range.indices) {
            switch field.number {
            case Field.started:
                out.startedAt = field.bytes.flatMap { timestamp(bytes, $0) }
            case Field.ended:
                out.endedAt = field.bytes.flatMap { timestamp(bytes, $0) }
            case Field.source:
                if let raw = field.unsigned {
                    out.source = AntigravityStepSource(rawValue: Int(raw))
                }
            case Field.toolCall:
                if let slice = field.bytes {
                    let call = decodeToolCall(bytes, slice)
                    if !call.isEmpty { out.toolCall = call }
                }
            case Field.usage:
                guard let slice = field.bytes else { break }
                for usage in ProtobufWireReader.fields(in: bytes, range: slice.indices) {
                    switch usage.number {
                    case Field.usagePromptTokens:
                        if out.promptTokens == nil, let raw = usage.unsigned {
                            out.promptTokens = Int(clamping: raw)
                        }
                    case Field.usageRequestID:
                        out.requestID = out.requestID ?? usage.text
                    default:
                        break
                    }
                }
            case Field.promptTokens:
                if out.promptTokens == nil, let raw = field.unsigned {
                    out.promptTokens = Int(clamping: raw)
                }
            case Field.trajectory:
                guard let slice = field.bytes else { break }
                for entry in ProtobufWireReader.fields(in: bytes, range: slice.indices) {
                    switch entry.number {
                    case Field.trajectoryID: out.trajectoryID = out.trajectoryID ?? entry.text
                    case Field.cascadeID: out.cascadeID = out.cascadeID ?? entry.text
                    default: break
                    }
                }
            case Field.transitions:
                if let slice = field.bytes, let transition = decodeTransition(bytes, slice) {
                    out.transitions.append(transition)
                }
            default:
                break
            }
        }
        return out
    }

    private static func decodeToolCall(_ bytes: [UInt8], _ range: ArraySlice<UInt8>) -> ToolCall {
        var callID: String?
        var name: String?
        var args: String?
        for field in ProtobufWireReader.fields(in: bytes, range: range.indices) {
            switch field.number {
            case Field.toolCallID: callID = callID ?? field.text
            case Field.toolName: name = name ?? field.text
            case Field.toolArgs: args = args ?? field.text
            default: break
            }
        }
        return ToolCall(callID: callID, name: name, argsJSON: args)
    }

    /// `5.26` is a repeated wrapper whose single field `1` holds the entry.
    private static func decodeTransition(
        _ bytes: [UInt8],
        _ range: ArraySlice<UInt8>
    ) -> Transition? {
        for wrapper in ProtobufWireReader.fields(in: bytes, range: range.indices)
        where wrapper.number == Field.transitionEntry {
            guard let slice = wrapper.bytes else { continue }
            var status: AntigravityStepStatus?
            var at: Date?
            for entry in ProtobufWireReader.fields(in: bytes, range: slice.indices) {
                switch entry.number {
                case Field.transitionStatus:
                    if let raw = entry.unsigned {
                        status = AntigravityStepStatus(rawValue: Int(raw))
                    }
                case Field.transitionAt:
                    at = entry.bytes.flatMap { timestamp(bytes, $0) }
                default:
                    break
                }
            }
            guard status != nil || at != nil else { continue }
            return Transition(status: status, at: at)
        }
        return nil
    }

    /// A `google.protobuf.Timestamp`: seconds at `1`, nanos at `2`.
    ///
    /// Rejects the zero value AntiGravity writes for "never" and anything
    /// past the year 9999, so a corrupt varint cannot produce a row dated a
    /// hundred million years from now.
    static func timestamp(_ bytes: [UInt8], _ range: ArraySlice<UInt8>) -> Date? {
        var seconds: UInt64?
        var nanos: UInt64 = 0
        for field in ProtobufWireReader.fields(in: bytes, range: range.indices) {
            switch field.number {
            case Field.timestampSeconds: seconds = field.unsigned
            case Field.timestampNanos: nanos = field.unsigned ?? 0
            default: break
            }
        }
        guard let seconds, seconds > 0, seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }
}

/// The one heuristic in the AntiGravity payload decoder: does this string look
/// like something a person or a model said?
///
/// The schema names no field "text", so a decoder that took the first string
/// it found would put a 40-character request id where a prompt belongs. The
/// filter is deliberately blunt and deliberately conservative — when in doubt,
/// no preview, because a wrong preview on a board is worse than an empty one.
public enum AntigravityStepText {
    /// Shorter runs are field names (`toolSummary`, `sessionID`) far more
    /// often than they are content.
    static let minimumLength = 8
    /// CJK carries far more per character and never appears in this schema's
    /// own identifiers, so those runs get a lower floor.
    static let minimumCJKLength = 4
    /// How far into the type-specific submessage the search descends. One
    /// level covers every shape observed; two is slack for a wrapper.
    static let maximumDepth = 2

    /// The shallowest prose-shaped string in `range`, searched breadth-first
    /// so a wrapper never outranks the field it wraps.
    static func shallowText(_ bytes: [UInt8], in range: ArraySlice<UInt8>) -> String? {
        var frontier: [ArraySlice<UInt8>] = [range]
        var depth = 0
        while !frontier.isEmpty, depth <= maximumDepth {
            var next: [ArraySlice<UInt8>] = []
            for slice in frontier {
                for field in ProtobufWireReader.fields(in: bytes, range: slice.indices) {
                    guard let payload = field.bytes else { continue }
                    if let text = field.text, readsAsText(text) { return text }
                    if payload.count > 2 { next.append(payload) }
                }
            }
            frontier = next
            depth += 1
        }
        return nil
    }

    /// `true` for a run that reads as prose rather than as an identifier.
    ///
    /// In order: long enough to be content; under 5% control bytes; not a
    /// bare UUID, path, or base64/hex-shaped token; and — for anything
    /// without CJK, which has no word spacing — at least two whitespace-
    /// separated words with letters making up half the characters.
    public static func readsAsText(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minimumCJKLength else { return false }

        var controls = 0
        var letters = 0
        var hasCJK = false
        for character in text {
            if let scalar = character.unicodeScalars.first, scalar.value < 0x20,
               scalar != "\n", scalar != "\t", scalar != "\r" {
                controls += 1
            }
            if character.isLetter { letters += 1 }
            if !hasCJK, isCJK(character) { hasCJK = true }
        }
        guard text.count >= (hasCJK ? minimumCJKLength : minimumLength) else { return false }
        guard controls * 20 <= text.count else { return false }
        guard !isUUIDShaped(text), !isBarePath(text), !isTokenShaped(text) else { return false }
        if hasCJK { return true }

        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return false }
        return letters * 2 >= text.count
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func isUUIDShaped(_ text: String) -> Bool {
        guard text.count == 36 else { return false }
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return text.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    private static func isBarePath(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        return text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("file://")
    }

    private static func isTokenShaped(_ text: String) -> Bool {
        guard text.count >= 16, !text.contains(where: \.isWhitespace) else { return false }
        return text.unicodeScalars.allSatisfy(tokenCharacters.contains)
    }

    private static let tokenCharacters = CharacterSet(charactersIn:
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+/=_-.")
}
