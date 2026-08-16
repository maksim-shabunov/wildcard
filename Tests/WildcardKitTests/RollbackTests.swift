import Foundation
import Testing
@testable import WildcardKit

/// Undo has to name the change it is undoing, and go on naming it after a trip
/// through JSON and another process.
///
/// The bug these exist to prevent is silent: a rollback that identifies its
/// history entry by title marks whichever entry happens to share that text, so
/// the wrong one is struck off as undone and the real one quietly loses its
/// Undo button. Nothing errors, and the record ends up describing something
/// that never happened.
@Suite("Rollback identity")
struct RollbackTests {

    private func engine() -> AssociationEngine {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wildcard-rollback-\(UUID().uuidString)")
            .appendingPathComponent("store.json")
        return AssociationEngine(catalog: TypeCatalog(), store: Store(url: url))
    }

    /// An applied change, with the one result that makes it reversible.
    private func entry(id: String, title: String, ext: String = "kt") -> HistoryEntry {
        let target = Target.fileType(ext: ext)
        return HistoryEntry(
            id: id,
            title: title,
            source: .gui,
            items: [ChangeItem(
                target: target,
                fromApp: AppRef(id: "dev.warp.warp-stable", name: "Warp"),
                fromOrigin: .explicit,
                toApp: AppRef(id: "com.example.cursor", name: "Cursor"),
                isNoOp: false)],
            results: [ApplyResult(target: target, outcome: .applied)])
    }

    @Test("an undo carries the id of the change it reverses")
    func carriesHistoryID() throws {
        let proposal = try #require(
            engine().makeRollbackProposal(for: entry(id: "abc12345", title: "Code → Cursor")))

        #expect(proposal.rollbackOf == "abc12345")
        #expect(proposal.source == .rollback)
    }

    /// The regression itself. Two applies with the same title is ordinary — the
    /// same rule applied twice in a week produces it — and the titles of the two
    /// undo proposals are then character-for-character identical.
    @Test("two changes with the same title are told apart")
    func identicalTitlesAreDistinguished() throws {
        let engine = engine()
        let first = entry(id: "1111aaaa", title: "Code → Cursor")
        let second = entry(id: "2222bbbb", title: "Code → Cursor", ext: "rs")

        let undoFirst = try #require(engine.makeRollbackProposal(for: first))
        let undoSecond = try #require(engine.makeRollbackProposal(for: second))

        #expect(undoFirst.title == undoSecond.title, "the titles really are the same")
        #expect(undoFirst.rollbackOf == "1111aaaa")
        #expect(undoSecond.rollbackOf == "2222bbbb")
    }

    /// The window reads the proposal back out of the queue, not out of the
    /// memory that built it, so the link has to survive being written down.
    @Test("the link survives the queue")
    func survivesEncoding() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wildcard-rollback-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let proposal = try #require(
            engine().makeRollbackProposal(for: entry(id: "cafe0001", title: "Code → Cursor")))
        try ProposalQueue(directory: dir).write(proposal)

        let read = try #require(ProposalQueue(directory: dir).get(proposal.id))
        #expect(read.rollbackOf == "cafe0001")
    }

    /// A proposal written before this field existed still decodes; it simply has
    /// no entry to strike off. Anyone with a queue directory from an older build
    /// would otherwise find every request in it unreadable.
    @Test("a proposal without the field still decodes")
    func decodesWithoutField() throws {
        let json = """
        {"id":"old00001","title":"Code → Cursor","source":{"gui":{}},"items":[],
         "warnings":[],"status":"awaiting_approval","createdAt":"2026-01-01T00:00:00Z",
         "expiresAt":"2099-01-01T00:00:00Z","results":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let proposal = try decoder.decode(Proposal.self, from: Data(json.utf8))

        #expect(proposal.id == "old00001")
        #expect(proposal.rollbackOf == nil)
    }

    /// Restoring a snapshot that names an application since uninstalled would
    /// bind the type to nothing at all. LaunchServices accepts the write, so the
    /// only place this can be caught is before it.
    @Test("restoring onto a missing application says so first")
    func missingAppIsWarned() {
        let engine = engine()
        let snapshot = Snapshot(
            name: "Last week",
            isAutomatic: false,
            bindings: ["ext:wcselftestmissing": "com.example.definitely.not.installed"])

        let proposal = engine.makeRestoreProposal(for: snapshot)
        let warning = proposal.warnings.first { $0.kind == .missingApp }

        #expect(warning != nil, "a snapshot naming an uninstalled app must warn")
        #expect(warning?.targets.contains(.fileType(ext: "wcselftestmissing")) == true)
    }
}
