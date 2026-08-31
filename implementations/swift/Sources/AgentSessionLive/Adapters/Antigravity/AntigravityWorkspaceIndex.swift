import AgentSessionKit
import Foundation

/// Where an AntiGravity conversation was working, for the conversations
/// `conversation_summaries.db` cannot answer for.
///
/// `workspace_uris` is the right answer whenever the summaries store has one,
/// and on the corpus this was built against it had one for a fraction of the
/// conversations on disk: its rows go stale, and a conversation the CLI opened
/// non-interactively never reaches it at all. A board that stops there files
/// most of a day's AntiGravity work under no project.
///
/// Two side files close the gap, both written by the CLI itself, both read
/// bounded and cached against their own mtimes:
///
/// 1. `history.jsonl` — one `{display, timestamp, workspace, conversationId}`
///    object per prompt a person submitted. Exact, and only ever present for
///    a prompt someone typed.
/// 2. `log/cli-<stamp>.log` — the CLI server's own log. Its startup banner
///    names the directories the server was launched over (`workspaceDirs=[…]`)
///    and every conversation that run created, opened, or streamed is named
///    further down. One server, one workspace, so a conversation named in a
///    log belongs to that log's workspace.
///
/// The conversation database itself is not a third source. It records a
/// trajectory, a cascade, and a project label (`default-cli-project`), and
/// nowhere in it is the directory the CLI was launched in.
enum AntigravityWorkspaceIndex {
    /// The CLI's log directory, relative to a root.
    static let logDirectoryName = "log"
    /// The CLI's prompt history, relative to a root.
    static let historyFileName = "history.jsonl"

    static let logNamePrefix = "cli-"
    static let logNameExtension = "log"

    /// Logs whose contents are scanned, most recently written first. Several
    /// `agy` servers run at once and each keeps its own log, so the newest
    /// file alone is not the whole picture.
    static let logsScanned = 8
    /// Logs stat'd to find those. Bounded so a machine with a year of runs
    /// does not pay for all of them; the names sort by start time, so the
    /// window is the most recently *started* runs.
    static let logsConsidered = 64
    /// A log at or below this size is walked whole, which every one on a real
    /// machine is — a day of `agy` writes tens of kilobytes. Past it the walk
    /// falls back to a head and a tail, because a log that big is a runaway
    /// and the two ends are where the answers are.
    static let wholeLogThreshold: Int64 = 512 * 1024
    /// Lines read from the head of an oversized log: the startup banner, and
    /// the conversations the run opened as it came up.
    static let logHeadLines = 200
    /// Lines read from its end, where a conversation that is live right now
    /// was last named. ``JSONLHeadTail`` caps that window at 16 KiB whatever
    /// this says.
    static let logTailLines = 400
    /// Conversations one log will attribute. A bound, not an expectation.
    static let maxConversationIDs = 4_096
    /// Prompt-history lines read, from the end — the newest prompts are the
    /// ones a live board is asking about.
    static let historyLines = 512

    /// The banner key. Everything up to the closing bracket is the launch
    /// directory list.
    static let workspaceDirsKey = "workspaceDirs=["

    // MARK: - Paths

    /// `<root>/log`.
    static func logDirectory(home: String, root: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(root, isDirectory: true)
            .appendingPathComponent(logDirectoryName, isDirectory: true)
    }

    /// `<root>/history.jsonl`.
    static func historyPath(home: String, root: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(root, isDirectory: true)
            .appendingPathComponent(historyFileName)
    }

    /// The `cli-<stamp>.log` files worth reading, oldest written first so a
    /// merge in order leaves the newest run's answer on top.
    ///
    /// Symlinks are skipped by ``DiscoveryIO/children(of:options:sorted:)`` —
    /// which is also what keeps the `cli.log` link in the root out of this,
    /// since it is the same bytes as one of these files under another name.
    static func recentLogs(in directory: URL) -> [URL] {
        let candidates = DiscoveryIO.children(of: directory, options: [.skipsHiddenFiles])
            .filter {
                $0.lastPathComponent.hasPrefix(logNamePrefix)
                    && $0.pathExtension == logNameExtension
            }
            .suffix(logsConsidered)
        let stamped = candidates.compactMap { url -> (url: URL, modified: Date)? in
            guard let stamp = FileStamp.read(path: url.path) else { return nil }
            return (url, stamp.modified)
        }
        return stamped
            .sorted { $0.modified < $1.modified }
            .suffix(logsScanned)
            .map(\.url)
    }

    // MARK: - history.jsonl

    /// `conversationId → workspace`, from the prompt history.
    static func historyWorkspaces(at url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for line in JSONLHeadTail.tailLines(url: url, count: historyLines) {
            guard let object = SessionParsing.json(line),
                  let id = SessionParsing.string(object["conversationId"])?.lowercased(),
                  let workspace = SessionParsing.string(object["workspace"])
            else { continue }
            out[id] = workspace
        }
        return out
    }

    // MARK: - cli-<stamp>.log

    /// `conversationId → workspace` for one CLI log.
    ///
    /// A log with no banner answers nothing: without the workspace there is
    /// no fact to attribute, and the ids on their own are already known.
    static func logWorkspaces(at url: URL) -> [String: String] {
        var workspace: String?
        var ids: [String] = []
        func take(_ line: Data) {
            if workspace == nil { workspace = workspaceDirectory(in: line) }
            guard ids.count < maxConversationIDs else { return }
            ids.append(contentsOf: conversationIDs(in: line))
        }

        let size = JSONLHeadTail.fileSize(url)
        guard size > 0 else { return [:] }
        if size <= wholeLogThreshold {
            _ = JSONLLineScanner.forEachLine(in: url, take)
        } else {
            // The banner is at the top, so the head has to come first.
            for line in JSONLHeadTail.headLines(url: url, count: logHeadLines) { take(line) }
            for line in JSONLHeadTail.tailLines(url: url, count: logTailLines) { take(line) }
        }

        guard let workspace else { return [:] }
        return Dictionary(ids.map { ($0, workspace) }, uniquingKeysWith: { first, _ in first })
    }

    /// The first directory in a `workspaceDirs=[…]` banner.
    ///
    /// Go prints a `[]string` with its entries separated by a space, and a
    /// directory name may contain one too — so a space that opens another
    /// absolute path is the separator and any other space is part of the
    /// name. `[/a b/c]` is one directory; `[/a /b]` is two, and the first
    /// wins, because that is the one the CLI reports as its workspace.
    static func workspaceDirectory(in line: Data) -> String? {
        guard let text = String(data: line, encoding: .utf8),
              let key = text.range(of: workspaceDirsKey),
              let close = text[key.upperBound...].firstIndex(of: "]")
        else { return nil }
        let inside = String(text[key.upperBound..<close])
        guard inside.hasPrefix("/") else { return nil }
        guard let separator = inside.range(of: " /") else { return inside }
        return String(inside[inside.startIndex..<separator.lowerBound])
    }

    /// Every UUID-shaped token on a log line.
    ///
    /// Not filtered by what the line says. `Created conversation <id>` is the
    /// obvious one, but the same conversation also appears as `Streaming
    /// conversation <id>`, `Starting conversation update stream for <id>`,
    /// and `Stream goroutine exited for <id>` — and on this corpus the last
    /// of those was the only mention some conversations got. Requiring the
    /// word left them under no project for the sake of a filter that was
    /// never the thing keeping the map honest.
    ///
    /// What keeps it honest is the caller: it looks up only the ids it found
    /// as `conversations/<id>.db` on disk, so a trajectory or request id in
    /// here names nothing and is never asked about.
    static func conversationIDs(in line: Data) -> [String] {
        guard let text = String(data: line, encoding: .utf8), text.utf8.count >= 36
        else { return [] }
        return text
            .split(whereSeparator: { !($0.isHexDigit || $0 == "-") })
            .map(String.init)
            .filter(isConversationID)
            .map { $0.lowercased() }
    }

    /// `8-4-4-4-12` hex. The same shape the conversation databases are named
    /// with, which is what makes a match on one meaningful.
    static func isConversationID(_ text: String) -> Bool {
        guard text.count == 36 else { return false }
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return text.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}
