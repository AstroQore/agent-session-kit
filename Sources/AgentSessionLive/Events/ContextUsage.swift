import Foundation

/// How full a session's context window was the last time the model ran.
///
/// This is the `/context` gauge, not the bill. ``SessionSnapshot/tokensIn``
/// and its neighbours are cumulative — every token the session ever paid for
/// — while this is a *level*: what was in the window when the model was last
/// called. That is the number that says whether a session is about to compact
/// and forget what it was doing, which is a thing a person watching a board
/// can act on and a running total is not.
///
/// ## What `used` means, across three harnesses
///
/// One definition, because a gauge that means different things on different
/// rows is not a gauge: **the tokens that were in the model's context when it
/// was last called** — the whole prompt, cached prefix included.
///
/// | Harness | Read from | ``Source`` |
/// | --- | --- | --- |
/// | Claude Code | `message.usage.input_tokens` + `cache_read_input_tokens` + `cache_creation_input_tokens` on the newest assistant record | ``Source/derived`` |
/// | Codex | `info.last_token_usage.input_tokens` of a `token_count` event, which Codex reports with its cached share already in it | ``Source/measured`` |
/// | Grok Build | `contextTokensUsed` in `signals.json`, which the harness computes for itself | ``Source/measured`` |
///
/// The reply the model just generated is deliberately *not* added. It lands in
/// the *next* call's input, so counting it here would run the gauge ahead of
/// the window by one message — and, on a session that stopped mid-turn, for
/// good.
///
/// Cursor, AntiGravity, Grok Bot, and Claude Cowork record nothing that
/// answers this, so their snapshots carry `nil`. An invented denominator would
/// put a full-looking gauge on a row nobody can check.
public struct ContextUsage: Hashable, Codable, Sendable {
    /// Where the window figure came from — the difference between a gauge a
    /// UI may state flatly and one it has to hedge.
    public enum Source: String, Codable, Sendable, CaseIterable {
        /// The store wrote the window size down itself: Codex's
        /// `info.model_context_window`, Grok's `contextWindowTokens`.
        case measured
        /// The store recorded only the token counts, and the window was looked
        /// up from the model id — see ``ModelContextWindows``. Right for every
        /// model this package knows and wrong the day one ships with a window
        /// it has not heard of, which is exactly why it is labelled rather
        /// than presented as measurement.
        case derived
    }

    /// Tokens in the window when the model was last called. See the type's
    /// discussion for what is and is not counted.
    public let used: Int
    /// The window size, or `nil` when neither the store nor the model table
    /// could say. A gauge with no denominator is a number, not a fill.
    public let window: Int?
    /// How much of ``used`` was served from a prompt cache, when the store
    /// separated it out. Not subtracted from ``used``: a cached token occupies
    /// the window exactly as a fresh one does, it is only cheaper.
    public let cached: Int?
    /// The source's own timestamp for the step this level was read from.
    public let at: Date
    /// Whether ``window`` was measured or looked up.
    public let source: Source

    /// Creates a reading.
    public init(used: Int, window: Int?, cached: Int?, at: Date, source: Source) {
        self.used = used
        self.window = window
        self.cached = cached
        self.at = at
        self.source = source
    }

    /// ``used`` over ``window``, or `nil` without a window.
    ///
    /// Deliberately not clamped at 1. A harness that reports a fill larger
    /// than the window it also reported is telling you something is wrong with
    /// one of the two numbers, and a silently capped gauge would hide it.
    public var fraction: Double? {
        guard let window, window > 0 else { return nil }
        return Double(used) / Double(window)
    }

    /// Tokens left before the window is full, floored at zero, or `nil`
    /// without a window.
    public var remaining: Int? {
        guard let window else { return nil }
        return max(window - used, 0)
    }
}

/// Model id → context window, for the harnesses whose stores record the token
/// counts but not the size of the window they filled.
///
/// Only Claude Code needs it: Codex writes `model_context_window` into every
/// `token_count` event and Grok writes `contextWindowTokens` into
/// `signals.json`, so both are measured and neither consults this table.
///
/// The table is small on purpose. Every entry is a claim about a model that
/// goes stale on its own schedule, and a wrong denominator is worse than an
/// absent one — it renders as a confident gauge pointing at the wrong number.
/// So: a marker rule for the long-context variants, one prefix for the family
/// whose members all share a window, and ``fallback`` left `nil` so a model
/// nothing matches answers "I do not know" rather than a plausible guess.
///
/// A host that knows better passes its own:
///
/// ```swift
/// let windows = ModelContextWindows.standard.overriding(["my-model-": 512_000])
/// ClaudeLiveAdapter(contextWindows: windows)
/// ```
public struct ModelContextWindows: Sendable, Hashable {
    /// The window every current Claude model has unless its id says otherwise.
    /// The documented default of ``standard``'s `claude-` prefix.
    public static let defaultWindow = 200_000

    /// The window a long-context variant has.
    public static let millionTokenWindow = 1_000_000

    /// What Claude Code appends to a model id running with the 1M-token
    /// context beta — `claude-opus-5[1m]`. A marker rather than a prefix,
    /// because it qualifies a family rather than naming one.
    public static let millionTokenMarker = "[1m]"

    /// Model id prefixes, lowercased on lookup. The longest match wins, so a
    /// specific id can override the family it belongs to.
    public var prefixes: [String: Int]

    /// Substrings that qualify a model whatever family it is in. Checked
    /// before ``prefixes``: a `[1m]` variant is a 1M window first and a
    /// `claude-` model second.
    public var markers: [String: Int]

    /// The answer for a model nothing matched. `nil` on ``standard`` — see the
    /// type's discussion.
    public var fallback: Int?

    /// Creates a table.
    public init(prefixes: [String: Int] = [:], markers: [String: Int] = [:], fallback: Int? = nil) {
        self.prefixes = prefixes
        self.markers = markers
        self.fallback = fallback
    }

    /// What this package knows, and nothing more.
    public static let standard = ModelContextWindows(
        prefixes: ["claude-": defaultWindow],
        markers: [millionTokenMarker: millionTokenWindow],
        fallback: nil
    )

    /// The window for a model id, or `nil` when nothing in the table matches
    /// and there is no ``fallback``.
    ///
    /// Case-insensitive, and deterministic: matches are resolved longest-first
    /// and ties broken by the key itself, so the answer never depends on
    /// dictionary iteration order.
    public func window(for model: String?) -> Int? {
        guard let model, !model.isEmpty else { return nil }
        let id = model.lowercased()
        for (marker, window) in Self.ordered(markers) where id.contains(marker) {
            return window
        }
        for (prefix, window) in Self.ordered(prefixes) where id.hasPrefix(prefix) {
            return window
        }
        return fallback
    }

    /// This table with `overrides` merged over its ``prefixes``.
    public func overriding(_ overrides: [String: Int]) -> ModelContextWindows {
        var merged = self
        for (prefix, window) in overrides { merged.prefixes[prefix] = window }
        return merged
    }

    /// Keys lowercased and ordered longest-first, ties broken alphabetically.
    private static func ordered(_ table: [String: Int]) -> [(String, Int)] {
        table.map { ($0.key.lowercased(), $0.value) }
            .sorted { lhs, rhs in
                if lhs.0.count != rhs.0.count { return lhs.0.count > rhs.0.count }
                return lhs.0 < rhs.0
            }
    }
}

/// What a harness's own store says about the plan limit the session is
/// spending against.
///
/// Read off disk, never fetched: the numbers below are whatever the harness
/// last wrote into its transcript, so they are as fresh as the session is and
/// no fresher. Codex is the only store on this machine that records them —
/// `event_msg.token_count` carries a `rate_limits` block beside its token
/// counters — which is why this is one small value and not a billing model.
/// The package's boundary rule still holds: this is what a *log* said, not a
/// price, a quota policy, or an account.
public struct SessionQuota: Hashable, Codable, Sendable {
    /// How much of the window has been consumed, 0–100 as the store spells it.
    public let usedPercent: Double
    /// When the window rolls over, when the store said.
    public let resetsAt: Date?
    /// The plan name the store recorded — `pro`, `team`, … — verbatim.
    public let plan: String?
    /// The source's own timestamp for the record this came from.
    public let at: Date

    /// Creates a quota reading.
    public init(usedPercent: Double, resetsAt: Date?, plan: String?, at: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.plan = plan
        self.at = at
    }
}
