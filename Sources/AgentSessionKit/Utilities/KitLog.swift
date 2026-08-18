import Foundation
import os.log

/// The package's own logger, with the explicit invariant that NO sensitive
/// material (access tokens, raw credentials, session bodies, file paths
/// under the user's home) ever passes through. Always call with an already
/// redacted value — `sanitize` is the tool for the ones you cannot vouch
/// for by construction.
///
/// Deliberately named for this package rather than sharing a host app's
/// logger type: a session store is full of the user's own words, and a
/// library that logs into someone else's subsystem makes it that much
/// harder to audit what actually reaches the log.
public enum KitLog {
    public static let subsystem = "com.astroqore.AgentSessionKit"

    private static let general = Logger(subsystem: subsystem, category: "general")

    public static func info(_ message: String) {
        general.info("\(message, privacy: .public)")
    }

    public static func warn(_ message: String) {
        general.warning("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        general.error("\(message, privacy: .public)")
    }

    /// Sanitizes an arbitrary string for log inclusion: collapses newlines
    /// and replaces token-shaped runs (>= 20 characters of
    /// alphanumerics / `-` / `.` / `_`) with `***`. A session id, an OAuth
    /// token, and a long opaque filename all match — which is the point.
    public static func sanitize(_ raw: String) -> String {
        let collapsed = raw.replacingOccurrences(of: "\n", with: " ")
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9_\\-\\.]{20,}") else {
            return collapsed
        }
        let range = NSRange(collapsed.startIndex..., in: collapsed)
        return regex.stringByReplacingMatches(
            in: collapsed, options: [], range: range, withTemplate: "***"
        )
    }
}
