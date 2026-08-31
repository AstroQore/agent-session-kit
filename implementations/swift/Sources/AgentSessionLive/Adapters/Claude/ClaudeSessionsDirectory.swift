import Darwin
import Foundation

/// One entry of `~/.claude/sessions` — a running Claude Code process, the
/// session it is driving, and where it is driving it.
///
/// This is the authoritative pid ↔ session ↔ cwd table on the machine, and
/// the only place any of the three is written down together. Nothing in a
/// transcript records a pid, and the project directory name a transcript lives
/// under is a lossy encoding of the cwd (see ``ClaudeProjectPath``), so a
/// session with an entry here is one whose identity is *known* rather than
/// reconstructed.
///
/// Claude Code removes the entry when the process exits — cleanly or not, the
/// file goes — which is what makes presence in this directory a liveness
/// signal in its own right.
public struct ClaudeLiveSession: Hashable, Sendable, Codable {
    /// The Claude Code process.
    public let pid: pid_t
    /// The session it is driving. Matches a transcript file's stem.
    public let sessionID: String
    /// The directory it was launched in.
    public let cwd: String?
    /// When the *session* started, from the entry's millisecond epoch.
    public let startedAt: Date?
    /// When the *process* started, parsed from the entry's `procStart`.
    /// Paired with ``pid`` this is what survives pid reuse.
    public let procStart: Date?
    /// The Claude Code version.
    public let version: String?
    /// `interactive`, and whatever else a future release writes.
    public let kind: String?
    /// Where the session was started from — `claude-desktop`, `cli`, …
    public let entrypoint: String?
    /// The harness's own derived name for the session — `auspex-41`. A
    /// reasonable title until the transcript offers a better one.
    public let name: String?
    /// The `AF_UNIX` socket the desktop app talks to this process over.
    /// Its existence is supporting liveness evidence; its absence is not
    /// proof of anything, because a headless run has none.
    public let messagingSocketPath: String?

    /// Creates an entry.
    public init(
        pid: pid_t,
        sessionID: String,
        cwd: String? = nil,
        startedAt: Date? = nil,
        procStart: Date? = nil,
        version: String? = nil,
        kind: String? = nil,
        entrypoint: String? = nil,
        name: String? = nil,
        messagingSocketPath: String? = nil
    ) {
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.startedAt = startedAt
        self.procStart = procStart
        self.version = version
        self.kind = kind
        self.entrypoint = entrypoint
        self.name = name
        self.messagingSocketPath = messagingSocketPath
    }

    /// `true` when ``messagingSocketPath`` names a file that is there.
    public var hasMessagingSocket: Bool {
        guard let messagingSocketPath else { return false }
        return FileManager.default.fileExists(atPath: messagingSocketPath)
    }
}

/// Reads `~/.claude/sessions`.
///
/// The directory holds a `<pid>.json` per running process and a
/// `<pid>.<hex>.key` beside it. Only the JSON is read: the key file is a
/// credential for the messaging socket and this package has no business
/// opening it, which the `pathExtension == "json"` filter enforces by
/// construction rather than by remembering to skip it.
public enum ClaudeSessionsDirectory {
    /// `<home>/.claude/sessions`.
    public static func directoryURL(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".claude/sessions")
    }

    /// Every readable entry, in no particular order.
    ///
    /// Never throws. A directory that does not exist yields `[]` — Claude Code
    /// may simply not be installed — and an entry that is mid-write, truncated,
    /// or missing its `pid` or `sessionId` is skipped rather than failing the
    /// read: this is a live directory, and a partially written file in it is
    /// normal.
    public static func read(home: String) -> [ClaudeLiveSession] {
        let directory = directoryURL(home: home)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            guard (name as NSString).pathExtension == "json" else { return nil }
            return entry(at: directory.appendingPathComponent(name))
        }
    }

    /// The entry naming `sessionID`, when a process is driving it.
    ///
    /// When two entries name the same session — which happens for the moments
    /// around a `--resume`, where the exiting process has not yet removed its
    /// file — the one with the later ``ClaudeLiveSession/procStart`` wins,
    /// because that is the process still running.
    public static func session(for sessionID: String, in entries: [ClaudeLiveSession]) -> ClaudeLiveSession? {
        entries
            .filter { $0.sessionID == sessionID }
            .max { ($0.procStart ?? .distantPast) < ($1.procStart ?? .distantPast) }
    }

    /// Parses one `<pid>.json`.
    static func entry(at url: URL) -> ClaudeLiveSession? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = ClaudeJSON.int(object["pid"]),
              let sessionID = ClaudeJSON.string(object["sessionId"])
        else { return nil }

        return ClaudeLiveSession(
            pid: pid_t(pid),
            sessionID: sessionID,
            cwd: ClaudeJSON.string(object["cwd"]),
            startedAt: ClaudeJSON.int(object["startedAt"]).map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000)
            },
            procStart: procStart(ClaudeJSON.string(object["procStart"])),
            version: ClaudeJSON.string(object["version"]),
            kind: ClaudeJSON.string(object["kind"]),
            entrypoint: ClaudeJSON.string(object["entrypoint"]),
            name: ClaudeJSON.string(object["name"]),
            messagingSocketPath: ClaudeJSON.string(object["messagingSocketPath"])
        )
    }

    /// Parses `procStart`, which Claude Code writes as C `ctime(3)` text —
    /// `"Tue Aug 18 20:38:36 2026"`.
    ///
    /// **In UTC, not in local time**, which is the one thing about this field
    /// worth writing down. `ps -o lstart` renders the same instant in the
    /// machine's own zone, so on a `UTC+8` machine the two strings differ by
    /// eight hours for the same process. Parsing this as local time is not a
    /// cosmetic error: the start time is compared against the process table's
    /// with a two-second tolerance to detect pid reuse, and a whole-hour offset
    /// makes every live session look like a recycled pid — every row on a
    /// board goes dead at once.
    ///
    /// The pairing was checked against `startedAt`, which is an unambiguous
    /// millisecond epoch written one second after `procStart` by the same
    /// process, and against `ps` for the same pid.
    public static func procStart(_ text: String?) -> Date? {
        guard let text else { return nil }
        // `ctime(3)` pads a single-digit day with a second space — `"Tue Aug
        // 8 20:38:36 2026"` is really `"Tue Aug  8 …"` — and a `DateFormatter`
        // pattern with one literal space does not reliably absorb the extra
        // one. Collapsing first makes both widths parse.
        return ctimeFormatter.date(from: EventText.collapseWhitespace(text))
    }

    // `DateFormatter` is `Sendable` and is never mutated after this closure
    // returns, so one shared instance is both safe and considerably cheaper
    // than building a formatter per entry.
    private static let ctimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        // `d` rather than `dd`: `ctime(3)` pads a single-digit day with a
        // space, and a lenient day field accepts both that and the two-digit
        // form. The extra space is absorbed by the literal in the pattern.
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()
}
