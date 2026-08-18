import AgentSessionKit
import Foundation

/// AntiGravity's `steps.step_type` — one value per tool, plus the handful of
/// row kinds that are not tool calls at all.
///
/// The numbers are an internal enum with no published schema. This table was
/// decoded from the `agy` binary's embedded `FileDescriptorProto`
/// (`CORTEX_STEP_TYPE_*`, 2026-08-19) rather than inferred from a corpus, so it
/// is complete for that build: all 118 values, including the ones no
/// conversation on this machine ever produced.
///
/// A value outside the table is not an error — a later AntiGravity may add one
/// — so callers take the optional and fall back to ``label(rawValue:)``.
public enum AntigravityStepType: Int, Sendable, Hashable, CaseIterable, Codable {
    /// `CORTEX_STEP_TYPE_UNSPECIFIED`
    case unspecified = 0
    /// `CORTEX_STEP_TYPE_DUMMY`
    case dummy = 1
    /// `CORTEX_STEP_TYPE_FINISH`
    case finish = 2
    /// `CORTEX_STEP_TYPE_PLAN_INPUT`
    case planInput = 3
    /// `CORTEX_STEP_TYPE_MQUERY`
    case mquery = 4
    /// `CORTEX_STEP_TYPE_CODE_ACTION`
    case codeAction = 5
    /// `CORTEX_STEP_TYPE_GIT_COMMIT`
    case gitCommit = 6
    /// `CORTEX_STEP_TYPE_GREP_SEARCH`
    case grepSearch = 7
    /// `CORTEX_STEP_TYPE_VIEW_FILE`
    case viewFile = 8
    /// `CORTEX_STEP_TYPE_LIST_DIRECTORY`
    case listDirectory = 9
    /// `CORTEX_STEP_TYPE_COMPILE`
    case compile = 10
    /// `CORTEX_STEP_TYPE_VIEW_CODE_ITEM`
    case viewCodeItem = 13
    /// `CORTEX_STEP_TYPE_USER_INPUT`
    case userInput = 14
    /// `CORTEX_STEP_TYPE_PLANNER_RESPONSE`
    case plannerResponse = 15
    /// `CORTEX_STEP_TYPE_ERROR_MESSAGE`
    case errorMessage = 17
    /// `CORTEX_STEP_TYPE_RUN_COMMAND`
    case runCommand = 21
    /// `CORTEX_STEP_TYPE_CHECKPOINT`
    case checkpoint = 23
    /// `CORTEX_STEP_TYPE_PROPOSE_CODE`
    case proposeCode = 24
    /// `CORTEX_STEP_TYPE_FIND`
    case find = 25
    /// `CORTEX_STEP_TYPE_SUGGESTED_RESPONSES`
    case suggestedResponses = 27
    /// `CORTEX_STEP_TYPE_COMMAND_STATUS`
    case commandStatus = 28
    /// `CORTEX_STEP_TYPE_MEMORY`
    case memory = 29
    /// `CORTEX_STEP_TYPE_READ_URL_CONTENT`
    case readUrlContent = 31
    /// `CORTEX_STEP_TYPE_VIEW_CONTENT_CHUNK`
    case viewContentChunk = 32
    /// `CORTEX_STEP_TYPE_SEARCH_WEB`
    case searchWeb = 33
    /// `CORTEX_STEP_TYPE_RETRIEVE_MEMORY`
    case retrieveMemory = 34
    /// `CORTEX_STEP_TYPE_MCP_TOOL`
    case mcpTool = 38
    /// `CORTEX_STEP_TYPE_MANAGER_FEEDBACK`
    case managerFeedback = 39
    /// `CORTEX_STEP_TYPE_TOOL_CALL_PROPOSAL`
    case toolCallProposal = 40
    /// `CORTEX_STEP_TYPE_TOOL_CALL_CHOICE`
    case toolCallChoice = 41
    /// `CORTEX_STEP_TYPE_TRAJECTORY_CHOICE`
    case trajectoryChoice = 42
    /// `CORTEX_STEP_TYPE_CLIPBOARD`
    case clipboard = 45
    /// `CORTEX_STEP_TYPE_VIEW_FILE_OUTLINE`
    case viewFileOutline = 47
    /// `CORTEX_STEP_TYPE_POST_PR_REVIEW`
    case postPrReview = 49
    /// `CORTEX_STEP_TYPE_LIST_RESOURCES`
    case listResources = 51
    /// `CORTEX_STEP_TYPE_READ_RESOURCE`
    case readResource = 52
    /// `CORTEX_STEP_TYPE_LINT_DIFF`
    case lintDiff = 53
    /// `CORTEX_STEP_TYPE_FIND_ALL_REFERENCES`
    case findAllReferences = 54
    /// `CORTEX_STEP_TYPE_BRAIN_UPDATE`
    case brainUpdate = 55
    /// `CORTEX_STEP_TYPE_OPEN_BROWSER_URL`
    case openBrowserUrl = 56
    /// `CORTEX_STEP_TYPE_RUN_EXTENSION_CODE`
    case runExtensionCode = 57
    /// `CORTEX_STEP_TYPE_PROPOSAL_FEEDBACK`
    case proposalFeedback = 59
    /// `CORTEX_STEP_TYPE_TRAJECTORY_SEARCH`
    case trajectorySearch = 60
    /// `CORTEX_STEP_TYPE_EXECUTE_BROWSER_JAVASCRIPT`
    case executeBrowserJavascript = 61
    /// `CORTEX_STEP_TYPE_LIST_BROWSER_PAGES`
    case listBrowserPages = 62
    /// `CORTEX_STEP_TYPE_CAPTURE_BROWSER_SCREENSHOT`
    case captureBrowserScreenshot = 63
    /// `CORTEX_STEP_TYPE_CLICK_BROWSER_PIXEL`
    case clickBrowserPixel = 64
    /// `CORTEX_STEP_TYPE_READ_TERMINAL`
    case readTerminal = 65
    /// `CORTEX_STEP_TYPE_CAPTURE_BROWSER_CONSOLE_LOGS`
    case captureBrowserConsoleLogs = 66
    /// `CORTEX_STEP_TYPE_READ_BROWSER_PAGE`
    case readBrowserPage = 67
    /// `CORTEX_STEP_TYPE_BROWSER_GET_DOM`
    case browserGetDom = 68
    /// `CORTEX_STEP_TYPE_CODE_SEARCH`
    case codeSearch = 73
    /// `CORTEX_STEP_TYPE_BROWSER_INPUT`
    case browserInput = 74
    /// `CORTEX_STEP_TYPE_BROWSER_MOVE_MOUSE`
    case browserMoveMouse = 75
    /// `CORTEX_STEP_TYPE_BROWSER_SELECT_OPTION`
    case browserSelectOption = 76
    /// `CORTEX_STEP_TYPE_BROWSER_SCROLL_UP`
    case browserScrollUp = 77
    /// `CORTEX_STEP_TYPE_BROWSER_SCROLL_DOWN`
    case browserScrollDown = 78
    /// `CORTEX_STEP_TYPE_BROWSER_CLICK_ELEMENT`
    case browserClickElement = 79
    /// `CORTEX_STEP_TYPE_BROWSER_PRESS_KEY`
    case browserPressKey = 80
    /// `CORTEX_STEP_TYPE_TASK_BOUNDARY`
    case taskBoundary = 81
    /// `CORTEX_STEP_TYPE_NOTIFY_USER`
    case notifyUser = 82
    /// `CORTEX_STEP_TYPE_CODE_ACKNOWLEDGEMENT`
    case codeAcknowledgement = 83
    /// `CORTEX_STEP_TYPE_INTERNAL_SEARCH`
    case internalSearch = 84
    /// `CORTEX_STEP_TYPE_BROWSER_SUBAGENT`
    case browserSubagent = 85
    /// `CORTEX_STEP_TYPE_FILE_CHANGE`
    case fileChange = 86
    /// `CORTEX_STEP_TYPE_MOVE`
    case move = 87
    /// `CORTEX_STEP_TYPE_BROWSER_SCROLL`
    case browserScroll = 88
    /// `CORTEX_STEP_TYPE_KNOWLEDGE_GENERATION`
    case knowledgeGeneration = 89
    /// `CORTEX_STEP_TYPE_EPHEMERAL_MESSAGE`
    case ephemeralMessage = 90
    /// `CORTEX_STEP_TYPE_GENERATE_IMAGE`
    case generateImage = 91
    /// `CORTEX_STEP_TYPE_DELETE_DIRECTORY`
    case deleteDirectory = 92
    /// `CORTEX_STEP_TYPE_COMPILE_APPLET`
    case compileApplet = 93
    /// `CORTEX_STEP_TYPE_INSTALL_APPLET_DEPENDENCIES`
    case installAppletDependencies = 94
    /// `CORTEX_STEP_TYPE_INSTALL_APPLET_PACKAGE`
    case installAppletPackage = 95
    /// `CORTEX_STEP_TYPE_BROWSER_RESIZE_WINDOW`
    case browserResizeWindow = 96
    /// `CORTEX_STEP_TYPE_BROWSER_DRAG_PIXEL_TO_PIXEL`
    case browserDragPixelToPixel = 97
    /// `CORTEX_STEP_TYPE_CONVERSATION_HISTORY`
    case conversationHistory = 98
    /// `CORTEX_STEP_TYPE_KNOWLEDGE_ARTIFACTS`
    case knowledgeArtifacts = 99
    /// `CORTEX_STEP_TYPE_SEND_COMMAND_INPUT`
    case sendCommandInput = 100
    /// `CORTEX_STEP_TYPE_SYSTEM_MESSAGE`
    case systemMessage = 101
    /// `CORTEX_STEP_TYPE_WAIT`
    case wait = 102
    /// `CORTEX_STEP_TYPE_AGENCY_TOOL_CALL`
    case agencyToolCall = 103
    /// `CORTEX_STEP_TYPE_CIDER_AGENT_DUMMY`
    case ciderAgentDummy = 104
    /// `CORTEX_STEP_TYPE_BUILD_CLEANER`
    case buildCleaner = 105
    /// `CORTEX_STEP_TYPE_BLAZE_BUILD_TARGETS`
    case blazeBuildTargets = 106
    /// `CORTEX_STEP_TYPE_BLAZE_TEST_TARGETS`
    case blazeTestTargets = 107
    /// `CORTEX_STEP_TYPE_SET_UP_FIREBASE`
    case setUpFirebase = 108
    /// `CORTEX_STEP_TYPE_MOMA`
    case moma = 109
    /// `CORTEX_STEP_TYPE_RESTART_DEV_SERVER`
    case restartDevServer = 110
    /// `CORTEX_STEP_TYPE_DEPLOY_FIREBASE`
    case deployFirebase = 111
    /// `CORTEX_STEP_TYPE_SHELL_EXEC`
    case shellExec = 112
    /// `CORTEX_STEP_TYPE_BROWSER_MOUSE_WHEEL`
    case browserMouseWheel = 113
    /// `CORTEX_STEP_TYPE_LINT_APPLET`
    case lintApplet = 114
    /// `CORTEX_STEP_TYPE_KI_INSERTION`
    case kiInsertion = 116
    /// `CORTEX_STEP_TYPE_RETRIEVE_CONTENT`
    case retrieveContent = 117
    /// `CORTEX_STEP_TYPE_CRITIQUE`
    case critique = 118
    /// `CORTEX_STEP_TYPE_FINDINGS`
    case findings = 119
    /// `CORTEX_STEP_TYPE_BROWSER_MOUSE_UP`
    case browserMouseUp = 120
    /// `CORTEX_STEP_TYPE_BROWSER_MOUSE_DOWN`
    case browserMouseDown = 121
    /// `CORTEX_STEP_TYPE_WORKSPACE_API`
    case workspaceApi = 122
    /// `CORTEX_STEP_TYPE_BROWSER_LIST_NETWORK_REQUESTS`
    case browserListNetworkRequests = 123
    /// `CORTEX_STEP_TYPE_BROWSER_GET_NETWORK_REQUEST`
    case browserGetNetworkRequest = 124
    /// `CORTEX_STEP_TYPE_BROWSER_REFRESH_PAGE`
    case browserRefreshPage = 125
    /// `CORTEX_STEP_TYPE_EDIT_NOTEBOOK`
    case editNotebook = 126
    /// `CORTEX_STEP_TYPE_INVOKE_SUBAGENT`
    case invokeSubagent = 127
    /// `CORTEX_STEP_TYPE_WRITE_BLOB`
    case writeBlob = 128
    /// `CORTEX_STEP_TYPE_READ_NOTEBOOK`
    case readNotebook = 129
    /// `CORTEX_STEP_TYPE_PROPOSE_AI_COMMENTS`
    case proposeAiComments = 130
    /// `CORTEX_STEP_TYPE_START_CODE_REVIEW`
    case startCodeReview = 131
    /// `CORTEX_STEP_TYPE_GENERIC`
    case generic = 132
    /// `CORTEX_STEP_TYPE_SET_UP_CLOUD_SQL`
    case setUpCloudSql = 133
    /// `CORTEX_STEP_TYPE_EXECUTE_NOTEBOOK`
    case executeNotebook = 134
    /// `CORTEX_STEP_TYPE_CLOUD_SQL_UPDATE_SCHEMA`
    case cloudSqlUpdateSchema = 135
    /// `CORTEX_STEP_TYPE_RPC_ACTION`
    case rpcAction = 136
    /// `CORTEX_STEP_TYPE_CLOUD_SQL_EXECUTE_SQL`
    case cloudSqlExecuteSql = 137
    /// `CORTEX_STEP_TYPE_ASK_QUESTION`
    case askQuestion = 138
    /// `CORTEX_STEP_TYPE_DIRECTORY_RULES`
    case directoryRules = 139
    /// `CORTEX_STEP_TYPE_TOOL_SEARCH`
    case toolSearch = 140
}

extension AntigravityStepType {
    /// The descriptor's own name, lower-cased: `run_command`, `search_web`,
    /// `planner_response`.
    ///
    /// Not decoration. AntiGravity's own `ToolCall.tool_name` is exactly this
    /// string for every tool observed, which makes it the honest fallback when a
    /// payload carries no explicit name.
    public var label: String {
        switch self {
        case .unspecified: "unspecified"
        case .dummy: "dummy"
        case .finish: "finish"
        case .planInput: "plan_input"
        case .mquery: "mquery"
        case .codeAction: "code_action"
        case .gitCommit: "git_commit"
        case .grepSearch: "grep_search"
        case .viewFile: "view_file"
        case .listDirectory: "list_directory"
        case .compile: "compile"
        case .viewCodeItem: "view_code_item"
        case .userInput: "user_input"
        case .plannerResponse: "planner_response"
        case .errorMessage: "error_message"
        case .runCommand: "run_command"
        case .checkpoint: "checkpoint"
        case .proposeCode: "propose_code"
        case .find: "find"
        case .suggestedResponses: "suggested_responses"
        case .commandStatus: "command_status"
        case .memory: "memory"
        case .readUrlContent: "read_url_content"
        case .viewContentChunk: "view_content_chunk"
        case .searchWeb: "search_web"
        case .retrieveMemory: "retrieve_memory"
        case .mcpTool: "mcp_tool"
        case .managerFeedback: "manager_feedback"
        case .toolCallProposal: "tool_call_proposal"
        case .toolCallChoice: "tool_call_choice"
        case .trajectoryChoice: "trajectory_choice"
        case .clipboard: "clipboard"
        case .viewFileOutline: "view_file_outline"
        case .postPrReview: "post_pr_review"
        case .listResources: "list_resources"
        case .readResource: "read_resource"
        case .lintDiff: "lint_diff"
        case .findAllReferences: "find_all_references"
        case .brainUpdate: "brain_update"
        case .openBrowserUrl: "open_browser_url"
        case .runExtensionCode: "run_extension_code"
        case .proposalFeedback: "proposal_feedback"
        case .trajectorySearch: "trajectory_search"
        case .executeBrowserJavascript: "execute_browser_javascript"
        case .listBrowserPages: "list_browser_pages"
        case .captureBrowserScreenshot: "capture_browser_screenshot"
        case .clickBrowserPixel: "click_browser_pixel"
        case .readTerminal: "read_terminal"
        case .captureBrowserConsoleLogs: "capture_browser_console_logs"
        case .readBrowserPage: "read_browser_page"
        case .browserGetDom: "browser_get_dom"
        case .codeSearch: "code_search"
        case .browserInput: "browser_input"
        case .browserMoveMouse: "browser_move_mouse"
        case .browserSelectOption: "browser_select_option"
        case .browserScrollUp: "browser_scroll_up"
        case .browserScrollDown: "browser_scroll_down"
        case .browserClickElement: "browser_click_element"
        case .browserPressKey: "browser_press_key"
        case .taskBoundary: "task_boundary"
        case .notifyUser: "notify_user"
        case .codeAcknowledgement: "code_acknowledgement"
        case .internalSearch: "internal_search"
        case .browserSubagent: "browser_subagent"
        case .fileChange: "file_change"
        case .move: "move"
        case .browserScroll: "browser_scroll"
        case .knowledgeGeneration: "knowledge_generation"
        case .ephemeralMessage: "ephemeral_message"
        case .generateImage: "generate_image"
        case .deleteDirectory: "delete_directory"
        case .compileApplet: "compile_applet"
        case .installAppletDependencies: "install_applet_dependencies"
        case .installAppletPackage: "install_applet_package"
        case .browserResizeWindow: "browser_resize_window"
        case .browserDragPixelToPixel: "browser_drag_pixel_to_pixel"
        case .conversationHistory: "conversation_history"
        case .knowledgeArtifacts: "knowledge_artifacts"
        case .sendCommandInput: "send_command_input"
        case .systemMessage: "system_message"
        case .wait: "wait"
        case .agencyToolCall: "agency_tool_call"
        case .ciderAgentDummy: "cider_agent_dummy"
        case .buildCleaner: "build_cleaner"
        case .blazeBuildTargets: "blaze_build_targets"
        case .blazeTestTargets: "blaze_test_targets"
        case .setUpFirebase: "set_up_firebase"
        case .moma: "moma"
        case .restartDevServer: "restart_dev_server"
        case .deployFirebase: "deploy_firebase"
        case .shellExec: "shell_exec"
        case .browserMouseWheel: "browser_mouse_wheel"
        case .lintApplet: "lint_applet"
        case .kiInsertion: "ki_insertion"
        case .retrieveContent: "retrieve_content"
        case .critique: "critique"
        case .findings: "findings"
        case .browserMouseUp: "browser_mouse_up"
        case .browserMouseDown: "browser_mouse_down"
        case .workspaceApi: "workspace_api"
        case .browserListNetworkRequests: "browser_list_network_requests"
        case .browserGetNetworkRequest: "browser_get_network_request"
        case .browserRefreshPage: "browser_refresh_page"
        case .editNotebook: "edit_notebook"
        case .invokeSubagent: "invoke_subagent"
        case .writeBlob: "write_blob"
        case .readNotebook: "read_notebook"
        case .proposeAiComments: "propose_ai_comments"
        case .startCodeReview: "start_code_review"
        case .generic: "generic"
        case .setUpCloudSql: "set_up_cloud_sql"
        case .executeNotebook: "execute_notebook"
        case .cloudSqlUpdateSchema: "cloud_sql_update_schema"
        case .rpcAction: "rpc_action"
        case .cloudSqlExecuteSql: "cloud_sql_execute_sql"
        case .askQuestion: "ask_question"
        case .directoryRules: "directory_rules"
        case .toolSearch: "tool_search"
        }
    }

    /// The normalised activity a board groups by, or `nil` for a row that is not
    /// a tool call — a user prompt, a planner response, a checkpoint.
    ///
    /// Anything that *is* a tool but fits none of the buckets is
    /// ``ToolKind/other`` rather than a guess.
    public var toolKind: ToolKind? {
        switch self {
        case .runCommand, .commandStatus, .readTerminal, .sendCommandInput, .shellExec:
            .shell
        case .viewFile, .listDirectory, .viewCodeItem, .viewContentChunk,
             .viewFileOutline, .readNotebook:
            .fileRead
        case .codeAction, .gitCommit, .proposeCode, .fileChange, .move,
             .deleteDirectory, .editNotebook, .writeBlob:
            .fileWrite
        case .grepSearch, .find, .findAllReferences, .trajectorySearch, .codeSearch,
             .internalSearch, .toolSearch:
            .search
        case .readUrlContent, .searchWeb, .openBrowserUrl, .executeBrowserJavascript,
             .listBrowserPages, .captureBrowserScreenshot, .clickBrowserPixel,
             .captureBrowserConsoleLogs, .readBrowserPage, .browserGetDom,
             .browserInput, .browserMoveMouse, .browserSelectOption, .browserScrollUp,
             .browserScrollDown, .browserClickElement, .browserPressKey,
             .browserSubagent, .browserScroll, .browserResizeWindow,
             .browserDragPixelToPixel, .browserMouseWheel, .browserMouseUp,
             .browserMouseDown, .browserListNetworkRequests, .browserGetNetworkRequest,
             .browserRefreshPage:
            .web
        case .mcpTool:
            .mcp
        case .invokeSubagent:
            .subagent
        case .planInput:
            .plan
        case .mquery, .compile, .memory, .retrieveMemory, .toolCallProposal,
             .toolCallChoice, .trajectoryChoice, .clipboard, .postPrReview,
             .listResources, .readResource, .lintDiff, .brainUpdate, .runExtensionCode,
             .knowledgeGeneration, .generateImage, .compileApplet,
             .installAppletDependencies, .installAppletPackage, .knowledgeArtifacts,
             .wait, .agencyToolCall, .buildCleaner, .blazeBuildTargets,
             .blazeTestTargets, .setUpFirebase, .moma, .restartDevServer,
             .deployFirebase, .lintApplet, .kiInsertion, .retrieveContent, .critique,
             .findings, .workspaceApi, .proposeAiComments, .startCodeReview, .generic,
             .setUpCloudSql, .executeNotebook, .cloudSqlUpdateSchema, .rpcAction,
             .cloudSqlExecuteSql, .directoryRules:
            .other
        case .unspecified, .dummy, .finish, .userInput, .plannerResponse,
             .errorMessage, .checkpoint, .suggestedResponses, .managerFeedback,
             .proposalFeedback, .taskBoundary, .notifyUser, .codeAcknowledgement,
             .ephemeralMessage, .conversationHistory, .systemMessage, .ciderAgentDummy,
             .askQuestion:
            nil
        }
    }

    /// `true` when this row is a tool call — something that opens and closes
    /// rather than something that is simply said.
    public var isTool: Bool { toolKind != nil }

    /// A display label for a raw column value, known or not.
    public static func label(rawValue: Int) -> String {
        AntigravityStepType(rawValue: rawValue)?.label ?? "step_\(rawValue)"
    }
}
