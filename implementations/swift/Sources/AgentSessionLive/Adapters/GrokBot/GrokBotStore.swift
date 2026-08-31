import AgentSessionKit
import Foundation

/// Grok Bot's client cache, as the live layer has to see it.
///
/// ## Two directories, and one of them is off limits
///
/// ```text
/// ~/Library/Application Support/Grok Bot/sand-client-persistence/
///     <base32(key)>.blob        every slice the client persists
/// ~/.grokbot/
///     local-exec-supervisor.json      {pid, at} — rewritten every few seconds
///     local-exec-daemon-connection.json   NEVER READ: it carries a token
/// ```
///
/// The blob names are the lowercase, unpadded RFC 4648 base32 of the key they
/// hold, so `Base32` and `GrokBotSessionAdapter`'s key parsers are what decide
/// whether a file is one of ours — this type does not spell any of that a
/// second time. Two keys matter: `…transcript.replicas.<bot uuid>` is a
/// conversation, and `…roster.last-roster` is the bot list that names it.
///
/// ## A snapshot, never an append
///
/// A replica file is *rewritten whole* on every change: entries are added at
/// the end, and an entry already in the file is edited in place while its
/// reply streams. There is no offset to resume from and no line to read past,
/// which is why ``GrokBotTranscriptTailer`` diffs rather than walks.
///
/// ## What the client does not record
///
/// No tool calls, no model, no token counts, and no working directory — the
/// run happened on xAI's servers and this directory is only what the client
/// replicated. An adapter that invented any of them would be wrong in a way
/// nothing downstream could detect.
public enum GrokBotStore {
    // MARK: - Paths

    /// `~/Library/Application Support/Grok Bot/sand-client-persistence`.
    public static func root(home: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(GrokBotSessionAdapter.storeRelativePath, isDirectory: true)
    }

    /// The local executor's directory, `~/.grokbot`.
    ///
    /// Watched and stat'd, never enumerated: it holds
    /// `local-exec-daemon-connection.json` and
    /// `local-exec-daemon-credential.json`, both of which carry live
    /// credentials. ``supervisorPath(home:)`` is the only file in it this
    /// package opens.
    public static let daemonDirectory = ".grokbot"

    /// The supervisor's heartbeat file: `{"pid": …, "at": …}`, rewritten
    /// every few seconds while the client's local executor is up.
    public static let supervisorFileName = "local-exec-supervisor.json"

    /// `~/.grokbot`.
    public static func daemonRoot(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(daemonDirectory, isDirectory: true)
    }

    /// `~/.grokbot/local-exec-supervisor.json`.
    public static func supervisorPath(home: String) -> String {
        daemonRoot(home: home).appendingPathComponent(supervisorFileName).path
    }

    /// Whether a path is a blob inside a `sand-client-persistence` directory.
    ///
    /// By name only, and deliberately so: this answers "could a change here
    /// be a conversation" for a file nothing is tailing yet, and it runs on
    /// every path in every filesystem notification.
    public static func isBlob(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == GrokBotSessionAdapter.blobExtension else { return false }
        return url.deletingLastPathComponent().lastPathComponent == storeDirectoryName
    }

    /// The last component of ``root(home:)``.
    static let storeDirectoryName = "sand-client-persistence"

    /// The largest blob this package will read.
    ///
    /// Far above what the client writes — the biggest transcript measured was
    /// ~130 KB — and it exists so that a junk file dropped into the directory
    /// costs a `stat` rather than a heap.
    public static let maxBlobBytes: Int64 = 32 * 1024 * 1024

    // MARK: - Replicas

    /// One transcript replica, parsed.
    public struct Replica: Hashable, Sendable {
        /// The conversation, in the order the client wrote it.
        ///
        /// File order rather than timestamp order: a few conversations have
        /// entries whose `timestampMs` runs backwards, and the array is the
        /// client's own idea of what happened.
        public let entries: [GrokBotEntry]
        /// When the client last wrote the file, by its own clock.
        public let persistedAt: Date?
    }

    /// Reads a replica blob, or `nil` when it is missing, oversized, not
    /// JSON, or not a replica at all.
    ///
    /// Total, like every parser in this package: a single unreadable entry is
    /// dropped rather than sinking the conversation around it.
    public static func replica(at path: String) -> Replica? {
        let url = URL(fileURLWithPath: path)
        guard SessionParsing.fileSize(url) <= maxBlobBytes,
              let object = SessionParsing.jsonObject(at: url),
              let value = object["value"] as? [String: Any],
              let raw = value["entries"] as? [[String: Any]]
        else { return nil }
        return Replica(
            entries: raw.compactMap(GrokBotEntry.init(json:)),
            persistedAt: SessionParsing.date(value["persistedAt"])
        )
    }

    // MARK: - Roster

    /// The roster rows for one account, and the file they came from.
    ///
    /// Read through `GrokBotSessionAdapter` rather than re-parsed here: the
    /// roster is the only place a conversation's name and its
    /// `awaitingUserResponse` flag exist, and two readers of one file
    /// eventually disagree.
    public static func roster(
        accountID: String,
        in directory: URL
    ) -> (url: URL, rows: [String: GrokBotSessionAdapter.RosterRow])? {
        guard let url = GrokBotSessionAdapter.rosterURL(forAccount: accountID, in: directory) else {
            return nil
        }
        return (url, GrokBotSessionAdapter.rosterRows(at: url))
    }

    // MARK: - Liveness

    /// What the local executor's supervisor last wrote about itself.
    public struct Heartbeat: Hashable, Sendable {
        /// The supervisor's process id.
        public let pid: pid_t
        /// When it last wrote the file, by its own clock.
        public let at: Date
    }

    /// Reads `~/.grokbot/local-exec-supervisor.json`.
    ///
    /// The one file in that directory this package opens. Its siblings hold a
    /// daemon token and a credential, and nothing here has any reason to know
    /// what is in them.
    public static func heartbeat(home: String) -> Heartbeat? {
        let url = URL(fileURLWithPath: supervisorPath(home: home))
        guard let object = SessionParsing.jsonObject(at: url),
              let pid = SessionParsing.int(object["pid"]), pid > 0,
              let at = SessionParsing.date(object["at"])
        else { return nil }
        return Heartbeat(pid: pid_t(pid), at: at)
    }
}
