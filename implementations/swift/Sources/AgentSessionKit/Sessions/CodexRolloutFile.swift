import Foundation

/// Names of Codex rollout files, plain or compressed.
///
/// Codex writes `rollout-<stamp>-<uuid>.jsonl`. With the experimental
/// `local_thread_store_compression` feature on, each start-up rewrites
/// rollouts idle for a week as `rollout-<stamp>-<uuid>.jsonl.zst` (same
/// bytes, zstd-framed) and removes the original. Both spellings name the
/// same thread, so anything keyed on the path — a host's scan cache, a
/// usage ledger's per-file digests — should key on the *canonical* path,
/// the one without `.zst`, or the rename reads as a brand-new session.
public enum CodexRolloutFile {
    public static let plainExtension = "jsonl"
    public static let compressedExtension = "zst"
    public static let compressedSuffix = ".jsonl.zst"
    public static let namePrefix = "rollout-"

    /// `rollout-*.jsonl` or `rollout-*.jsonl.zst`.
    public static func isRollout(_ url: URL) -> Bool {
        isRolloutName(url.lastPathComponent)
    }

    public static func isRolloutName(_ name: String) -> Bool {
        name.hasPrefix(namePrefix) && (name.hasSuffix(".jsonl") || name.hasSuffix(compressedSuffix))
    }

    /// Any `.jsonl` / `.jsonl.zst`, rollout-named or not. Discovery uses
    /// this because older Codex builds wrote other names under `sessions/`.
    public static func isJSONL(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".jsonl") || name.hasSuffix(compressedSuffix)
    }

    public static func isCompressed(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(compressedSuffix)
    }

    /// The file name without `.jsonl` or `.jsonl.zst` —
    /// `rollout-<stamp>-<uuid>`.
    public static func stem(of url: URL) -> String {
        stem(ofName: url.lastPathComponent)
    }

    public static func stem(ofName name: String) -> String {
        if name.hasSuffix(compressedSuffix) {
            return String(name.dropLast(compressedSuffix.count))
        }
        if name.hasSuffix(".jsonl") {
            return String(name.dropLast(".jsonl".count))
        }
        return name
    }

    /// The path a rollout had before compression: `.jsonl.zst` → `.jsonl`.
    /// Identity for anything else.
    public static func canonicalPath(_ path: String) -> String {
        guard path.hasSuffix(compressedSuffix) else { return path }
        return String(path.dropLast(compressedExtension.count + 1))
    }
}
