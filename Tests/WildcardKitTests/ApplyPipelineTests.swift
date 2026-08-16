import Foundation
import Testing
@testable import WildcardKit

/// Exercises the real write path against the real LaunchServices database.
///
/// It is off unless `WILDCARD_LIVE_TESTS=1` is set, because it genuinely changes
/// this Mac's file associations. It only ever touches invented extensions that
/// nothing on earth uses (`.wcselftest…`), and it puts every one of them back —
/// including on failure — so a normal `swift test` stays inert and a live run
/// leaves nothing behind.
///
///     WILDCARD_LIVE_TESTS=1 swift test --filter ApplyPipeline
@Suite("Apply pipeline", .enabled(if: ProcessInfo.processInfo.environment["WILDCARD_LIVE_TESTS"] == "1"))
struct ApplyPipelineTests {

    /// Junk extensions, so a mistake here cannot cost anyone a real association.
    static let ext1 = "wcselftest1"
    static let ext2 = "wcselftest2"
    static let scheme = "wcselftest"

    private func makeEngine() throws -> (AssociationEngine, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wildcard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A throwaway store: the person's real rules and history are not involved.
        let store = Store(url: dir.appendingPathComponent("store.json"))
        let engine = AssociationEngine(store: store)
        engine.refresh()
        return (engine, dir)
    }

    private var targets: [Target] {
        [.fileType(ext: Self.ext1), .fileType(ext: Self.ext2), .urlScheme(Self.scheme)]
    }

    private func cleanUp() {
        let db = LSDatabase()
        try? db.remove(targets.map { LSDatabase.form(for: $0, narrowBinding: true) })
        db.reload()
    }

    /// Assign, confirm it really took, undo, confirm it really went back.
    @Test("applies, verifies and rolls back")
    func roundTrip() throws {
        let (engine, dir) = try makeEngine()
        defer {
            cleanUp()
            try? FileManager.default.removeItem(at: dir)
        }
        cleanUp()

        // TextEdit is on every Mac, so this test does not depend on what is installed.
        guard let app = engine.inventory.resolve("TextEdit") else {
            Issue.record("TextEdit was not found; cannot run the live test")
            return
        }

        engine.refresh()
        let proposal = engine.makeProposal(
            title: "Self test", targets: targets, to: app, source: .cli)
        #expect(proposal.effectiveItems.count == targets.count,
                "all three should be changes, not no-ops")

        let entry = engine.apply(proposal)
        #expect(entry.failedCount == 0, "failures: \(entry.results.filter { $0.outcome.isFailure })")
        #expect(entry.appliedCount == targets.count)

        // The preference file is the thing that was written, so it is the thing
        // that gets checked — not this process's cached idea of the answer.
        let written = Dictionary(uniqueKeysWithValues:
            LSDatabase().readAll().compactMap { e -> (LSDatabase.Entry.Form, String)? in
                guard let role = e.roleAll?.lowercased() else { return nil }
                return (e.form, role)
            })
        for target in targets {
            let form = LSDatabase.form(for: target, narrowBinding: true)
            #expect(written[form] == app.id.lowercased(), "\(target.key) was not written")
        }

        // And a process that has never asked before, which is the only way to see
        // a reloaded binding.
        if let fresh = resolveInInstalledHelper(targets) {
            for target in targets {
                #expect(fresh[target.key] == app.id.lowercased(),
                        "a fresh process still does not open \(target.display) with \(app.name)")
            }
        }

        // Undo, from the recorded before-state.
        engine.refresh()
        let undo = try #require(engine.makeRollbackProposal(for: entry))
        #expect(undo.effectiveItems.count == targets.count)
        let undone = engine.apply(undo, rollingBack: entry.id)
        #expect(undone.failedCount == 0)

        let afterUndo = Set(LSDatabase().readAll().map(\.form))
        for target in targets {
            #expect(afterUndo.contains(LSDatabase.form(for: target, narrowBinding: true)) == false,
                    "\(target.key) was left behind after the undo")
        }

        // The history entry knows it was undone, so it cannot be undone twice.
        let recorded = try #require(engine.store.historyEntry(id: entry.id))
        #expect(recorded.canRollBack == false)
    }

    /// A proposal that changes nothing must say so rather than write anything.
    @Test("a no-op proposal writes nothing")
    func noOp() throws {
        let (engine, dir) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }

        let before = LSDatabase().readAll().count
        let proposal = engine.makeProposal(
            title: "Nothing", targets: [.fileType(ext: Self.ext1)], to: nil, source: .cli)
        #expect(proposal.effectiveItems.isEmpty, "nothing already opens it, so clearing it is a no-op")
        let entry = engine.apply(proposal)
        #expect(entry.appliedCount == 0)
        #expect(LSDatabase().readAll().count == before)
    }

    /// Ask the installed helper, which is what the app itself uses to check.
    private func resolveInInstalledHelper(_ targets: [Target]) -> [String: String]? {
        let helper = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Wildcard.app/Contents/Helpers/wildcard")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }

        let p = Process()
        p.executableURL = helper
        p.arguments = ["resolve"] + targets.map(\.key)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }
}
