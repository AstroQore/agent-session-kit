import Foundation

/// Folds ``AgentEvent``s into a ``SessionSnapshot``.
///
/// Pure and total: `reduce` never throws, never blocks, never reads a clock
/// of its own, and never rejects an event. A transition the table below does
/// not describe is a no-op that still records the heartbeat — a live board
/// built on half-understood logs must degrade into "quiet" rather than into
/// "wrong".
///
/// ## Transition table
///
/// | Event | Effect |
/// | --- | --- |
/// | `sessionStarted` | `state = .idle`, `startedAt = ts`, `isAlive = true`, pending cleared, `endedAt = nil` |
/// | `identityUpdated` | merge the patch's non-`nil` fields |
/// | `userPrompt` | `turnCount += 1`, turn opens at `ts`, the brief records the instruction, `state = .thinking` unless blocked on a permission |
/// | `turnStarted` | same, but no `turnCount` bump if a prompt already opened this turn, and no brief |
/// | `thinking` | `.idle` becomes `.thinking`; every other state is kept |
/// | `assistantText` | as `thinking`, and the brief records the reply |
/// | `toolCallStarted` | record the call, `toolCallCount += 1`, state from the call's kind |
/// | `toolCallFinished` | drop the call, re-derive the state from what is still open |
/// | `permissionRequested` | record it, `state = .waitingPermission` |
/// | `permissionResolved` | drop it if the id matches, re-derive the state |
/// | `subagentStarted` | record the child, `state = .delegating` unless blocked |
/// | `subagentFinished` | drop the child, re-derive the state |
/// | `turnEnded` | close the turn, stamp the brief's `lastTurnEndedAt`, drop orphaned tool calls, keep children |
/// | `usage` | add the token deltas |
/// | `compaction`, `note`, `textBody` | heartbeat only |
/// | `sessionEnded` | `state = .ended(reason)`, `isAlive = false`, `endedAt = ts`, pending cleared |
/// | `liveness(false)` | `isAlive = false`; an un-ended session becomes `.ended(.processGone)` |
/// | `liveness(true)` | `isAlive = true`; `.ended(.processGone)` becomes `.idle` again |
///
/// Every event sets `lastEventAt = max(lastEventAt, event.timestamp)`.
///
/// ## Where the spec was silent, and what was chosen
///
/// These are the judgement calls. Each picks the reading that cannot invent
/// activity, because a board that under-reports is merely quiet while one
/// that over-reports sends a person to a terminal for nothing.
///
/// - **`ended` is sticky.** Once a session is `.ended`, no ordinary event
///   revives it. Counters, tokens, and `lastEventAt` still update — a
///   trailing `usage` record is real accounting — but only `sessionStarted`
///   (an explicit restart) or `liveness(alive: true)` after a
///   `.processGone` verdict can leave the state. Late-arriving transcript
///   lines from an exited process are history, not life.
/// - **`liveness(true)` only undoes `.processGone`.** A session whose log
///   said `exited` or `killed` stays ended even if a pid is reused; only the
///   verdict a probe *guessed* may be withdrawn by a probe.
/// - **Resurrection clears `endedAt`.** A session that is running again has
///   no end time; leaving the old one would make a duration meaningless.
/// - **`permissionResolved` matches on id.** A resolution for a different id
///   than the one on record is dropped rather than clearing the prompt: the
///   common way ids diverge is a second request superseding a first, and
///   clearing on any resolution would hide a prompt that is genuinely still
///   on screen.
/// - **`turnEnded` clears the open permission** as well as orphaned tool
///   calls. A turn cannot close while the harness is blocked on a prompt, so
///   an open permission at that point is an event we missed. Keeping it would
///   strand the row in `.waitingPermission` forever, which is the one wrong
///   answer that makes a person act.
/// - **A denied permission changes nothing but the pending set.** The state
///   is re-derived exactly as for an allow; the harness reports the refusal
///   as a failed tool call of its own, and pre-empting that would double-count.
/// - **`usage` does not fill in `identity.model`.** The token record names a
///   model, but identity changes travel in `identityUpdated` patches so that
///   there is one path for them; an adapter that wants the model recorded
///   emits both.
/// - **The first event sets `startedAt` if nothing has.** Tailing usually
///   begins mid-session and `sessionStarted` never arrives; an unknown start
///   time is less useful than an honest "first seen at".
/// - **`children` is cumulative, `pending.openChildren` is live.** A child
///   that finishes stays in the roster so the shape of a turn survives it.
/// - **The brief survives everything, including a restart.** A
///   `sessionStarted` for an ended session resets the state machine, but not
///   ``SessionSnapshot/brief``: the key is the same session, the transcript is
///   the same transcript, and the task the person assigned did not stop being
///   the task because the process came back. Only a prompt that ``SessionBrief``
///   accepts as an instruction moves any of its prompt fields — a slash-command
///   envelope still counts a turn, because the harness ran one, and still says
///   nothing about what was asked for.
public struct SessionStateReducer: Sendable {
    /// How long a session may claim to be working without saying anything
    /// before ``SessionSnapshot/isStale`` is set. Default 90 seconds — long
    /// enough for a slow build, short enough to notice a hung tail.
    public var staleAfter: TimeInterval

    /// Creates a reducer.
    public init(staleAfter: TimeInterval = 90) {
        self.staleAfter = staleAfter
    }

    /// The snapshot a session starts from: idle, alive, nothing counted.
    public static func initialSnapshot(identity: SessionIdentity) -> SessionSnapshot {
        SessionSnapshot(identity: identity)
    }

    /// Applies one event and returns the new snapshot.
    ///
    /// Never throws. Events for a session other than the snapshot's are
    /// applied anyway — the caller owns routing, and silently dropping them
    /// here would hide a routing bug behind a quiet board.
    public func reduce(_ snapshot: SessionSnapshot, event: AgentEvent) -> SessionSnapshot {
        var next = snapshot
        let ts = event.timestamp

        // Heartbeat first: every event the *source* produced, understood or
        // not, is evidence the session was alive at `ts`. A liveness verdict
        // is not — it comes from a probe, not the session, and counting it
        // would keep a hung session from ever reading as stale.
        if case .liveness = event.kind {
            // no heartbeat
        } else {
            next.lastEventAt = maxDate(next.lastEventAt, ts)
            next.pending.lastEventAt = next.lastEventAt
            if next.startedAt == nil { next.startedAt = ts }
        }

        switch event.kind {
        case .sessionStarted(let identity):
            let staleStart = snapshot.endedAt.map { ts <= $0 } ?? false
            if snapshot.startedAt != nil, !snapshot.state.isEnded || staleStart {
                // A `sessionStarted` for a live session already being tracked
                // — a source re-registered after a drop, or a seed identity
                // arriving after the tail already produced events. That is
                // new evidence about *who* the session is, not a restart:
                // merge the identity and leave state, pending, and clocks
                // alone. An *ended* session that starts again is a real
                // restart and falls through to the reset below — unless the
                // start is stamped before the end (a seed identity for a
                // source discovered after its process was seen to exit),
                // which is history, not a resurrection.
                if identity.key == next.identity.key {
                    next.identity = Self.merge(next.identity, with: identity)
                }
                break
            }
            if identity.key == next.identity.key {
                next.identity = identity
            }
            next.state = .idle
            next.isAlive = true
            next.startedAt = ts
            next.endedAt = nil
            next.pending.openToolCalls.removeAll()
            next.pending.openChildren.removeAll()
            next.pending.openPermission = nil
            next.pending.currentTurnStartedAt = nil

        case .identityUpdated(let patch):
            next.identity = patch.applied(to: next.identity)

        case .userPrompt(let preview):
            next.turnCount += 1
            next.pending.currentTurnStartedAt = ts
            next.brief.record(prompt: preview, at: ts)
            if !next.state.isEnded, next.pending.openPermission == nil {
                next.state = .thinking
            }

        case .turnStarted:
            if next.pending.currentTurnStartedAt == nil {
                next.turnCount += 1
                next.pending.currentTurnStartedAt = ts
            }
            if !next.state.isEnded, next.pending.openPermission == nil {
                next.state = .thinking
            }

        case .thinking:
            if case .idle = next.state {
                next.state = .thinking
            }

        case .assistantText(let preview):
            next.brief.record(reply: preview, at: ts)
            if case .idle = next.state {
                next.state = .thinking
            }

        case .toolCallStarted(let id, let name, let kind, let target):
            let call = PendingToolCall(id: id, name: name, kind: kind, target: target, startedAt: ts)
            next.pending.openToolCalls[id] = call
            next.toolCallCount += 1
            if !next.state.isEnded {
                next.state = next.pending.openPermission == nil
                    ? state(for: call, in: next.pending)
                    : waitingState(next.pending)
            }

        case .toolCallFinished(let id, _):
            next.pending.openToolCalls.removeValue(forKey: id)
            next.state = derivedState(next)

        case .permissionRequested(let id, let tool):
            next.pending.openPermission = PendingPermission(id: id, tool: tool)
            if !next.state.isEnded {
                next.state = .waitingPermission(tool: tool)
            }

        case .permissionResolved(let id, _):
            if next.pending.openPermission?.id == id {
                next.pending.openPermission = nil
                next.state = derivedState(next)
            }

        case .subagentStarted(let child, _, _):
            next.pending.openChildren.insert(child)
            if !next.children.contains(child) { next.children.append(child) }
            if !next.state.isEnded, next.pending.openPermission == nil {
                next.state = .delegating(children: next.pending.openChildren.count)
            }

        case .subagentFinished(let child):
            next.pending.openChildren.remove(child)
            next.state = derivedState(next)

        case .turnEnded:
            next.brief.recordTurnEnded(at: ts)
            next.pending.openToolCalls.removeAll()
            next.pending.openPermission = nil
            next.pending.currentTurnStartedAt = nil
            if !next.state.isEnded {
                next.state = next.pending.openChildren.isEmpty
                    ? .idle
                    : .delegating(children: next.pending.openChildren.count)
            }

        case .usage(_, let inputTokens, let outputTokens, let cachedTokens):
            next.tokensIn += inputTokens
            next.tokensOut += outputTokens
            next.tokensCached += cachedTokens

        case .compaction, .note, .textBody:
            break

        case .sessionEnded(let reason):
            next.state = .ended(reason: reason)
            next.isAlive = false
            next.endedAt = ts
            next.pending.openToolCalls.removeAll()
            next.pending.openChildren.removeAll()
            next.pending.openPermission = nil
            next.pending.currentTurnStartedAt = nil

        case .liveness(let alive):
            next.isAlive = alive
            if alive {
                if case .ended(let reason) = next.state, reason == .processGone {
                    next.state = .idle
                    next.endedAt = nil
                }
            } else if !next.state.isEnded {
                next.state = .ended(reason: .processGone)
                next.endedAt = ts
                next.pending.openToolCalls.removeAll()
                next.pending.openChildren.removeAll()
                next.pending.openPermission = nil
                next.pending.currentTurnStartedAt = nil
            }
        }

        return refreshStaleness(next, now: event.observedAt)
    }

    /// Recomputes ``SessionSnapshot/isStale`` against `now`, with no event.
    ///
    /// A UI calls this on its own tick: staleness is the one derived value
    /// that changes because time passed rather than because something
    /// happened, and a session that goes quiet mid-tool-call produces no
    /// event to notice it by.
    ///
    /// Stale means: alive, claiming to work (`thinking`, `toolCalling`, or
    /// `writingFile`), and silent for longer than ``staleAfter``. A session
    /// blocked on a permission is *not* stale — waiting is what it is
    /// supposed to be doing — and neither is one delegating to a child that
    /// is producing its own events.
    public func refreshStaleness(_ snapshot: SessionSnapshot, now: Date) -> SessionSnapshot {
        var next = snapshot
        next.isStale = isStale(next, now: now)
        return next
    }

    // MARK: - Derivation

    private func isStale(_ snapshot: SessionSnapshot, now: Date) -> Bool {
        guard snapshot.isAlive else { return false }
        switch snapshot.state {
        case .thinking, .toolCalling, .writingFile: break
        case .idle, .delegating, .waitingPermission, .ended: return false
        }
        guard let last = snapshot.lastEventAt else { return false }
        return now.timeIntervalSince(last) > staleAfter
    }

    /// The state implied by whatever is still open, in priority order:
    /// a person is waited on before a child, a child before a tool call, and
    /// an empty pending set means the model has the floor again.
    ///
    /// `thinking` rather than `idle` is the empty-set answer on purpose: a
    /// tool call finishing hands control back to the model, and only
    /// `turnEnded` or `sessionEnded` means nothing is coming.
    private func derivedState(_ snapshot: SessionSnapshot) -> SessionState {
        if snapshot.state.isEnded { return snapshot.state }
        let pending = snapshot.pending
        if pending.openPermission != nil { return waitingState(pending) }
        if !pending.openChildren.isEmpty { return .delegating(children: pending.openChildren.count) }
        if let call = pending.mostRecentOpenToolCall { return state(for: call, in: pending) }
        return .thinking
    }

    private func waitingState(_ pending: PendingSet) -> SessionState {
        .waitingPermission(tool: pending.openPermission?.tool)
    }

    private func state(for call: PendingToolCall, in pending: PendingSet) -> SessionState {
        switch call.kind {
        case .fileWrite:
            return .writingFile(path: call.target)
        case .subagent:
            // The spawn is observed before the child session is, so count at
            // least the one this call represents.
            return .delegating(children: max(pending.openChildren.count, 1))
        case .shell, .fileRead, .search, .web, .mcp, .plan, .other:
            return .toolCalling(name: call.name)
        }
    }

    /// `incoming`'s non-`nil` fields over `existing`'s. Discovery is fresher
    /// than whatever the tail said earlier about pid, parent, or cwd, but it
    /// knows nothing about a title a `custom-title` record set five minutes
    /// ago — so blanks in the incoming identity keep the old value.
    static func merge(_ existing: SessionIdentity, with incoming: SessionIdentity) -> SessionIdentity {
        var merged = existing
        merged.variant = incoming.variant ?? existing.variant
        merged.parent = incoming.parent ?? existing.parent
        merged.parentLink = incoming.parentLink ?? existing.parentLink
        merged.cwd = incoming.cwd ?? existing.cwd
        merged.gitRoot = incoming.gitRoot ?? existing.gitRoot
        merged.worktreePath = incoming.worktreePath ?? existing.worktreePath
        merged.gitBranch = incoming.gitBranch ?? existing.gitBranch
        merged.pid = incoming.pid ?? existing.pid
        merged.procStart = incoming.procStart ?? existing.procStart
        if !incoming.sourcePath.isEmpty { merged.sourcePath = incoming.sourcePath }
        merged.title = incoming.title ?? existing.title
        merged.model = incoming.model ?? existing.model
        merged.entrypoint = incoming.entrypoint ?? existing.entrypoint
        return merged
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return lhs > rhs ? lhs : rhs
    }
}
