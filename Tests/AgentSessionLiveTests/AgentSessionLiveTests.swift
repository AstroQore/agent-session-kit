import AgentSessionKit
import Testing
@testable import AgentSessionLive

/// Placeholder. The live layer lands in its own change; this asserts only
/// that the target builds, links against `AgentSessionKit`, and is honest
/// about being empty.
@Test func liveLayerIsNotImplementedYet() {
    #expect(AgentSessionLive.isImplemented == false)
    #expect(Harness.allCases.isEmpty == false)
}
