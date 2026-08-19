import Foundation

/// Extracts what a person actually asked from records many harnesses label
/// `user` even when they contain injected machine context.
public enum HumanPromptText {
    public static let previewLimit = 280

    public static let metaTags: Set<String> = [
        "command-name", "command-message", "command-args", "command-contents",
        "system-reminder", "user-prompt-submit-hook", "environment_context",
        "user_instructions", "app-context", "recommended_plugins",
        "skills_instructions", "permissions", "collaboration_mode",
        "apps_instructions", "plugins_instructions", "instructions",
    ]

    public static let metaTagPrefixes = ["local-command-"]

    public static func instruction(_ text: String) -> String? {
        let stripped = stripBoilerplateLines(stripMeta(text))
        let preview = preview(stripped, max: previewLimit)
        guard !preview.isEmpty, !isBareSlashCommand(preview) else { return nil }
        return preview
    }

    public static func isMetaTag(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if metaTags.contains(lowered) { return true }
        return metaTagPrefixes.contains { lowered.hasPrefix($0) }
    }

    public static func stripMeta(_ text: String) -> String {
        var body = text
        while let resume = orphanedCloseEnd(in: body) {
            body = String(body[resume...])
        }
        while let opening = firstMetaOpening(in: body) {
            if let close = tags(in: body).first(where: {
                $0.isClosing
                    && $0.name == opening.name
                    && $0.range.lowerBound >= opening.range.upperBound
            }) {
                body.removeSubrange(opening.range.lowerBound..<close.range.upperBound)
            } else {
                body.removeSubrange(opening.range.lowerBound..<body.endIndex)
            }
        }
        return body
    }

    private static func stripBoilerplateLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let normalized = line.trimmingCharacters(in: .whitespaces).lowercased()
                return !(normalized.hasPrefix("#") && normalized.contains("agents.md instructions"))
            }
            .joined(separator: "\n")
    }

    private static func preview(_ text: String, max: Int) -> String {
        guard max > 0 else { return "" }
        var collapsed = ""
        collapsed.reserveCapacity(text.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !collapsed.isEmpty
                continue
            }
            if pendingSpace { collapsed.append(" "); pendingSpace = false }
            collapsed.append(character)
        }
        guard collapsed.count > max else { return collapsed }
        return String(collapsed.prefix(max - 1)) + "…"
    }

    private static func orphanedCloseEnd(in text: String) -> String.Index? {
        for tag in tags(in: text) {
            guard isMetaTag(tag.name) else { continue }
            return tag.isClosing ? tag.range.upperBound : nil
        }
        return nil
    }

    private static func firstMetaOpening(
        in text: String
    ) -> (name: String, range: Range<String.Index>)? {
        for tag in tags(in: text) where !tag.isClosing && isMetaTag(tag.name) {
            return (tag.name, tag.range)
        }
        guard let lt = text.lastIndex(of: "<"), !text[lt...].contains(">") else { return nil }
        let fragment = String(text[text.index(after: lt)...]).lowercased()
        guard !fragment.isEmpty else { return nil }
        let isPrefix = metaTags.contains { $0.hasPrefix(fragment) }
            || metaTagPrefixes.contains { $0.hasPrefix(fragment) }
        guard isPrefix else { return nil }
        return (fragment, lt..<text.endIndex)
    }

    private struct Tag {
        let name: String
        let isClosing: Bool
        let range: Range<String.Index>
    }

    private static func tags(in text: String) -> [Tag] {
        var found: [Tag] = []
        var cursor = text.startIndex
        while let lt = text[cursor...].firstIndex(of: "<") {
            guard let gt = text[lt...].firstIndex(of: ">") else { break }
            var inner = Substring(text[text.index(after: lt)..<gt])
            let isClosing = inner.hasPrefix("/")
            if isClosing { inner = inner.dropFirst() }
            let name = String(inner.prefix { !$0.isWhitespace && $0 != "/" }).lowercased()
            if !name.isEmpty {
                found.append(Tag(name: name, isClosing: isClosing, range: lt..<text.index(after: gt)))
            }
            cursor = text.index(after: gt)
        }
        return found
    }

    private static func isBareSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        return !text.dropFirst().contains(" ")
    }
}
