import AgentSessionKit
import Foundation
import Testing

@testable import AgentSessionLive

// MARK: - Discovery

@Suite("GrokBotLiveAdapter discovery")
struct GrokBotLiveAdapterDiscoveryTests {
    private let adapter = GrokBotLiveAdapter()

    @Test("one source per transcript replica, named by the roster")
    func discoversReplicas() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [
            GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout"),
            GrokBotHome.rosterRow(id: GrokBotFixture.archivist, name: "Archivist")
        ])
        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.prompt(id: "p1", at: 1, text: "Summarise the release feed.")
        ])
        home.writeReplica(bot: GrokBotFixture.archivist, entries: [
            GrokBotEntryJSON.prompt(id: "p1", at: 1, text: "Index the archive.")
        ])
        // Client chrome under the same prefix, and a marker file that is not
        // base32 at all. Neither is a session.
        home.writeBlob(
            key: "sand.client.slice.account.\(GrokBotFixture.account).composer-drafts",
            json: #"{"schemaVersion":1,"value":{"drafts":{}}}"#
        )
        home.writeBlob(key: "sand.client.slice.ui-layout", json: #"{"value":{"sidebarWidth":320}}"#)
        try? Data().write(to: home.store.appendingPathComponent(".migrated-from-local-storage"))

        let sources = try await adapter.discover(home: home.home, activeSince: .distantPast)

        #expect(sources.map(\.key.sessionID) == [GrokBotFixture.scout, GrokBotFixture.archivist]
            .sorted())
        let scout = try #require(sources.first { $0.key.sessionID == GrokBotFixture.scout })
        #expect(scout.key.harness == .grokBot)
        #expect(scout.seedIdentity.title == "Scout")
        #expect(scout.seedIdentity.variant == GrokBotSessionAdapter.variant)
        #expect(scout.seedIdentity.entrypoint == GrokBotLiveAdapter.entrypoint)
        // A cloud conversation has no working directory and no model, and
        // inventing either would be wrong everywhere downstream.
        #expect(scout.seedIdentity.cwd == nil)
        #expect(scout.seedIdentity.model == nil)
        // The roster travels with the source: a change to it is a change to
        // this session.
        #expect(scout.auxiliaryPaths == [home.blobPath(key: GrokBotFixture.rosterKey()).path])
    }

    @Test("each account resolves its own roster")
    func rosterPerAccount() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        home.writeRoster(
            account: GrokBotFixture.otherAccount,
            rows: [GrokBotHome.rosterRow(id: GrokBotFixture.archivist, name: "Elsewhere")]
        )
        home.writeReplica(bot: GrokBotFixture.scout, entries: [])
        home.writeReplica(
            bot: GrokBotFixture.archivist,
            account: GrokBotFixture.otherAccount,
            entries: []
        )

        let sources = try await adapter.discover(home: home.home, activeSince: .distantPast)
        let titles = Dictionary(
            uniqueKeysWithValues: sources.map { ($0.key.sessionID, $0.seedIdentity.title) })
        #expect(titles[GrokBotFixture.scout] == "Scout")
        #expect(titles[GrokBotFixture.archivist] == "Elsewhere")
    }

    @Test("the cutoff drops a quiet conversation and keeps one that is blocked on a person")
    func cutoff() async throws {
        let home = GrokBotHome()
        let cutoff = Date().addingTimeInterval(-3600)
        home.writeRoster(rows: [
            GrokBotHome.rosterRow(
                id: GrokBotFixture.scout, name: "Scout", lastActivityAt: cutoff.addingTimeInterval(-86_400)),
            GrokBotHome.rosterRow(
                id: GrokBotFixture.archivist, name: "Archivist",
                lastActivityAt: cutoff.addingTimeInterval(-86_400), awaiting: true),
            GrokBotHome.rosterRow(
                id: GrokBotFixture.stranger, name: "Stranger",
                lastActivityAt: Date())
        ])
        for bot in [GrokBotFixture.scout, GrokBotFixture.archivist, GrokBotFixture.stranger] {
            let url = home.writeReplica(bot: bot, entries: [])
            home.touch(url, secondsAgo: 86_400)
        }

        let sources = try await adapter.discover(home: home.home, activeSince: cutoff)
        // Scout is quiet by both clocks. Archivist is just as quiet and is
        // waiting on somebody, which is the one row a board must not drop.
        // Stranger's blob is old but the roster says it moved a moment ago.
        #expect(Set(sources.map(\.key.sessionID))
            == [GrokBotFixture.archivist, GrokBotFixture.stranger])
    }

    @Test("a store that is not there is empty rather than an error")
    func missingStore() async throws {
        let tree = TemporaryTree()
        let sources = try await adapter.discover(home: tree.path, activeSince: .distantPast)
        #expect(sources.isEmpty)
        #expect(adapter.watchRoots(home: "/Users/example").map(\.path) == [
            "/Users/example/Library/Application Support/Grok Bot/sand-client-persistence"
        ])
    }

    @Test("only a transcript blob could be a session")
    func mightBeSessionFile() {
        let home = GrokBotHome()
        #expect(adapter.mightBeSessionFile(
            path: home.blobPath(key: GrokBotFixture.transcriptKey(bot: GrokBotFixture.scout)).path))
        // The roster is rewritten constantly. Treating each write as "a
        // conversation appeared" would run discovery in a loop.
        #expect(!adapter.mightBeSessionFile(path: home.blobPath(key: GrokBotFixture.rosterKey()).path))
        #expect(!adapter.mightBeSessionFile(path: home.store.appendingPathComponent("notes.txt").path))
        #expect(!adapter.mightBeSessionFile(path: "/Users/example/elsewhere/anything.blob"))
    }
}

// MARK: - Tailing

@Suite("GrokBotTranscriptTailer")
struct GrokBotTranscriptTailerTests {
    private let adapter = GrokBotLiveAdapter()

    /// Discovery, then a tailer for one bot — the path a host actually takes.
    private func tailer(
        _ home: GrokBotHome,
        bot: String = GrokBotFixture.scout,
        cursor: SourceCursor? = nil
    ) async throws -> GrokBotTranscriptTailer {
        let sources = try await adapter.discover(home: home.home, activeSince: .distantPast)
        let source = try #require(sources.first { $0.key.sessionID == bot })
        return try #require(adapter.makeTailer(source, cursor: cursor) as? GrokBotTranscriptTailer)
    }

    @Test("both entry vintages come out on the right side of the conversation")
    func vintages() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.prompt(id: "e1", at: 1, text: "Summarise the release feed."),
            GrokBotEntryJSON.sendMessage(id: "e2", at: 2, text: "Three releases landed."),
            GrokBotEntryJSON.inbound(id: "e3", at: 3, text: "Anything to file?", from: "Archivist"),
            GrokBotEntryJSON.outbound(id: "e4", at: 4, text: "Only the notes.", to: "Archivist"),
            GrokBotEntryJSON.renamed(id: "e5", at: 5, to: "Scout"),
            GrokBotEntryJSON.attachment(id: "e6", name: "notes.png"),
            GrokBotEntryJSON.sendPayload(id: "e7", at: 6, type: "widget"),
            GrokBotEntryJSON.unknownKind(id: "e8")
        ])

        let events = try await tailer(home).poll()

        // `send-message` is the bot answering the person, not the person
        // asking. Getting this backwards puts every reply on the wrong side.
        #expect(events.prompts == ["Summarise the release feed.", "Archivist: Anything to file?"])
        #expect(events.replies == ["Three releases landed.", "→ Archivist: Only the notes."])
        #expect(events.notes == ["renamed to Scout", "attachment: notes.png", "widget"])
        #expect(events.bodies.map(\.0) == [.user, .assistant, .user, .assistant])
        #expect(events.bodies.first?.1 == "Summarise the release feed.")
        // A `file_path` is a path on the person's own disk and never leaves
        // the file it was written in.
        #expect(!events.notes.contains { $0.contains("/Users/") })
        #expect(events.hasTurnEnded)
    }

    @Test("a poll that finds nothing changed reads nothing")
    func unchangedIsANoOp() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.prompt(id: "e1", at: 1, text: "Summarise the release feed."),
            GrokBotEntryJSON.sendMessage(id: "e2", at: 2, text: "Three releases landed.")
        ])
        let tailer = try await tailer(home)

        #expect(try await !tailer.poll().isEmpty)
        // The client rewrites this file on every step of a streaming reply,
        // so a quiet conversation has to cost two `stat` calls and no parse.
        #expect(try await tailer.poll().isEmpty)
        #expect(try await tailer.poll().isEmpty)
    }

    @Test("a streaming reply is thinking until the flag clears, then it is the words")
    func streaming() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.inbound(id: "e1", at: 1, text: "Anything to file?", from: "Archivist"),
            GrokBotEntryJSON.outbound(id: "e2", at: 2, text: "Only the", to: "Archivist", streaming: true)
        ])
        let tailer = try await tailer(home)

        let first = try await tailer.poll()
        #expect(first.hasThinking)
        // Half a sentence must not reach a board, because nothing would ever
        // correct it.
        #expect(first.replies.isEmpty)
        #expect(!first.hasTurnEnded)
        #expect(tailer.streamingCount == 1)

        // The client rewrites the file in place: same entry id, more text,
        // flag cleared.
        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.inbound(id: "e1", at: 1, text: "Anything to file?", from: "Archivist"),
            GrokBotEntryJSON.outbound(id: "e2", at: 2, text: "Only the release notes.", to: "Archivist")
        ])
        let second = try await tailer.poll()
        #expect(second.replies == ["→ Archivist: Only the release notes."])
        #expect(second.hasTurnEnded)
        #expect(tailer.streamingCount == 0)
        // And exactly once: the settled entry is not read again.
        #expect(try await tailer.poll().isEmpty)
    }

    @Test("a resumed tailer emits what arrived while it was away and not a word more")
    func resume() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.prompt(id: "e1", at: 1, text: "Summarise the release feed."),
            GrokBotEntryJSON.sendMessage(id: "e2", at: 2, text: "Three releases landed.")
        ])
        let first = try await tailer(home)
        _ = try await first.poll()
        #expect(first.cursor == .blobHead("e2"))

        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.prompt(id: "e1", at: 1, text: "Summarise the release feed."),
            GrokBotEntryJSON.sendMessage(id: "e2", at: 2, text: "Three releases landed."),
            GrokBotEntryJSON.prompt(id: "e3", at: 3, text: "And the week before?"),
            GrokBotEntryJSON.sendMessage(id: "e4", at: 4, text: "Nine, all patch.")
        ])
        let resumed = try await tailer(home, cursor: first.cursor)
        let events = try await resumed.poll()

        #expect(events.prompts == ["And the week before?"])
        #expect(events.replies == ["Nine, all patch."])
        #expect(resumed.cursor == .blobHead("e4"))
    }

    @Test("an anchor the file no longer holds is adopted rather than replayed")
    func lostAnchor() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.prompt(id: "e9", at: 9, text: "Only what is left."),
            GrokBotEntryJSON.sendMessage(id: "e10", at: 10, text: "Noted.")
        ])
        // The client trimmed its history: the entry the cursor named is gone.
        let resumed = try await tailer(home, cursor: .blobHead("e1"))
        let events = try await resumed.poll()

        #expect(events.prompts.isEmpty)
        #expect(events.replies.isEmpty)
        #expect(resumed.cursor == .blobHead("e10"))
    }

    @Test("a cursor of another shape re-seeds instead of failing")
    func foreignCursor() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.sendMessage(id: "e1", at: 1, text: "Noted.")
        ])
        let tailer = try await tailer(home, cursor: .byteOffset(inode: 7, offset: 512))
        #expect(try await tailer.poll().replies == ["Noted."])
    }

    @Test("a cold start reads the end of the conversation and leaves it settled")
    func seedFromTail() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        let entries = (1...40).map { index in
            index.isMultiple(of: 2)
                ? GrokBotEntryJSON.sendMessage(id: "e\(index)", at: Int64(index), text: "Reply \(index).")
                : GrokBotEntryJSON.prompt(id: "e\(index)", at: Int64(index), text: "Ask \(index).")
        }
        home.writeReplica(bot: GrokBotFixture.scout, entries: entries)
        let tailer = try await tailer(home)

        let seeded = try await tailer.seedFromTail(maxBytes: 8 * 1024)
        #expect(seeded.prompts.count == 4)
        #expect(seeded.replies.count == 4)
        #expect(seeded.prompts.first == "Ask 33.")
        #expect(tailer.cursor == .blobHead("e40"))
        // Replayed history is history: a conversation somebody abandoned
        // mid-question does not read as *thinking* a week later.
        #expect(seeded.hasTurnEnded)
    }

    @Test("a question with no answer yet leaves the turn open")
    func unansweredPromptKeepsTheTurnOpen() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.sendMessage(id: "e1", at: 1, text: "Anything else?"),
            GrokBotEntryJSON.prompt(id: "e2", at: 2, text: "Yes — the changelog.")
        ])
        let events = try await tailer(home).poll()

        #expect(events.prompts == ["Yes — the changelog."])
        #expect(!events.hasTurnEnded)

        var snapshot = SessionSnapshot(identity: SessionIdentity(
            key: GrokBotFixture.session(GrokBotFixture.scout), sourcePath: "/dev/null"))
        let reducer = SessionStateReducer()
        for event in events { snapshot = reducer.reduce(snapshot, event: event) }
        #expect(snapshot.state == .thinking)
    }

    @Test("a replica the client is halfway through writing is retried, not believed")
    func tornRead() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.sendMessage(id: "e1", at: 1, text: "Noted.")
        ])
        let tailer = try await tailer(home)
        _ = try await tailer.poll()

        home.writeBlob(
            key: GrokBotFixture.transcriptKey(bot: GrokBotFixture.scout),
            json: #"{"schemaVersion":1,"value":{"entries":[{"kind":"send-mes"#
        )
        await #expect(throws: GrokBotTranscriptTailer.Failure.self) { try await tailer.poll() }

        // The stamp was not recorded, so the next poll reads again rather
        // than treating the torn read as the truth.
        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.sendMessage(id: "e1", at: 1, text: "Noted."),
            GrokBotEntryJSON.sendMessage(id: "e2", at: 2, text: "And filed.")
        ])
        #expect(try await tailer.poll().replies == ["And filed."])
    }
}

// MARK: - The roster's "needs you" flag

@Suite("GrokBotLiveAdapter needs-you")
struct GrokBotNeedsYouTests {
    private let adapter = GrokBotLiveAdapter()

    @Test("awaitingUserResponse flips a session to waiting and back")
    func rosterFlip() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.sendMessage(id: "e1", at: 1, text: "Which branch should I read?")
        ])
        let sources = try await adapter.discover(home: home.home, activeSince: .distantPast)
        let source = try #require(sources.first)
        let tailer = try #require(
            adapter.makeTailer(source, cursor: nil) as? GrokBotTranscriptTailer)

        let reducer = SessionStateReducer()
        var snapshot = SessionSnapshot(identity: source.seedIdentity)
        for event in try await tailer.poll() { snapshot = reducer.reduce(snapshot, event: event) }
        #expect(snapshot.state == .idle)

        home.writeRoster(rows: [
            GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout", awaiting: true)
        ])
        let raised = try await tailer.poll()
        #expect(raised.kinds == [
            .permissionRequested(id: "grokbot:\(GrokBotFixture.scout)", tool: nil)
        ])
        for event in raised { snapshot = reducer.reduce(snapshot, event: event) }
        #expect(snapshot.state == .waitingPermission(tool: nil))

        home.writeRoster(rows: [
            GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout", awaiting: false)
        ])
        let cleared = try await tailer.poll()
        #expect(cleared.kinds == [
            .permissionResolved(id: "grokbot:\(GrokBotFixture.scout)", allowed: true)
        ])
        for event in cleared { snapshot = reducer.reduce(snapshot, event: event) }
        // The reducer hands the floor back to the model when a permission
        // clears, which is the right reading here too: the person answered
        // and the bot is about to say something. The answer itself lands in
        // the replica a moment later and closes the turn.
        #expect(snapshot.state == .thinking)

        home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.sendMessage(id: "e1", at: 1, text: "Which branch should I read?"),
            GrokBotEntryJSON.prompt(id: "e2", at: 2, text: "The release one."),
            GrokBotEntryJSON.sendMessage(id: "e3", at: 3, text: "Reading it now.")
        ])
        for event in try await tailer.poll() { snapshot = reducer.reduce(snapshot, event: event) }
        #expect(snapshot.state == .idle)
    }

    @Test("a rename in the roster becomes an identity patch, and only once")
    func renameIsAnIdentityPatch() async throws {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Watcher")])
        home.writeReplica(bot: GrokBotFixture.scout, entries: [])
        let sources = try await adapter.discover(home: home.home, activeSince: .distantPast)
        let source = try #require(sources.first)
        let tailer = try #require(
            adapter.makeTailer(source, cursor: nil) as? GrokBotTranscriptTailer)

        // Discovery already reported "Watcher" on the seed identity, so the
        // first poll has nothing to add.
        #expect(try await tailer.poll().isEmpty)

        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        let renamed = try await tailer.poll()
        #expect(renamed.kinds == [.identityUpdated(SessionIdentityPatch(title: "Scout"))])
        #expect(try await tailer.poll().isEmpty)
    }
}

// MARK: - Liveness

@Suite("GrokBotLiveAdapter liveness")
struct GrokBotLivenessTests {
    private let clientPath = "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot"

    private func client(pid: pid_t = 4711) -> ProcessRecord {
        ProcessRecord(
            pid: pid, ppid: 1, startTime: Date().addingTimeInterval(-600),
            executablePath: clientPath, argv: [clientPath])
    }

    /// An Electron helper. Up on its own it is not the app the person sees.
    private func helper(pid: pid_t = 4712) -> ProcessRecord {
        let path = "/Applications/Grok Bot.app/Contents/Frameworks/"
            + "Grok Bot Helper.app/Contents/MacOS/Grok Bot Helper"
        return ProcessRecord(
            pid: pid, ppid: 4711, startTime: Date().addingTimeInterval(-600),
            executablePath: path, argv: [path])
    }

    private func identity(_ home: GrokBotHome, sourcePath: String) -> SessionIdentity {
        SessionIdentity(
            key: GrokBotFixture.session(GrokBotFixture.scout), sourcePath: sourcePath)
    }

    private func fixture() -> (GrokBotHome, String) {
        let home = GrokBotHome()
        home.writeRoster(rows: [GrokBotHome.rosterRow(id: GrokBotFixture.scout, name: "Scout")])
        let url = home.writeReplica(bot: GrokBotFixture.scout, entries: [
            GrokBotEntryJSON.sendMessage(id: "e1", at: 1, text: "Noted.")
        ])
        return (home, url.path)
    }

    @Test("a running client and a fresh replica is alive, with the client's pid")
    func alive() {
        let (home, path) = fixture()
        let adapter = GrokBotLiveAdapter()
        let hint = adapter.probeLiveness(
            identity(home, sourcePath: path),
            table: FakeProcessTable(records: [client(), helper()]),
            home: home.home
        )
        #expect(hint.verdict == .alive)
        #expect(hint.pid == 4711)
    }

    @Test("no client and no heartbeat ends every conversation at once")
    func processGone() {
        let (home, path) = fixture()
        let adapter = GrokBotLiveAdapter()
        // A helper on its own is not the app: those come and go.
        let hint = adapter.probeLiveness(
            identity(home, sourcePath: path),
            table: FakeProcessTable(records: [helper()]),
            home: home.home
        )
        #expect(hint.verdict == .dead)
        #expect(hint.evidence.contains("not running"))
    }

    @Test("a fresh supervisor heartbeat stands in for a client the table did not name")
    func heartbeat() {
        let (home, path) = fixture()
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        try? FileManager.default.createDirectory(
            at: GrokBotStore.daemonRoot(home: home.home), withIntermediateDirectories: true)
        try? Data(#"{"pid":4242,"at":\#(at)}"#.utf8)
            .write(to: URL(fileURLWithPath: GrokBotStore.supervisorPath(home: home.home)))

        let adapter = GrokBotLiveAdapter()
        let hint = adapter.probeLiveness(
            identity(home, sourcePath: path),
            table: FakeProcessTable(records: []),
            home: home.home
        )
        #expect(hint.verdict == .alive)
        #expect(hint.evidence.contains("heartbeat"))
    }

    @Test("a quiet conversation under a running client is idle, never ended")
    func quietIsNotDead() {
        let (home, path) = fixture()
        home.touch(URL(fileURLWithPath: path), secondsAgo: 4 * 3600)
        let adapter = GrokBotLiveAdapter()
        let hint = adapter.probeLiveness(
            identity(home, sourcePath: path),
            table: FakeProcessTable(records: [client()]),
            home: home.home
        )
        // The conversation is on xAI's servers. It did not end because
        // nobody spoke to it this afternoon.
        #expect(hint.verdict == .unknown)
        #expect(hint.evidence.contains("quiet"))
    }

    @Test("the supervisor's neighbours are never opened")
    func credentialsAreNotRead() {
        let home = GrokBotHome()
        // Named exactly as the client names them. Nothing in this package
        // reads either, and the heartbeat reader must not fall back to one.
        let daemon = GrokBotStore.daemonRoot(home: home.home)
        try? FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
        for name in ["local-exec-daemon-connection.json", "local-exec-daemon-credential.json"] {
            try? Data(#"{"token":"NEVER-READ"}"#.utf8)
                .write(to: daemon.appendingPathComponent(name))
        }
        #expect(GrokBotStore.heartbeat(home: home.home) == nil)
        // And the watch never subscribes to that directory either.
        #expect(!GrokBotLiveAdapter().watchRoots(home: home.home)
            .contains { $0.path.contains(GrokBotStore.daemonDirectory) })
    }
}
