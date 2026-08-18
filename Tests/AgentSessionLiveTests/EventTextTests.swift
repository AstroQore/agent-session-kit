import Foundation
import Testing
@testable import AgentSessionLive

@Suite("EventText")
struct EventTextTests {
    @Test("short text passes through unchanged")
    func shortText() {
        #expect(EventText.preview("add a test") == "add a test")
    }

    @Test("newlines and runs of whitespace collapse to single spaces")
    func collapsesWhitespace() {
        #expect(EventText.preview("add\n\na  test\tplease") == "add a test please")
        #expect(EventText.preview("   leading and trailing   ") == "leading and trailing")
        #expect(EventText.preview("\n\n\n") == "")
    }

    @Test("the result never exceeds max, ellipsis included")
    func truncation() {
        let long = String(repeating: "x", count: 500)
        let preview = EventText.preview(long)
        #expect(preview.count == 200)
        #expect(preview.hasSuffix("…"))
        #expect(preview.hasPrefix("xxx"))
    }

    @Test("a custom max is respected")
    func customMax() {
        #expect(EventText.preview("abcdefghij", max: 5) == "abcd…")
        #expect(EventText.preview("abcde", max: 5) == "abcde")
        #expect(EventText.preview("abcdef", max: 1) == "…")
    }

    @Test("a non-positive max yields an empty string")
    func zeroMax() {
        #expect(EventText.preview("anything", max: 0) == "")
        #expect(EventText.preview("anything", max: -3) == "")
    }

    @Test("truncation counts characters, so a grapheme cluster is never split")
    func graphemeClusters() {
        let flags = String(repeating: "🇯🇵", count: 10)
        let preview = EventText.preview(flags, max: 5)
        #expect(preview.count == 5)
        #expect(preview == "🇯🇵🇯🇵🇯🇵🇯🇵…")
    }

    @Test("collapsing is idempotent")
    func idempotent() {
        let once = EventText.collapseWhitespace("a  b\nc")
        #expect(EventText.collapseWhitespace(once) == once)
        #expect(once == "a b c")
    }
}
