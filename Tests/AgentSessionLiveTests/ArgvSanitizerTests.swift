import Foundation
import Testing
@testable import AgentSessionLive

/// Synthetic secrets only. Every value here is invented and matches no real
/// account; the prefixes are what the sanitizer keys on, not the payloads.
@Suite("ArgvSanitizer")
struct ArgvSanitizerTests {
    private let placeholder = ArgvSanitizer.redactionPlaceholder

    @Test("the value after a secret flag is redacted")
    func flagThenValue() {
        let argv = ["cursor-agent", "--api-key", "crsr_0123456789abcdef", "--print"]
        #expect(ArgvSanitizer.sanitize(argv) == ["cursor-agent", "--api-key", placeholder, "--print"])
    }

    @Test("an inline assignment keeps the flag and loses the value")
    func flagEqualsValue() {
        let argv = ["cursor-agent", "--api-key=crsr_0123456789abcdef"]
        #expect(ArgvSanitizer.sanitize(argv) == ["cursor-agent", "--api-key=\(placeholder)"])
    }

    @Test("environment-style assignments are redacted by name")
    func environmentAssignment() {
        let argv = ["env", "FOO_TOKEN=abc", "ANTHROPIC_API_KEY=abc123", "MY_SECRET=x", "DB_PASSWORD=hunter2"]
        #expect(ArgvSanitizer.sanitize(argv) == [
            "env",
            "FOO_TOKEN=\(placeholder)",
            "ANTHROPIC_API_KEY=\(placeholder)",
            "MY_SECRET=\(placeholder)",
            "DB_PASSWORD=\(placeholder)",
        ])
    }

    @Test("assignment matching is case-insensitive")
    func assignmentCaseInsensitive() {
        #expect(ArgvSanitizer.sanitize(["Api_Key=abc"]) == ["Api_Key=\(placeholder)"])
        #expect(ArgvSanitizer.sanitize(["refresh-token=abc"]) == ["refresh-token=\(placeholder)"])
    }

    @Test("a bearer token is redacted but the header stays readable")
    func bearerHeader() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let argv = ["curl", "-H", "Authorization: Bearer \(jwt)", "https://example.invalid"]
        let sanitized = ArgvSanitizer.sanitize(argv)
        #expect(sanitized == ["curl", "-H", "Authorization: Bearer \(placeholder)", "https://example.invalid"])
        #expect(!sanitized.joined(separator: " ").contains("eyJ"))
    }

    @Test("a bare JWT is redacted wherever it appears")
    func bareJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(ArgvSanitizer.sanitize(["some-cli", jwt]) == ["some-cli", placeholder])
        #expect(ArgvSanitizer.looksLikeJWT(jwt))
    }

    @Test("an unsigned two-segment JWT is still a JWT")
    func twoSegmentJWT() {
        #expect(ArgvSanitizer.looksLikeJWT("eyJhbGciOiJub25lIn0.eyJzdWIiOiIxIn0"))
    }

    @Test("things that merely contain dots are not JWTs", arguments: [
        "example.com",
        "a.b.c",
        "eyJ",
        "eyJabc.",
        "foo.eyJabc.bar",
        "1.2.3.4",
    ])
    func notJWTs(_ value: String) {
        #expect(ArgvSanitizer.looksLikeJWT(value) == false)
    }

    @Test("vendor key prefixes are redacted on shape alone", arguments: [
        "sk-abcdefghijklmnopqrstuvwxyz",
        "crsr_0123456789abcdef",
        "xai-0123456789abcdef",
        "ghp_0123456789abcdefghij",
        "github_pat_0123456789abcdef",
        "xoxb-0123-4567-abcdef",
        "glpat-0123456789abcdef",
        "AIzaSyA0123456789abcdefghij",
    ])
    func vendorPrefixes(_ secret: String) {
        #expect(ArgvSanitizer.looksSecret(secret))
        #expect(ArgvSanitizer.sanitize(["tool", secret]) == ["tool", placeholder])
    }

    @Test("a prefix with nothing behind it is not treated as a key")
    func barePrefix() {
        #expect(ArgvSanitizer.looksSecret("sk-") == false)
        #expect(ArgvSanitizer.looksSecret("crsr_") == false)
    }

    @Test("ordinary arguments are left exactly as they were")
    func normalArgumentsSurvive() {
        let argv = [
            "codex", "exec", "--skip-git-repo-check",
            "--sandbox", "read-only",
            "-m", "gpt-5.6-terra",
            "--cd", "/Users/example/code/demo",
            "-p", "8080",
            "--model=claude-opus-5",
            "PATH=/usr/bin:/bin",
            "https://example.invalid/docs",
            "Summarize the changes.",
        ]
        #expect(ArgvSanitizer.sanitize(argv) == argv)
    }

    @Test("the array keeps its length and its ordering")
    func shapeIsPreserved() {
        let argv = ["a", "--token", "abc", "b"]
        let sanitized = ArgvSanitizer.sanitize(argv)
        #expect(sanitized.count == argv.count)
        #expect(sanitized[0] == "a")
        #expect(sanitized[3] == "b")
    }

    @Test("a secret flag with nothing after it keeps the flag")
    func trailingSecretFlag() {
        #expect(ArgvSanitizer.sanitize(["cli", "--password"]) == ["cli", "--password"])
    }

    @Test("an empty assignment is left alone rather than claiming a secret")
    func emptyAssignment() {
        #expect(ArgvSanitizer.sanitize(["FOO_TOKEN="]) == ["FOO_TOKEN="])
    }

    @Test("an empty argv sanitizes to an empty argv")
    func emptyArgv() {
        #expect(ArgvSanitizer.sanitize([]).isEmpty)
    }

    @Test("environment values are redacted by name and by shape")
    func environmentSanitization() {
        let environment = [
            "ANTHROPIC_API_KEY": "sk-ant-0123456789",
            "GH_TOKEN": "ghp_0123456789abcdefghij",
            "AWS_SECRET_ACCESS_KEY": "abcdef",
            "SUDO_PASSWORD": "hunter2",
            "HTTP_COOKIE": "session=1",
            "OPAQUE_VALUE": "crsr_0123456789abcdef",
            "HOME": "/Users/example",
            "TERM": "xterm-256color",
            "CLAUDE_SESSION_ID": "11111111-2222-3333-4444-555555555555",
        ]
        let sanitized = ArgvSanitizer.sanitizeEnvironment(environment)

        #expect(sanitized["ANTHROPIC_API_KEY"] == placeholder)
        #expect(sanitized["GH_TOKEN"] == placeholder)
        #expect(sanitized["AWS_SECRET_ACCESS_KEY"] == placeholder)
        #expect(sanitized["SUDO_PASSWORD"] == placeholder)
        #expect(sanitized["HTTP_COOKIE"] == placeholder)
        // Redacted on shape, since its name says nothing.
        #expect(sanitized["OPAQUE_VALUE"] == placeholder)
        // Kept: neither the name nor the value is secret-shaped.
        #expect(sanitized["HOME"] == "/Users/example")
        #expect(sanitized["TERM"] == "xterm-256color")
        // Kept, because a session id is what makes a row identifiable.
        #expect(sanitized["CLAUDE_SESSION_ID"] == "11111111-2222-3333-4444-555555555555")
        #expect(sanitized.count == environment.count)
    }
}
