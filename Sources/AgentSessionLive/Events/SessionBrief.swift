import Foundation

/// What a person asked a session to do, and the last thing it said back.
///
/// The state machine answers *what is this session doing*; a brief answers the
/// two questions that come before it — **what did I ask for**, and **what came
/// of it**. Somebody running a dozen sessions across five harnesses forgets the
/// first within an hour, and a board that can only say "Thinking" cannot remind
/// them.
///
/// Every string here is a preview, never content: already whitespace-collapsed
/// by the adapter that emitted the event, capped again at ``previewLimit`` on
/// the way in, and single-line by construction. The full text of a prompt or a
/// reply travels in ``AgentEventKind/textBody(role:text:toolCallID:)`` for a
/// host that keeps an index, and nothing in this type is a substitute for it.
///
/// ## What counts as an instruction
///
/// Half of what a harness records as a "user message" is not something a
/// person typed: slash-command envelopes, hook output, injected skill
/// preambles, the environment blob a CLI prepends to the first turn. Those are
/// stripped by ``instruction(_:)`` and never reach any of the prompt fields —
/// not ``firstPrompt``, not ``latestPrompt``, not ``lastPromptAt``. A board
/// whose "asked:" line reads `<system-reminder>` is worse than one with no
/// line at all.
///
/// ## Ordering
///
/// A harness flushes a whole turn at once and a tailer can be handed lines out
/// of order, so every field guards its own clock: ``firstPrompt`` yields only
/// to a prompt stamped *earlier* than the one recorded, the latest fields only
/// to one stamped at or after theirs, and ``lastTurnEndedAt`` only moves
/// forward.
///
/// One honest limitation: a cold start seeds from the *tail* of a transcript,
/// so ``firstPrompt`` on a session Auspex met at line nine hundred is the first
/// instruction it *saw*, not the first the person gave. A host that keeps a
/// full-text index can do better; a reducer folding a stream cannot.
public struct SessionBrief: Hashable, Codable, Sendable {
    /// The assignment: the first instruction that was a person talking.
    public var firstPrompt: String?
    /// When ``firstPrompt`` was said — how long the session has been on the
    /// task.
    public var firstPromptAt: Date?
    /// The most recent instruction. Equal to ``firstPrompt`` until a follow-up
    /// arrives.
    public var latestPrompt: String?
    /// When ``latestPrompt`` was said.
    public var lastPromptAt: Date?
    /// The last thing the model said in prose. `nil` for a session that has
    /// only ever run tools.
    public var latestAssistant: String?
    /// When ``latestAssistant`` was said.
    public var lastAssistantAt: Date?
    /// When a turn last closed, whatever the reason.
    ///
    /// This is the "and it finished" half of *done and waiting for me to
    /// look*: a host compares it against its own record of when the person
    /// last opened the session. Only ``AgentEventKind/turnEnded(reason:)``
    /// sets it — a session that ended without closing its turn leaves it
    /// `nil`, and ``SessionSnapshot/endedAt`` is the fact to use there.
    public var lastTurnEndedAt: Date?

    /// Creates a brief. Everything defaults to "not observed yet".
    public init(
        firstPrompt: String? = nil,
        firstPromptAt: Date? = nil,
        latestPrompt: String? = nil,
        lastPromptAt: Date? = nil,
        latestAssistant: String? = nil,
        lastAssistantAt: Date? = nil,
        lastTurnEndedAt: Date? = nil
    ) {
        self.firstPrompt = firstPrompt
        self.firstPromptAt = firstPromptAt
        self.latestPrompt = latestPrompt
        self.lastPromptAt = lastPromptAt
        self.latestAssistant = latestAssistant
        self.lastAssistantAt = lastAssistantAt
        self.lastTurnEndedAt = lastTurnEndedAt
    }

    /// `true` when nothing has been observed at all.
    public var isEmpty: Bool {
        firstPrompt == nil && latestPrompt == nil
            && latestAssistant == nil && lastTurnEndedAt == nil
    }

    /// ``latestPrompt``, but only when it says something ``firstPrompt`` does
    /// not.
    ///
    /// A card shows the assignment on its title line; repeating it verbatim on
    /// the "asked:" line below costs a row of pixels and tells nobody
    /// anything.
    public var followUpPrompt: String? {
        guard let latestPrompt, latestPrompt != firstPrompt else { return nil }
        return latestPrompt
    }

    // MARK: - Recording

    /// Folds one ``AgentEventKind/userPrompt(preview:)`` in.
    ///
    /// A preview that is not an instruction — see ``instruction(_:)`` — is
    /// dropped whole: it does not become the assignment, it does not become
    /// the latest prompt, and it does not move ``lastPromptAt``.
    public mutating func record(prompt text: String, at timestamp: Date) {
        guard let prompt = Self.instruction(text) else { return }
        let isEarlier = firstPromptAt.map { timestamp < $0 } ?? false
        if firstPrompt == nil || isEarlier {
            firstPrompt = prompt
            firstPromptAt = timestamp
        }
        let isStale = lastPromptAt.map { timestamp < $0 } ?? false
        if !isStale {
            latestPrompt = prompt
            lastPromptAt = timestamp
        }
    }

    /// Folds one ``AgentEventKind/assistantText(preview:)`` in.
    ///
    /// Assistant prose is not filtered the way a prompt is — every word of it
    /// was produced for the person to read — beyond dropping an empty preview,
    /// which a harness emits when a turn was only tool calls.
    public mutating func record(reply text: String, at timestamp: Date) {
        let reply = EventText.preview(text, max: Self.previewLimit)
        guard !reply.isEmpty else { return }
        let isStale = lastAssistantAt.map { timestamp < $0 } ?? false
        guard !isStale else { return }
        latestAssistant = reply
        lastAssistantAt = timestamp
    }

    /// Folds one ``AgentEventKind/turnEnded(reason:)`` in. Monotonic.
    public mutating func recordTurnEnded(at timestamp: Date) {
        if let lastTurnEndedAt, lastTurnEndedAt >= timestamp { return }
        lastTurnEndedAt = timestamp
    }

    // MARK: - Instructions

    /// Characters kept in any of the brief's lines.
    ///
    /// Wider than the 200 an adapter's preview uses, so that this cap is a
    /// backstop rather than a second truncation: a brief renders on two lines
    /// of a card, not one column of a table.
    public static let previewLimit = 280

    /// The instruction inside a user-prompt preview, or `nil` when there is
    /// none.
    ///
    /// Strips the envelopes a harness wraps around things a person did not
    /// type — see ``metaTags`` — and refuses what is left when it is empty or
    /// a bare slash command. Total: any input yields a string or `nil`, never
    /// a throw.
    public static func instruction(_ text: String) -> String? {
        let preview = EventText.preview(stripMeta(text), max: previewLimit)
        guard !preview.isEmpty, !isBareSlashCommand(preview) else { return nil }
        return preview
    }

    /// The tags a harness wraps machine-generated context in.
    ///
    /// Claude Code spells a slash command as
    /// `<command-name>/foo</command-name><command-args>…</command-args>` and
    /// injects context as `<system-reminder>`; Codex prepends
    /// `<environment_context>` and `<user_instructions>` to the first turn of
    /// a rollout. None of it is a person asking for anything, and all of it
    /// arrives on records that no `isMeta` flag covers.
    public static let metaTags: Set<String> = [
        "command-name",
        "command-message",
        "command-args",
        "command-contents",
        "system-reminder",
        "user-prompt-submit-hook",
        "environment_context",
        "user_instructions",
        "app-context",
    ]

    /// Tag families matched by prefix: Claude Code writes
    /// `<local-command-stdout>`, `<local-command-stderr>`, and
    /// `<local-command-caveat>`, and adds to the list between releases.
    public static let metaTagPrefixes = ["local-command-"]

    /// Whether a tag name names machine-generated context.
    public static func isMetaTag(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if metaTags.contains(lowered) { return true }
        return metaTagPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// Removes every meta block, including the ones a preview cut in half.
    ///
    /// Truncation is the case that matters: a 40 KB skill preamble becomes
    /// `<system-reminder>You have been…`, an opening tag with no close. So an
    /// unterminated meta block swallows the rest of the string, and a preview
    /// that begins *after* an opening it never saw drops everything through
    /// the orphaned close.
    static func stripMeta(_ text: String) -> String {
        var body = text
        while let resume = orphanedCloseEnd(in: body) {
            body = String(body[resume...])
        }
        while let opening = firstMetaOpening(in: body) {
            let tail = opening.range.upperBound..<body.endIndex
            if let close = body.range(
                of: "</\(opening.name)>", options: [.caseInsensitive], range: tail
            ) {
                body.removeSubrange(opening.range.lowerBound..<close.upperBound)
            } else {
                body.removeSubrange(opening.range.lowerBound..<body.endIndex)
            }
        }
        return body
    }

    /// The index just past a closing meta tag that has no opening before it,
    /// or `nil` when the string does not start inside a meta block.
    private static func orphanedCloseEnd(in text: String) -> String.Index? {
        for tag in tags(in: text) {
            guard isMetaTag(tag.name) else { continue }
            // The first meta tag decides: a close means the string began
            // inside the block, an open means the block starts here and the
            // other pass owns it.
            return tag.isClosing ? tag.range.upperBound : nil
        }
        return nil
    }

    /// The first opening meta tag, with the name to look for a close by.
    private static func firstMetaOpening(in text: String) -> (name: String, range: Range<String.Index>)? {
        for tag in tags(in: text) where !tag.isClosing && isMetaTag(tag.name) {
            return (tag.name, tag.range)
        }
        // `<system-remind` — a preview cut inside the tag itself. Nobody types
        // the prefix of a meta tag at the end of a sentence.
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

    /// Every `<…>` in the string, in order. Syntactic only: it never decides
    /// whether the text is markup, just where the angle brackets are.
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

    /// `/clear`, `/compact`, `/model` — a command to the harness, not a task
    /// for the model.
    ///
    /// Only the bare form. `/dual-supervisor rewrite the parser` carries an
    /// instruction after the command and is kept whole, because the words
    /// after the slash are what the person actually wants done.
    private static func isBareSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        return !text.dropFirst().contains(" ")
    }
}
