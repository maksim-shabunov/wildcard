import Foundation

/// Applies an approved proposal and reports what really happened.
///
/// The pipeline is the one proved out before any of this was built:
///
///   1. capture a snapshot of every explicit handler
///   2. write the whole batch to `LSHandlers` in a single preference write
///   3. restart `lsd` so LaunchServices re-reads it
///   4. read the preferences back and confirm each row
///
/// Step 4 is what turns "we wrote something" into "this is now true". A partial
/// failure is reported as a partial failure.
///
/// The read-back is deliberately of the preference file rather than of
/// `NSWorkspace`, which caches handler lookups for the life of a process and
/// would keep reporting the app that was there before. Asking the system proper
/// therefore means asking a *new* process: `resolveInFreshProcess` below does
/// that, and is what the `wildcard resolve` command exists for.
public struct ApplyRunner: Sendable {

    private let db = LSDatabase()
    private let inventory: AppInventory

    public init(inventory: AppInventory) {
        self.inventory = inventory
    }

    /// Extensions whose declared content type is shared with unrelated formats
    /// must be bound narrowly, by extension tag, or they drag those formats along.
    /// `.ts` is the standing example: it resolves to a transport-stream video type.
    public static func needsNarrowBinding(_ target: Target) -> Bool {
        guard case .fileType(let ext) = target else { return false }
        return !SystemState.siblings(of: ext).isEmpty
    }

    public func apply(_ proposal: Proposal) -> [ApplyResult] {
        let work = proposal.items.filter { !$0.isNoOp }
        guard !work.isEmpty else {
            return proposal.items.map { ApplyResult(target: $0.target, outcome: .unchanged) }
        }

        var results: [ApplyResult] = proposal.items
            .filter(\.isNoOp)
            .map { ApplyResult(target: $0.target, outcome: .unchanged) }

        // Split: assigning a handler, versus handing a type back to macOS.
        var writes: [(form: LSDatabase.Entry.Form, bundleID: String)] = []
        var removals: [LSDatabase.Entry.Form] = []
        var forms: [Target: LSDatabase.Entry.Form] = [:]
        var expected: [Target: String?] = [:]

        for item in work {
            let form = LSDatabase.form(for: item.target,
                                       narrowBinding: Self.needsNarrowBinding(item.target))
            forms[item.target] = form
            expected[item.target] = item.toApp?.id
            if let to = item.toApp {
                writes.append((form, to.id))
            } else {
                removals.append(form)
            }
        }

        do {
            if !removals.isEmpty { try db.remove(removals) }
            if !writes.isEmpty { try db.write(writes) }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return results + work.map { ApplyResult(target: $0.target, outcome: .failed(reason: reason)) }
        }

        db.reload()

        // Read the preferences back. This is the authoritative check that the row
        // exists and names the app we asked for. Built by hand rather than with
        // `uniqueKeysWithValues:` because a plist written by something else may
        // legitimately contain duplicate rows, and that must not trap.
        var after: [LSDatabase.Entry.Form: String?] = [:]
        for entry in db.readAll() { after[entry.form] = entry.roleAll?.lowercased() }

        for item in work {
            guard let form = forms[item.target] else { continue }
            let want = (expected[item.target] ?? nil)?.lowercased()
            let got = after[form] ?? nil

            if want == got {
                results.append(ApplyResult(target: item.target, outcome: .applied))
            } else if want == nil {
                results.append(ApplyResult(
                    target: item.target,
                    outcome: .failed(reason: "The stored preference did not clear.")))
            } else {
                let name = item.toApp?.name ?? want ?? "that app"
                results.append(ApplyResult(
                    target: item.target,
                    outcome: .failed(reason: "LaunchServices did not accept \(name) for this type.")))
            }
        }

        return results.sorted { $0.target < $1.target }
    }

    // MARK: - Independent verification

    /// Ask a freshly launched process what opens a target now.
    ///
    /// Needed because this process's `NSWorkspace` has already cached the old
    /// answer and will keep giving it. Best-effort: returns nil when the helper
    /// cannot be found, and the caller falls back to the preference read-back.
    public static func resolveInFreshProcess(_ targets: [Target]) -> [Target: String]? {
        guard !targets.isEmpty, let helper = HelperLocator.url() else { return nil }

        let p = Process()
        p.executableURL = helper
        p.arguments = ["resolve"] + targets.map(\.key)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }

        var out: [Target: String] = [:]
        for (k, v) in raw {
            if let t = Target(key: k) { out[t] = v.lowercased() }
        }
        return out
    }

    // MARK: - Snapshots

    /// Every explicit binding right now, keyed for storage.
    public func captureSnapshot(name: String, automatic: Bool) -> Snapshot {
        let explicit = db.explicitBindings(extensionsForType: SystemState.extensions(forType:))
        var map: [String: String] = [:]
        for (target, bundleID) in explicit { map[target.key] = bundleID }
        return Snapshot(name: name, isAutomatic: automatic, bindings: map)
    }
}

/// Finds the `wildcard` helper binary next to whatever is running.
///
/// The GUI ships it inside the bundle; during development it sits in the SwiftPM
/// build directory beside the app executable.
public enum HelperLocator {
    public static func url() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let bundleHelpers = Bundle.main.builtInPlugInsURL?
            .deletingLastPathComponent().appendingPathComponent("Helpers/wildcard") {
            candidates.append(bundleHelpers)
        }
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "wildcard") {
            candidates.append(aux)
        }
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("wildcard"))
            candidates.append(exe.deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Helpers/wildcard"))
        }
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/wildcard"))

        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
