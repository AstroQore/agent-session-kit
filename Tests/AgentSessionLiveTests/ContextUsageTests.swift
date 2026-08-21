import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

@Suite("ContextUsage")
struct ContextUsageTests {
    // MARK: - The value

    @Test("a fill over a window is a fraction and a remainder")
    func fractionAndRemainder() {
        let usage = ContextUsage(
            used: 898_800, window: 1_000_000, cached: 880_000, at: epoch, source: .derived
        )
        #expect(usage.fraction == 0.8988)
        #expect(usage.remaining == 101_200)
    }

    @Test("no window means no fraction, and no remainder either")
    func withoutAWindow() {
        let usage = ContextUsage(used: 12_000, window: nil, cached: nil, at: epoch, source: .measured)
        #expect(usage.fraction == nil)
        #expect(usage.remaining == nil)
    }

    @Test("an overfull window is reported as overfull, not capped")
    func overfullIsNotCapped() {
        let usage = ContextUsage(used: 220_000, window: 200_000, cached: 0, at: epoch, source: .derived)
        #expect((usage.fraction ?? 0) > 1)
        #expect(usage.remaining == 0)
    }

    @Test("a zero window is not a division")
    func zeroWindow() {
        let usage = ContextUsage(used: 100, window: 0, cached: nil, at: epoch, source: .measured)
        #expect(usage.fraction == nil)
        #expect(usage.remaining == 0)
    }

    // MARK: - The table

    @Test("the standard table knows the Claude family's window")
    func standardTable() {
        let windows = ModelContextWindows.standard
        #expect(windows.window(for: "claude-opus-5-20260514") == 200_000)
        #expect(windows.window(for: "claude-sonnet-4-5-20250929") == 200_000)
    }

    @Test("a 1M marker beats the family it is in, whatever its case")
    func millionTokenMarker() {
        let windows = ModelContextWindows.standard
        #expect(windows.window(for: "claude-opus-5[1m]") == 1_000_000)
        #expect(windows.window(for: "CLAUDE-OPUS-5[1M]") == 1_000_000)
    }

    @Test("a model the table has never heard of answers nothing")
    func unknownModelIsNil() {
        let windows = ModelContextWindows.standard
        #expect(windows.window(for: "gpt-5.1-codex-max") == nil)
        #expect(windows.window(for: "") == nil)
        #expect(windows.window(for: nil) == nil)
    }

    @Test("a host's override wins, and the longest prefix wins among them")
    func overrides() {
        let windows = ModelContextWindows.standard.overriding([
            "claude-": 300_000,
            "claude-haiku-": 128_000,
        ])
        #expect(windows.window(for: "claude-opus-5-20260514") == 300_000)
        #expect(windows.window(for: "claude-haiku-4-5") == 128_000)
        // The marker still qualifies the family it overrode.
        #expect(windows.window(for: "claude-haiku-4-5[1m]") == 1_000_000)
    }

    @Test("a fallback answers for everything the table missed")
    func fallback() {
        let windows = ModelContextWindows(prefixes: [:], markers: [:], fallback: 64_000)
        #expect(windows.window(for: "anything-at-all") == 64_000)
    }

    // MARK: - Folding

    @Test("the newest reading replaces the one before it")
    func newestReadingWins() {
        var harness = ReducerHarness()
        harness.send(.contextUsage(used: 10_000, window: 200_000, cached: 4_000, source: .derived))
        harness.send(.contextUsage(used: 42_000, window: 200_000, cached: 30_000, source: .derived))
        #expect(harness.snapshot.contextUsage?.used == 42_000)
        #expect(harness.snapshot.contextUsage?.cached == 30_000)
        #expect(harness.snapshot.contextUsage?.source == .derived)
        // A level, not a total: two readings do not add up to 52,000.
        #expect(harness.snapshot.tokensIn == 0)
    }

    @Test("a reading with no window keeps the window the session already reported")
    func windowCarriesForward() {
        var harness = ReducerHarness()
        harness.send(.contextUsage(used: 10_000, window: 200_000, cached: nil, source: .measured))
        harness.send(.contextUsage(used: 20_000, window: nil, cached: nil, source: .measured))
        #expect(harness.snapshot.contextUsage?.window == 200_000)
        #expect(harness.snapshot.contextUsage?.used == 20_000)
    }

    @Test("a reading stamped before the one on record is dropped")
    func staleReadingIsDropped() {
        var harness = ReducerHarness()
        harness.send(.contextUsage(used: 42_000, window: 200_000, cached: nil, source: .measured))
        harness.send(
            .contextUsage(used: 10_000, window: 200_000, cached: nil, source: .measured),
            advance: -30
        )
        #expect(harness.snapshot.contextUsage?.used == 42_000)
    }

    @Test("a compaction is counted, and does not zero the gauge")
    func compactionsAreCounted() {
        var harness = ReducerHarness()
        harness.send(.contextUsage(used: 190_000, window: 200_000, cached: nil, source: .measured))
        harness.send(.compaction)
        harness.send(.compaction)
        #expect(harness.snapshot.compactions == 2)
        #expect(harness.snapshot.contextUsage?.used == 190_000)
    }

    @Test("the newest quota replaces the one before it")
    func quotaFolds() {
        var harness = ReducerHarness()
        let resets = epoch.addingTimeInterval(7_800)
        harness.send(.quota(usedPercent: 12, resetsAt: resets, plan: "pro"))
        harness.send(.quota(usedPercent: 43, resetsAt: resets, plan: "pro"))
        #expect(harness.snapshot.quota?.usedPercent == 43)
        #expect(harness.snapshot.quota?.resetsAt == resets)
        #expect(harness.snapshot.quota?.plan == "pro")
    }

    @Test("a session nobody measured carries nothing rather than zero")
    func absentByDefault() {
        var harness = ReducerHarness()
        harness.send([.userPrompt(preview: "hello"), .turnEnded(reason: .complete)])
        #expect(harness.snapshot.contextUsage == nil)
        #expect(harness.snapshot.quota == nil)
        #expect(harness.snapshot.compactions == 0)
    }

    @Test("a context reading is a heartbeat like any other event")
    func heartbeat() {
        var harness = ReducerHarness()
        harness.send(.contextUsage(used: 1, window: nil, cached: nil, source: .measured))
        #expect(harness.snapshot.lastEventAt == harness.clock)
    }
}

@Suite("Model windows — the Claude 5 family")
struct ClaudeFiveWindowTests {
    @Test("a Claude 5 model is a million-token window without a marker")
    func claudeFive() {
        let table = ModelContextWindows.standard
        #expect(table.window(for: "claude-fable-5") == 1_000_000)
        #expect(table.window(for: "claude-mythos-5") == 1_000_000)
        #expect(table.window(for: "claude-opus-5-20260514") == 200_000)
        #expect(table.window(for: "claude-opus-5-20260514[1m]") == 1_000_000)
        #expect(table.window(for: "claude-opus-4-1-20250805") == 200_000)
        #expect(table.window(for: "claude-haiku-4-5-20251001") == 200_000)
    }
}
