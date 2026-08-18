import CryptoKit
import Foundation

/// A one-way, deterministic hash for deriving stable-but-unlinkable
/// filesystem or index components (cache keys, row ids) from values that
/// must never appear in a path, a log line, or a database column in the
/// clear — a session's real on-disk file path, for example.
///
/// The mapping is SHA-256 over UTF-8 bytes, hex-encoded and prefixed: the
/// same `rawValue` always yields the same component, which is what makes it
/// usable as a cache key, while the raw value itself cannot be recovered
/// from the result.
public enum PrivacyPreservingHash {
    /// Derives a `"\(prefix)-<hex digest>"` component from `rawValue`.
    ///
    /// - Parameters:
    ///   - prefix: A short, human-readable tag prepended to the digest —
    ///     useful for namespacing or versioning the hash, e.g.
    ///     `"session-path-v1"`.
    ///   - rawValue: The sensitive value to hash. Never stored or logged
    ///     directly; only its digest is.
    /// - Returns: `prefix` followed by a `-` and the lowercase hex SHA-256
    ///   digest of `rawValue`.
    public static func fileComponent(prefix: String, rawValue: String) -> String {
        let digest = SHA256.hash(data: Data(rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix)-\(digest)"
    }
}
