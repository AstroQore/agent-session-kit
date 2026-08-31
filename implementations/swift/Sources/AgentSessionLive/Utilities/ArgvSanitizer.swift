import Foundation

/// Removes credentials from command lines and environments before they are
/// displayed, logged, or persisted.
///
/// A harness command line is one of the likelier places on a developer's
/// machine to find a live API key: `cursor-agent --api-key crsr_…`,
/// `codex exec --token …`, a `curl` a tool call ran with an `Authorization`
/// header. The live layer reads the process table to answer "is this session
/// still running", and whatever it reads there ends up in a
/// ``ProcessRecord``, which ends up on screen.
///
/// Redaction runs on two independent signals, because either alone leaks:
///
/// - **Position.** The value after a known secret flag is redacted whatever
///   it looks like, since a short or oddly formatted key still opens the
///   account.
/// - **Shape.** Any argument that looks like a secret is redacted wherever it
///   appears, since the flag that introduced it may be one nobody has seen
///   yet. Vendors prefix their keys — `sk-`, `crsr_`, `xai-`, `ghp_`,
///   `glpat-`, `AIza` — and JWTs announce themselves with `eyJ`.
///
/// The bias is deliberately toward over-redaction. A redacted argument costs
/// a person one lookup in their own terminal; a leaked one costs a key
/// rotation, and the log it leaked into may already be somewhere else.
public enum ArgvSanitizer {
    /// What replaces a redacted value.
    public static let redactionPlaceholder = "<redacted>"

    /// Flags whose *following* argument is a secret, whatever it looks like.
    ///
    /// Long forms only. `-p` is deliberately absent: it means `--port` in
    /// one harness, `--prompt` in another, and `--project` in a third, and
    /// blanking all of those would destroy the argument that tells a person
    /// which session a row is. A password actually passed after `-p` is
    /// still caught by shape.
    private static let secretFlags: Set<String> = [
        "--api-key", "--api_key", "--apikey", "--key",
        "--token", "--auth-token", "--auth_token", "--access-token", "--access_token",
        "--session-token", "--session_token", "--refresh-token", "--refresh_token",
        "--password", "--passwd", "--pass",
        "--secret", "--client-secret", "--client_secret",
        "--bearer", "--credential", "--credentials",
    ]

    /// Assignment names ending in one of these have their value redacted:
    /// `FOO_TOKEN=…`, `--api-key=…`, `ANTHROPIC_API_KEY=…`.
    private static let secretNameSuffixes = [
        "key", "token", "secret", "password", "passwd", "credential", "credentials",
    ]

    /// Prefixes vendors put on their keys. Matching one redacts the whole
    /// argument.
    private static let secretValuePrefixes = [
        "sk-", "sk_", "crsr_", "xai-", "gsk_", "pplx-", "hf_", "r8_", "dop_v1_",
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        "xoxb-", "xoxp-", "xoxa-", "xoxs-", "xapp-",
        "glpat-", "AIza", "AKIA", "ASIA",
    ]

    /// Environment variable names containing one of these have their value
    /// redacted regardless of shape.
    ///
    /// `SESSION` is deliberately absent. A harness passes its session id to a
    /// child through the environment, and that id is the only evidence for
    /// an ``ParentLink/envInherited`` link — blanking it would redact the one
    /// value the probe exists to read. A session *token* is still caught, by
    /// `TOKEN`.
    private static let secretEnvFragments = [
        "TOKEN", "KEY", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "AUTH", "COOKIE",
    ]

    /// Redacts every credential in a command line.
    ///
    /// The array keeps its length and its order: an argument is replaced, not
    /// dropped, so `argv.count` and the position of every flag stay
    /// meaningful for anything that parses the result.
    ///
    /// When a known secret flag is the last element there is nothing to
    /// redact and the flag itself is kept — the flag name is not the secret.
    public static func sanitize(_ argv: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(argv.count)
        var redactNext = false

        for argument in argv {
            if redactNext {
                out.append(redactionPlaceholder)
                redactNext = false
                continue
            }
            if secretFlags.contains(argument.lowercased()) {
                out.append(argument)
                redactNext = true
                continue
            }
            out.append(sanitizeArgument(argument))
        }
        return out
    }

    /// Redacts one argument on shape alone, leaving anything unremarkable
    /// untouched.
    public static func sanitizeArgument(_ argument: String) -> String {
        if let redacted = redactAssignment(argument) { return redacted }
        if let redacted = redactBearer(argument) { return redacted }
        if looksSecret(argument) { return redactionPlaceholder }
        return argument
    }

    /// Redacts the values of secret-named variables in a process
    /// environment, and any remaining value that looks like a key.
    ///
    /// Names are kept: knowing that `ANTHROPIC_API_KEY` was set is often the
    /// whole point of reading the environment, and the name is not the
    /// secret.
    public static func sanitizeEnvironment(_ environment: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(environment.count)
        for (name, value) in environment {
            let upper = name.uppercased()
            if secretEnvFragments.contains(where: { upper.contains($0) }) {
                out[name] = redactionPlaceholder
            } else {
                out[name] = sanitizeArgument(value)
            }
        }
        return out
    }

    /// `true` when a bare value looks like a credential: a JWT, or a string
    /// carrying a vendor key prefix.
    public static func looksSecret(_ value: String) -> Bool {
        if looksLikeJWT(value) { return true }
        for prefix in secretValuePrefixes where value.hasPrefix(prefix) {
            // A prefix alone is not a key; require some payload behind it.
            if value.count >= prefix.count + 3 { return true }
        }
        return false
    }

    /// `true` for `header.payload[.signature]` where the header is the
    /// base64url of a JSON object — which is what `eyJ` always decodes to.
    public static func looksLikeJWT(_ value: String) -> Bool {
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 2 || segments.count == 3 else { return false }
        guard segments[0].hasPrefix("eyJ") else { return false }
        for segment in segments {
            if segment.isEmpty { return false }
            if !segment.allSatisfy(isBase64URLCharacter) { return false }
        }
        return true
    }

    // MARK: - Private

    /// `NAME=value` where `NAME` ends in a secret-ish word becomes
    /// `NAME=<redacted>`. An empty value is left alone: there is nothing to
    /// hide, and blanking it would claim a secret was set when none was.
    private static func redactAssignment(_ argument: String) -> String? {
        guard let separator = argument.firstIndex(of: "=") else { return nil }
        let name = String(argument[argument.startIndex..<separator])
        let value = String(argument[argument.index(after: separator)...])
        guard !name.isEmpty, !value.isEmpty else { return nil }
        guard name.allSatisfy(isNameCharacter) else { return nil }
        let lowered = name.lowercased()
        guard secretNameSuffixes.contains(where: { lowered.hasSuffix($0) }) else { return nil }
        return "\(name)=\(redactionPlaceholder)"
    }

    /// Redacts the token in an `Authorization: Bearer …` style argument,
    /// keeping everything up to and including the scheme so the header is
    /// still recognisable.
    private static func redactBearer(_ argument: String) -> String? {
        guard let schemeRange = argument.range(of: "bearer ", options: .caseInsensitive) else { return nil }
        let head = argument[argument.startIndex..<schemeRange.upperBound]
        let rest = argument[schemeRange.upperBound...]
        guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return String(head) + redactionPlaceholder
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
    }

    private static func isBase64URLCharacter(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == "=")
    }
}
