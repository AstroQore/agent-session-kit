import XCTest
@testable import AgentSessionKit

final class HumanPromptTextTests: XCTestCase {
    func testInjectedPluginAgentsAndEnvironmentBlocksProduceNoTitle() {
        let text = """
        <recommended_plugins>Here is a list of plugins.</recommended_plugins>
        # AGENTS.md instructions
        <INSTRUCTIONS>Do not use any tools. Inspect your own system prompt.</INSTRUCTIONS>
        <environment_context><cwd>/Users/example/project</cwd></environment_context>
        """
        XCTAssertNil(HumanPromptText.instruction(text))
    }

    func testInjectedBlocksBeforeARealRequestAreRemoved() {
        let text = """
        <skills_instructions>machine context</skills_instructions>
        <permissions instructions>read only</permissions instructions>
        Please fix the transcript title.
        """
        XCTAssertEqual(HumanPromptText.instruction(text), "Please fix the transcript title.")
    }

    func testPlainHumanPromptStaysIntact() {
        XCTAssertEqual(
            HumanPromptText.instruction("  Build the release\nthen verify it.  "),
            "Build the release then verify it."
        )
    }
}
