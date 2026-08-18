import AgentSessionKit
import Foundation
import Testing
@testable import AgentSessionLive

@Suite("JSONLTailer")
struct JSONLTailerTests {
    private let key = SessionKey(harness: .claudeCode, sessionID: "tailer-fixture")

    private func makeTailer(
        _ tree: TemporaryTree,
        file name: String = "session.jsonl",
        cursor: SourceCursor? = nil
    ) -> JSONLTailer {
        let path = tree.file(name).path
        let source = SessionSource(
            key: key,
            primaryPath: path,
            seedIdentity: SessionIdentity(key: key, sourcePath: path)
        )
        return JSONLTailer(source: source, cursor: cursor, decode: fixtureDecoder(key: key))
    }

    private func offset(_ cursor: SourceCursor) -> Int64? {
        guard case let .byteOffset(_, offset) = cursor else { return nil }
        return offset
    }

    private func inode(_ cursor: SourceCursor) -> UInt64? {
        guard case let .byteOffset(inode, _) = cursor else { return nil }
        return inode
    }

    @Test("appended lines come back once, with the cursor at the end of the last one")
    func appendedLines() throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("one") + fixtureLine("two") + fixtureLine("three"), to: "session.jsonl")
        let tailer = makeTailer(tree)

        let events = try tailer.poll()
        #expect(events.count == 3)
        #expect(events.map(noteText) == ["one", "two", "three"])
        #expect(events.map(\.sequence) == [1, 2, 3])

        let size = FileStamp.read(path: tree.file("session.jsonl").path)?.size
        #expect(offset(tailer.cursor) == size)
        #expect(inode(tailer.cursor) == tree.inode(of: "session.jsonl"))

        // A second poll with nothing appended is empty and does not rewind.
        #expect(try tailer.poll().isEmpty)
        #expect(offset(tailer.cursor) == size)
    }

    @Test("every decoded event carries a RawRef the decoder did not supply")
    func rawReferences() throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("one") + fixtureLine("two"), to: "session.jsonl")
        let tailer = makeTailer(tree)

        let events = try tailer.poll()
        #expect(events.count == 2)
        #expect(events[0].raw?.byteOffset == 0)
        #expect(events[0].raw?.lineNumber == 1)
        #expect(events[1].raw?.byteOffset == Int64(fixtureLine("one").utf8.count))
        #expect(events[1].raw?.lineNumber == 2)
        #expect(events.allSatisfy { $0.raw?.path == tree.file("session.jsonl").path })
    }

    @Test("a half-written line waits for its newline")
    func partialLine() throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("first"), to: "session.jsonl")
        let tailer = makeTailer(tree)
        #expect(try tailer.poll().count == 1)

        let boundary = offset(tailer.cursor)
        tree.append(#"{"text":"sec"#, to: "session.jsonl")
        #expect(try tailer.poll().isEmpty)
        // The cursor stayed in front of the fragment, so a host that
        // persisted it here resumes at a record boundary.
        #expect(offset(tailer.cursor) == boundary)

        tree.append("ond\"}\n", to: "session.jsonl")
        let completed = try tailer.poll()
        #expect(completed.map(noteText) == ["second"])
        #expect(offset(tailer.cursor) == FileStamp.read(path: tree.file("session.jsonl").path)?.size)
    }

    @Test("truncating and rewriting the same file resets the cursor")
    func truncationResets() throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("one") + fixtureLine("two") + fixtureLine("three"), to: "session.jsonl")
        let tailer = makeTailer(tree)
        #expect(try tailer.poll().count == 3)
        let inodeBefore = inode(tailer.cursor)

        // Rewrite in place: same inode, smaller file.
        tree.write(fixtureLine("fresh"), to: "session.jsonl")
        #expect(tree.inode(of: "session.jsonl") == inodeBefore)

        let events = try tailer.poll()
        #expect(events.map(noteText) == ["fresh"])
        #expect(offset(tailer.cursor) == Int64(fixtureLine("fresh").utf8.count))
    }

    @Test("a rotated file — new inode, same path — is read from the start")
    func rotationResets() throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("old"), to: "session.jsonl")
        let tailer = makeTailer(tree)
        #expect(try tailer.poll().count == 1)
        let inodeBefore = inode(tailer.cursor)

        try FileManager.default.removeItem(at: tree.file("session.jsonl"))
        // Longer than the old file, so only the inode check can catch this.
        tree.write(fixtureLine("rotated-one") + fixtureLine("rotated-two"), to: "session.jsonl")
        let inodeAfter = tree.inode(of: "session.jsonl")
        try #require(inodeAfter != inodeBefore)

        let events = try tailer.poll()
        #expect(events.map(noteText) == ["rotated-one", "rotated-two"])
        #expect(inode(tailer.cursor) == inodeAfter)
    }

    @Test("seeding from the tail reads only the end of a large file")
    func seedFromTail() throws {
        let tree = TemporaryTree()
        var contents = ""
        for index in 0..<600 { contents += fixtureLine("line-\(index)") }
        tree.write(contents, to: "session.jsonl")
        let size = try #require(FileStamp.read(path: tree.file("session.jsonl").path)?.size)
        try #require(size > 10_000)

        let tailer = makeTailer(tree)
        let seeded = try tailer.seedFromTail(maxBytes: 100)

        // A 100-byte window over 20-byte lines holds a handful of them, and
        // the first one in the window is a fragment that must be dropped.
        #expect(!seeded.isEmpty)
        #expect(seeded.count < 8)
        #expect(noteText(seeded.last!) == "line-599")
        for event in seeded {
            let text = try #require(noteText(event))
            #expect(text.hasPrefix("line-59"))
        }
        #expect(offset(tailer.cursor) == size)

        // Everything appended after the seed still arrives.
        tree.append(fixtureLine("after-seed"), to: "session.jsonl")
        #expect(try tailer.poll().map(noteText) == ["after-seed"])
    }

    @Test("seeding a file smaller than the window keeps every line")
    func seedSmallFile() throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("a") + fixtureLine("b"), to: "session.jsonl")
        let tailer = makeTailer(tree)
        #expect(try tailer.seedFromTail(maxBytes: 64 * 1024).map(noteText) == ["a", "b"])
    }

    @Test("a garbage line is skipped without stopping the walk")
    func garbageLineSkipped() throws {
        let tree = TemporaryTree()
        var contents = fixtureLine("before")
        contents += "this is not json at all\n"
        contents += "{\"unexpected\":true}\n"
        contents += "\n"
        contents += fixtureLine("after")
        tree.write(contents, to: "session.jsonl")

        let tailer = makeTailer(tree)
        let events = try tailer.poll()
        #expect(events.map(noteText) == ["before", "after"])
        #expect(events.map(\.sequence) == [1, 2])
        #expect(offset(tailer.cursor) == Int64(contents.utf8.count))
    }

    @Test("non-UTF-8 bytes on a line are skipped, not fatal")
    func invalidUTF8Skipped() throws {
        let tree = TemporaryTree()
        var bytes = Data(fixtureLine("clean").utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, 0x80, 0x0A])
        bytes.append(contentsOf: Data(fixtureLine("also-clean").utf8))
        try bytes.write(to: tree.file("session.jsonl"))

        let tailer = makeTailer(tree)
        #expect(try tailer.poll().map(noteText) == ["clean", "also-clean"])
    }

    @Test("a file that is not there yields nothing and keeps its cursor")
    func missingFile() throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("one"), to: "session.jsonl")
        let tailer = makeTailer(tree)
        #expect(try tailer.poll().count == 1)
        let before = tailer.cursor

        try FileManager.default.removeItem(at: tree.file("session.jsonl"))
        #expect(try tailer.poll().isEmpty)
        #expect(tailer.cursor == before)

        // Seeding a missing file is equally quiet.
        #expect(try tailer.seedFromTail(maxBytes: 1024).isEmpty)
        #expect(tailer.cursor == before)
    }

    @Test("a persisted cursor resumes instead of replaying")
    func resumeFromCursor() throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("one") + fixtureLine("two"), to: "session.jsonl")
        let first = makeTailer(tree)
        #expect(try first.poll().count == 2)
        let saved = first.cursor

        tree.append(fixtureLine("three"), to: "session.jsonl")
        let second = makeTailer(tree, cursor: saved)
        #expect(try second.poll().map(noteText) == ["three"])
    }

    @Test("a cursor of the wrong shape is discarded rather than rejected")
    func foreignCursorShape() throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("one"), to: "session.jsonl")
        let tailer = makeTailer(tree, cursor: .rowID(99))
        #expect(try tailer.poll().map(noteText) == ["one"])
    }

    @Test("a composite cursor is looked up by this tailer's own path")
    func compositeCursor() throws {
        let tree = TemporaryTree()
        tree.write(fixtureLine("one") + fixtureLine("two"), to: "session.jsonl")
        let path = tree.file("session.jsonl").path
        let warm = makeTailer(tree)
        #expect(try warm.poll().count == 2)

        let composite = SourceCursor.composite([path: warm.cursor, "/elsewhere": .rowID(3)])
        tree.append(fixtureLine("three"), to: "session.jsonl")
        let resumed = makeTailer(tree, cursor: composite)
        #expect(try resumed.poll().map(noteText) == ["three"])
    }

    @Test("a line larger than one read chunk survives the buffer compaction")
    func lineLargerThanChunk() throws {
        let tree = TemporaryTree()
        let long = String(repeating: "x", count: JSONLTailer.chunkSize * 2 + 17)
        tree.write(fixtureLine("small") + fixtureLine(long) + fixtureLine("tail"), to: "session.jsonl")

        let tailer = makeTailer(tree)
        let events = try tailer.poll()
        #expect(events.count == 3)
        #expect(noteText(events[1])?.count == long.count)
        #expect(noteText(events[2]) == "tail")
    }
}
