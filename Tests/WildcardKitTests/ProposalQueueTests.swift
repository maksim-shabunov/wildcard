import Foundation
import Testing
@testable import WildcardKit

/// The queue is a directory of files that another process writes into. The
/// failure being guarded against here is the quiet one: a request lands, cannot
/// be read, is skipped, and the window shows an empty queue to someone an agent
/// has just told to go and approve something.
@Suite("Proposal queue")
struct ProposalQueueTests {

    private func makeQueue() throws -> (ProposalQueue, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wildcard-queue-\(UUID().uuidString)")
        return (ProposalQueue(directory: dir), dir)
    }

    private func proposal(_ id: String) -> Proposal {
        Proposal(
            id: id,
            title: "Code files open with Cursor",
            source: .mcp(client: "Claude Code"),
            items: [ChangeItem(
                target: .fileType(ext: "kt"),
                fromApp: AppRef(id: "dev.warp.warp-stable", name: "Warp"),
                fromOrigin: .implicit,
                toApp: AppRef(id: "com.example.cursor", name: "Cursor"),
                isNoOp: false)])
    }

    @Test("a request written by another process reads back whole")
    func roundTrip() throws {
        let (queue, dir) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        try queue.write(proposal("aaaa1111"))

        let read = try #require(ProposalQueue(directory: dir).get("aaaa1111"))
        #expect(read.title == "Code files open with Cursor")
        #expect(read.source == .mcp(client: "Claude Code"))
        #expect(read.effectiveItems.count == 1)
        #expect(ProposalQueue(directory: dir).awaitingApproval().map(\.id) == ["aaaa1111"])
    }

    @Test("a file that cannot be read is reported, not skipped")
    func unreadableIsReported() throws {
        let (queue, dir) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        try queue.write(proposal("good0001"))
        // Exactly what a half-finished write looks like: the file exists, and
        // there is no JSON in it yet.
        try Data("{\"id\": \"half".utf8).write(to: dir.appendingPathComponent("bad00001.json"))

        let contents = queue.contents()
        #expect(contents.proposals.map(\.id) == ["good0001"], "the good one still comes through")
        #expect(contents.unreadable == ["bad00001.json"], "and the bad one is named rather than dropped")
    }

    @Test("an unreadable file does not hide the requests around it")
    func unreadableDoesNotBlockApproval() throws {
        let (queue, dir) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("not json at all".utf8).write(to: dir.appendingPathComponent("bad00002.json"))
        try queue.write(proposal("good0002"))

        #expect(queue.awaitingApproval().map(\.id) == ["good0002"])
        #expect(queue.unreadableFiles() == ["bad00002.json"])
    }

    @Test("an expired request stops being offered for approval")
    func expiryIsHonoured() throws {
        let (queue, dir) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        var stale = proposal("old00001")
        stale.createdAt = Date(timeIntervalSinceNow: -1_200)
        stale.expiresAt = Date(timeIntervalSinceNow: -600)
        try queue.write(stale)

        #expect(queue.awaitingApproval().isEmpty)
        // And the file is left saying so, rather than being deleted behind
        // someone's back — an agent polling for it gets an answer.
        #expect(queue.get("old00001")?.status == .expired)
    }
}
