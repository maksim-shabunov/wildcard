import Foundation
import Testing
@testable import WildcardKit

/// Two `Store` objects on one file stand in for the two processes that really
/// share it: the window and the agent-facing helper. The failure being guarded
/// against is silent — the second writer wins, the first writer's rule is gone,
/// and nothing anywhere reports an error.
@Suite("Store, shared between processes")
struct StoreTests {

    private func makeFile() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wildcard-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    private func rule(_ name: String) -> Rule {
        Rule(name: name, scope: .category(id: "code"), appID: "com.example.\(name)", appName: name)
    }

    @Test("a write from the other process is not clobbered by the next write here")
    func noLostUpdate() throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Both opened the file before either wrote anything, which is the case
        // that goes wrong: each holds a whole copy and saves it wholesale.
        let app = Store(url: url)
        let helper = Store(url: url)

        helper.upsert(rule: rule("From the agent"))
        // The app has not looked since; it still believes there are no rules.
        app.update(settings: {
            var s = Store.Settings()
            s.agentAccessEnabled = true
            return s
        }())

        let onDisk = Store(url: url)
        #expect(onDisk.rules.map(\.name) == ["From the agent"],
                "the agent's rule was overwritten by the app's settings write")
        #expect(onDisk.settings.agentAccessEnabled == true)
    }

    @Test("both directions, interleaved")
    func interleaved() throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let app = Store(url: url)
        let helper = Store(url: url)

        app.upsert(rule: rule("one"))
        helper.upsert(rule: rule("two"))
        app.upsert(rule: rule("three"))
        helper.upsert(rule: rule("four"))

        let names = Set(Store(url: url).rules.map(\.name))
        #expect(names == ["one", "two", "three", "four"], "kept \(names.sorted())")
    }

    @Test("deleting a rule the other process created actually deletes it")
    func deleteAcrossProcesses() throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let app = Store(url: url)
        let helper = Store(url: url)

        app.upsert(rule: rule("doomed"))
        // The helper has to see it before it can be asked to remove it.
        #expect(helper.reloadIfChanged())
        let id = try #require(helper.rules.first?.id)
        helper.deleteRule(id: id)

        #expect(Store(url: url).rules.isEmpty)
    }

    @Test("reloadIfChanged reports only real changes")
    func reloadReportsHonestly() throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let app = Store(url: url)
        let helper = Store(url: url)

        #expect(app.reloadIfChanged() == false, "nothing has happened yet")
        helper.upsert(rule: rule("new"))
        #expect(app.reloadIfChanged(), "the helper wrote; that is a change")
        #expect(app.rules.count == 1)
        #expect(app.reloadIfChanged() == false, "reading twice is not two changes")

        // Its own save must not read back as somebody else's change, or the
        // window would refresh itself in a loop.
        app.upsert(rule: rule("mine"))
        #expect(app.reloadIfChanged() == false)
    }
}
