import AgentSessionKit
import Foundation

/// The conversation card Cursor keeps in `store.db`'s `meta` table.
///
/// Row `'0'`'s `value` is **hex-encoded** JSON — not base64, not a blob — and
/// decodes to `{agentId, latestRootBlobId, name, mode, isRunEverything,
/// createdAt, …}`. The key is read rather than assumed, exactly as
/// `AgentSessionKit`'s `CursorSessionAdapter` does, so a store whose card
/// moved to another key still resolves.
///
/// ``latestRootBlobID`` is the whole of the incremental story: it changes
/// once per turn and names the head of the content-addressed graph, so a
/// tailer that finds it unchanged knows there is nothing to walk without
/// touching a single blob.
public struct CursorStoreMeta: Hashable, Sendable {
    /// The agent id, which is also the name of the directory the store is in.
    public let agentID: String
    /// The head of the blob graph. `nil` for a conversation with no turns yet.
    public let latestRootBlobID: String?
    /// The conversation's name, as Cursor derived or a person set it.
    public let name: String?
    /// The agent mode — Cursor's own flavour string, kept in
    /// ``SessionIdentity/variant``.
    public let mode: String?
    /// When the conversation was created, when the card recorded it.
    public let createdAt: Date?

    /// Creates a card.
    public init(
        agentID: String,
        latestRootBlobID: String? = nil,
        name: String? = nil,
        mode: String? = nil,
        createdAt: Date? = nil
    ) {
        self.agentID = agentID
        self.latestRootBlobID = latestRootBlobID
        self.name = name
        self.mode = mode
        self.createdAt = createdAt
    }

    /// Parses one decoded `meta` value.
    public static func decode(json object: [String: Any]) -> CursorStoreMeta? {
        guard let agentID = SessionParsing.string(object["agentId"]) else { return nil }
        return CursorStoreMeta(
            agentID: agentID,
            latestRootBlobID: SessionParsing.string(object["latestRootBlobId"]),
            name: SessionParsing.string(object["name"]),
            mode: SessionParsing.string(object["mode"]),
            createdAt: SessionParsing.date(object["createdAt"])
        )
    }

    /// Titles Cursor invents for a conversation nobody named.
    ///
    /// A board that shows six rows all called "New Agent" has told a person
    /// nothing, so a generic name is treated as no name at all and the
    /// identity keeps `title` at `nil` rather than filling it with noise.
    public static let genericNames: Set<String> = ["new agent", "new chat", "untitled", "untitled agent"]

    /// The card's name, or `nil` when it is one Cursor made up.
    public var displayTitle: String? {
        guard let name, !name.isEmpty else { return nil }
        guard !Self.genericNames.contains(name.lowercased()) else { return nil }
        return name
    }
}

/// The `meta.json` sidecar written next to `store.db`.
///
/// `{schemaVersion, createdAtMs, updatedAtMs, hasConversation, cwd}`. Two
/// facts here are not in the store at all: `cwd` — which is what joins an
/// agent to its thin transcript — and `updatedAtMs`, which is a cheap
/// discovery cutoff that costs one small read rather than an open of somebody
/// else's live database.
public struct CursorAgentMeta: Hashable, Sendable {
    /// The store schema Cursor wrote, when it recorded one.
    public let schemaVersion: Int?
    /// When the agent directory was created.
    public let createdAt: Date?
    /// When Cursor last wrote to the agent. The discovery cutoff's first
    /// choice, because reading it does not open the database.
    public let updatedAt: Date?
    /// Whether the store has any conversation in it yet.
    public let hasConversation: Bool
    /// The working directory the agent runs in, verbatim.
    public let cwd: String?

    /// Creates a sidecar record.
    public init(
        schemaVersion: Int? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        hasConversation: Bool = false,
        cwd: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.hasConversation = hasConversation
        self.cwd = cwd
    }

    /// Reads and parses one `meta.json`, or `nil` when it is missing or is
    /// not an object.
    ///
    /// Bounded: the file is a handful of fields, and anything past
    /// ``maxBytes`` is not the sidecar and is not read into memory.
    public static func read(path: String) -> CursorAgentMeta? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return CursorAgentMeta(
            schemaVersion: SessionParsing.int(object["schemaVersion"]),
            createdAt: SessionParsing.date(object["createdAtMs"] ?? object["createdAt"]),
            updatedAt: SessionParsing.date(object["updatedAtMs"] ?? object["updatedAt"]),
            hasConversation: SessionParsing.bool(object["hasConversation"]),
            cwd: SessionParsing.string(object["cwd"])
        )
    }

    /// Upper bound on a `meta.json` read. The real file is a few hundred
    /// bytes; this is generous by three orders of magnitude and still bounded.
    public static let maxBytes = 64 * 1024
}

/// Hex, the way Cursor's `meta` values and blob ids are written.
///
/// Two directions and nothing else: the `meta` value is hex-encoded JSON, and
/// a blob reference on the wire is 32 raw bytes whose hex is the `blobs.id`
/// it names.
enum CursorHex {
    /// Lowercase or uppercase hex to bytes. Anything that is not an even run
    /// of hex digits is not hex and yields `nil`.
    static func decode(_ hex: String) -> Data? {
        let scalars = Array(hex.utf8)
        guard !scalars.isEmpty, scalars.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: scalars.count / 2)
        var index = 0
        while index < scalars.count {
            guard let high = nibble(scalars[index]), let low = nibble(scalars[index + 1]) else {
                return nil
            }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    /// Bytes to lowercase hex.
    static func encode(_ bytes: some Sequence<UInt8>) -> String {
        var out = ""
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }

    private static let digits = Array("0123456789abcdef")

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30           // 0-9
        case 0x61...0x66: return byte - 0x61 + 10      // a-f
        case 0x41...0x46: return byte - 0x41 + 10      // A-F
        default: return nil
        }
    }
}
