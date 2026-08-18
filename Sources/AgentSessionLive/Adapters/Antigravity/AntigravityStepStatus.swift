import Foundation

/// AntiGravity's `steps.status` — the lifecycle of one row.
///
/// The important thing about this column is that it *mutates in place*. A
/// conversation database is not an append-only log: a tool call is one row
/// whose `status` walks `PENDING → RUNNING → DONE`, and a model reply is one
/// row that sits at `GENERATING` until it lands on `DONE`. That is why the
/// tailer diffs rows instead of only reading new ones, and why this enum has
/// to distinguish "still going" from "finished" precisely.
///
/// Decoded from the `agy` binary's embedded `FileDescriptorProto`
/// (`CORTEX_STEP_STATUS_*`, 2026-08-19). Complete for that build: value `10`
/// genuinely does not exist.
public enum AntigravityStepStatus: Int, Sendable, Hashable, CaseIterable, Codable {
    /// `CORTEX_STEP_STATUS_UNSPECIFIED`
    case unspecified = 0
    /// `CORTEX_STEP_STATUS_PENDING` — accepted, not started.
    case pending = 1
    /// `CORTEX_STEP_STATUS_RUNNING` — a tool is in flight.
    case running = 2
    /// `CORTEX_STEP_STATUS_DONE`
    case done = 3
    /// `CORTEX_STEP_STATUS_INVALID`
    case invalid = 4
    /// `CORTEX_STEP_STATUS_CLEARED` — dropped from the trajectory.
    case cleared = 5
    /// `CORTEX_STEP_STATUS_CANCELED`
    case canceled = 6
    /// `CORTEX_STEP_STATUS_ERROR` — see the row's `error_details` blob.
    case error = 7
    /// `CORTEX_STEP_STATUS_GENERATING` — the model is streaming into this row.
    case generating = 8
    /// `CORTEX_STEP_STATUS_WAITING` — blocked on a person: an approval, an
    /// answer, a choice.
    case waiting = 9
    /// `CORTEX_STEP_STATUS_QUEUED`
    case queued = 11
    /// `CORTEX_STEP_STATUS_INTERRUPTED`
    case interrupted = 12

    /// The descriptor's own name, lower-cased.
    public var label: String {
        switch self {
        case .unspecified: "unspecified"
        case .pending: "pending"
        case .running: "running"
        case .done: "done"
        case .invalid: "invalid"
        case .cleared: "cleared"
        case .canceled: "canceled"
        case .error: "error"
        case .generating: "generating"
        case .waiting: "waiting"
        case .queued: "queued"
        case .interrupted: "interrupted"
        }
    }

    /// `true` once the row will not change again: the call returned, the
    /// reply landed, or the step was abandoned.
    ///
    /// `unspecified` counts as terminal. A row that never carried a status at
    /// all is not a row anybody is waiting on, and treating it as open would
    /// leave a tool call forever in flight.
    public var isTerminal: Bool {
        switch self {
        case .done, .invalid, .cleared, .canceled, .error, .interrupted, .unspecified: true
        case .pending, .running, .queued, .generating, .waiting: false
        }
    }

    /// `true` while the row is still going — the complement of
    /// ``isTerminal``.
    public var isOpen: Bool { !isTerminal }

    /// `true` when the row ended badly.
    public var isFailure: Bool {
        switch self {
        case .error, .invalid: true
        default: false
        }
    }
}

/// Who caused a step, from `step_payload.5.3`.
///
/// Decoded from `CORTEX_STEP_SOURCE_*` in the `agy` binary's embedded
/// `FileDescriptorProto`, 2026-08-19. Value `1` genuinely does not exist.
public enum AntigravityStepSource: Int, Sendable, Hashable, CaseIterable, Codable {
    /// `CORTEX_STEP_SOURCE_UNSPECIFIED`
    case unspecified = 0
    /// `CORTEX_STEP_SOURCE_MODEL` — the model asked for it.
    case model = 2
    /// `CORTEX_STEP_SOURCE_USER_IMPLICIT` — a consequence of what a person
    /// did, not something they typed.
    case userImplicit = 3
    /// `CORTEX_STEP_SOURCE_USER_EXPLICIT` — a person typed it.
    case userExplicit = 4
    /// `CORTEX_STEP_SOURCE_SYSTEM`
    case system = 5
    /// `CORTEX_STEP_SOURCE_SYSTEM_SDK`
    case systemSDK = 6

    /// The descriptor's own name, lower-cased.
    public var label: String {
        switch self {
        case .unspecified: "unspecified"
        case .model: "model"
        case .userImplicit: "user_implicit"
        case .userExplicit: "user_explicit"
        case .system: "system"
        case .systemSDK: "system_sdk"
        }
    }
}

/// `trajectory_meta.source` — which AntiGravity surface opened the
/// conversation.
///
/// The one value worth acting on is ``subagent``: a trajectory with that
/// source was spawned by another conversation, and its parent is named in the
/// summaries store rather than anywhere in its own database.
///
/// Decoded from `CORTEX_TRAJECTORY_SOURCE_*` in the `agy` binary's embedded
/// `FileDescriptorProto`, 2026-08-19. Values `11` and `14` genuinely do not
/// exist.
public enum AntigravityTrajectorySource: Int, Sendable, Hashable, CaseIterable, Codable {
    case unspecified = 0
    case cascadeClient = 1
    case explainProblem = 2
    case refactorFunction = 3
    case eval = 4
    case evalTask = 5
    case asyncPRR = 6
    case asyncCF = 7
    case asyncSL = 8
    case asyncPRD = 9
    case asyncCM = 10
    case interactiveCascade = 12
    case replay = 13
    case sdk = 15
    case subagent = 16
    /// `CORTEX_TRAJECTORY_SOURCE_CLI` — the `agy` command line.
    case cli = 17
    case jetbox = 18
    case agentAPI = 19

    /// The descriptor's own name, lower-cased.
    public var label: String {
        switch self {
        case .unspecified: "unspecified"
        case .cascadeClient: "cascade_client"
        case .explainProblem: "explain_problem"
        case .refactorFunction: "refactor_function"
        case .eval: "eval"
        case .evalTask: "eval_task"
        case .asyncPRR: "async_prr"
        case .asyncCF: "async_cf"
        case .asyncSL: "async_sl"
        case .asyncPRD: "async_prd"
        case .asyncCM: "async_cm"
        case .interactiveCascade: "interactive_cascade"
        case .replay: "replay"
        case .sdk: "sdk"
        case .subagent: "subagent"
        case .cli: "cli"
        case .jetbox: "jetbox"
        case .agentAPI: "agent_api"
        }
    }
}

/// `trajectory_meta.trajectory_type` — what kind of trajectory the rows
/// belong to.
///
/// Decoded from `CORTEX_TRAJECTORY_TYPE_*` in the `agy` binary's embedded
/// `FileDescriptorProto`, 2026-08-19.
public enum AntigravityTrajectoryType: Int, Sendable, Hashable, CaseIterable, Codable {
    case unspecified = 0
    case userMainline = 1
    case userGranular = 2
    case supercomplete = 3
    /// `CORTEX_TRAJECTORY_TYPE_CASCADE` — the whole-conversation trajectory
    /// every `agy` run writes.
    case cascade = 4
    case checkpoint = 6
    case applier = 11
    case toolCallProposal = 12
    case trajectoryChoice = 13
    case llmJudge = 14
    case brainUpdate = 16
    case interactiveCascade = 17
    case browser = 20
    case knowledgeGeneration = 21
    case sideQuestion = 22
    case commitMessageGeneration = 23

    /// The descriptor's own name, lower-cased.
    public var label: String {
        switch self {
        case .unspecified: "unspecified"
        case .userMainline: "user_mainline"
        case .userGranular: "user_granular"
        case .supercomplete: "supercomplete"
        case .cascade: "cascade"
        case .checkpoint: "checkpoint"
        case .applier: "applier"
        case .toolCallProposal: "tool_call_proposal"
        case .trajectoryChoice: "trajectory_choice"
        case .llmJudge: "llm_judge"
        case .brainUpdate: "brain_update"
        case .interactiveCascade: "interactive_cascade"
        case .browser: "browser"
        case .knowledgeGeneration: "knowledge_generation"
        case .sideQuestion: "side_question"
        case .commitMessageGeneration: "commit_message_generation"
        }
    }
}
