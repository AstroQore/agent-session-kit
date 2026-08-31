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

extension HumanPromptTextTests {
    func testTaskNotificationIsNotAnInstruction() {
        let text = "<task-notification>\n<task-id>ab97cd8d</task-id>\n<tool-use-id>toolu_x</tool-use-id>\n<output-file>/Users/example/t.out</output-file>\n<status>completed</status>\n<summary>Agent finished</summary>\n<result>Done.</result>\n</task-notification>"
        XCTAssertNil(HumanPromptText.instruction(text))
        XCTAssertEqual(HumanPromptText.instruction(text + "\nPlease summarise the result."), "Please summarise the result.")
    }
}
