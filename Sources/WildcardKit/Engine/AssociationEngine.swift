import Foundation

/// How a target stands relative to what the user asked for.
public enum Coverage: String, Sendable, Codable {
    /// A rule claims it and the system agrees.
    case covered
    /// A rule claims it, and the app that has it was chosen on purpose by
    /// something else — an installer, or the person before the rule existed.
    /// This is the state that otherwise only shows up when the wrong app
    /// launches.
    case drifted
    /// A rule claims it, but the rule has never been applied to it. Whatever
    /// opens it was picked by macOS, so nothing has been taken from anybody —
    /// which is a different sentence from "something changed this".
    case notApplied = "not_applied"
    /// No rule claims it.
    case uncovered
}

public struct CoverageRow: Identifiable, Sendable {
    public var id: String { target.key }
    public var target: Target
    public var label: String
    public var categoryID: String?
    public var categoryName: String?
    public var binding: Assignment
    public var coverage: Coverage
    public var rule: Rule?
    /// The app the governing rule wants, when it differs from reality.
    public var expected: AppRef?
}

public struct CoverageSummary: Sendable {
    public init() {}
    public var managed = 0
    public var drifted = 0
    public var notApplied = 0
    public var uncovered = 0
    public var unhandled = 0     // nothing opens it at all
    public var total = 0
}

/// The single place that knows the whole picture: what exists, what opens it,
/// what the user asked for, and what to do about the difference.
public final class AssociationEngine: @unchecked Sendable {

    public let catalog: TypeCatalog
    public let inventory: AppInventory
    public let state: SystemState
    public let store: Store
    private let runner: ApplyRunner

    public private(set) var rows: [Target: CoverageRow] = [:]
    public private(set) var universe: [Target] = []

    public init(catalog: TypeCatalog = .shared, store: Store = .shared) {
        self.catalog = catalog
        self.store = store
        let inv = AppInventory()
        self.inventory = inv
        self.state = SystemState(inventory: inv)
        self.runner = ApplyRunner(inventory: inv)
    }

    // MARK: - Refresh

    /// Rebuild the whole picture. Cheap enough (~0.1s) to run on every window
    /// activation rather than trying to be clever about invalidation.
    public func refresh() {
        inventory.scan()
        universe = buildUniverse()
        state.refresh(targets: universe)
        rebuildRows()
    }

    /// Everything worth showing: what the catalog knows, plus every extension and
    /// scheme any installed app declares, plus anything already bound.
    ///
    /// The union is the point. An association you never consciously set is
    /// exactly the kind this app exists to surface.
    private func buildUniverse() -> [Target] {
        var set = Set(catalog.allTargets)
        for c in store.customCategories { set.formUnion(c.targets) }
        set.formUnion(inventory.allDeclaredExtensions.map { Target.fileType(normalizing: $0) })
        set.formUnion(inventory.allDeclaredSchemes.map { Target.urlScheme($0) })
        set.formUnion(LSDatabase()
            .explicitBindings(extensionsForType: SystemState.extensions(forType:))
            .keys)
        set = set.filter { !$0.raw.isEmpty }
        return set.sorted()
    }

    private func rebuildRows() {
        let rules = store.rules.filter(\.isEnabled)
        let custom = store.customCategories

        // Highest priority wins; ties broken by most recently updated.
        var governing: [Target: Rule] = [:]
        for rule in rules.sorted(by: { ($0.priority, $0.updatedAt) < ($1.priority, $1.updatedAt) }) {
            for t in rule.targets(in: catalog, custom: custom) { governing[t] = rule }
        }

        var out: [Target: CoverageRow] = [:]
        out.reserveCapacity(universe.count)

        for target in universe {
            let binding = state.binding(for: target)
            let category = categoryInfo(for: target, custom: custom)
            var coverage = Coverage.uncovered
            var expected: AppRef?

            if let rule = governing[target] {
                if binding.handler?.matches(rule.appID) == true {
                    coverage = .covered
                } else {
                    // Telling these two apart is the difference between "an
                    // installer took this" and "you made a rule a minute ago and
                    // have not applied it yet". Only a deliberate binding — one
                    // written into LaunchServices by somebody — can be drift.
                    coverage = binding.origin == .explicit ? .drifted : .notApplied
                    expected = AppRef(id: rule.appID, name: rule.appName)
                }
            }

            out[target] = CoverageRow(
                target: target,
                label: catalog.label(for: target),
                categoryID: category?.0,
                categoryName: category?.1,
                binding: binding,
                coverage: coverage,
                rule: governing[target],
                expected: expected
            )
        }
        rows = out
    }

    private func categoryInfo(for target: Target, custom: [CustomCategory]) -> (String, String)? {
        if let c = catalog.category(forExtension: target.raw) { return (c.id, c.name) }
        if let c = custom.first(where: { $0.members.contains(target) }) { return (c.id, c.name) }
        return nil
    }

    // MARK: - Queries

    public func row(for target: Target) -> CoverageRow? { rows[target] }

    public func rows(inCategory id: String) -> [CoverageRow] {
        let targets: [Target]
        if let c = catalog.category(id: id) { targets = c.targets }
        else if let c = store.customCategories.first(where: { $0.id == id }) { targets = c.targets }
        else { return [] }
        return targets.compactMap { rows[$0] }
    }

    public var summary: CoverageSummary {
        var s = CoverageSummary()
        for row in rows.values {
            s.total += 1
            switch row.coverage {
            case .covered: s.managed += 1
            case .drifted: s.drifted += 1
            case .notApplied: s.notApplied += 1
            case .uncovered: s.uncovered += 1
            }
            if row.binding.origin == .none { s.unhandled += 1 }
        }
        return s
    }

    public var driftedRows: [CoverageRow] {
        rows.values.filter { $0.coverage == .drifted }.sorted { $0.target < $1.target }
    }

    /// Claimed by a rule that has not been applied to them yet.
    public var notAppliedRows: [CoverageRow] {
        rows.values.filter { $0.coverage == .notApplied }.sorted { $0.target < $1.target }
    }

    /// The app most of a category currently opens with, or nil if it is a mess.
    /// Used to show a category's state without pretending it is uniform.
    public func dominantApp(inCategory id: String) -> (app: AppRef, share: Double)? {
        let rows = rows(inCategory: id)
        guard !rows.isEmpty else { return nil }
        var counts: [AppRef: Int] = [:]
        for r in rows { if let h = r.binding.handler { counts[h, default: 0] += 1 } }
        // A tie must not be settled by Dictionary iteration order. Swift seeds
        // its hashing per process, so "Plain text — Numbers and 1 other" became
        // "Plain text — Zed and 1 other" on the next launch with nothing on the
        // machine having changed. In an app whose whole job is telling you what
        // moved, a line that moves on its own is worse than no line.
        guard let (app, n) = counts.max(by: { a, b in
            a.value != b.value ? a.value < b.value : a.key.name > b.key.name
        }) else { return nil }
        return (app, Double(n) / Double(rows.count))
    }

    // MARK: - Building proposals

    /// Compose a proposal to point a set of targets at an app.
    /// `app == nil` means "hand these back to macOS".
    public func makeProposal(
        title: String,
        targets: [Target],
        to app: InstalledApp?,
        source: ChangeSource,
        note: String? = nil
    ) -> Proposal {
        let toRef = app?.ref
        var items: [ChangeItem] = []
        var sharedTypeTargets: [Target] = []
        var undeclared: [Target] = []

        for target in targets.sorted() {
            let binding = state.binding(for: target)
            let isNoOp: Bool = {
                guard let toRef else { return binding.origin == .none }
                return binding.handler?.id == toRef.id && binding.origin == .explicit
            }()

            var collateral: [String] = []
            if case .fileType(let ext) = target {
                let siblings = SystemState.siblings(of: ext)
                if !siblings.isEmpty {
                    // Wildcard binds these narrowly, by extension tag, so the
                    // siblings are *not* dragged along. Worth naming anyway,
                    // because the shared type is the surprising part.
                    collateral = siblings
                    sharedTypeTargets.append(target)
                }
                if let app, !app.declaredExtensions.contains(ext) {
                    undeclared.append(target)
                }
            }

            items.append(ChangeItem(
                target: target,
                fromApp: binding.handler,
                fromOrigin: binding.origin,
                toApp: toRef,
                isNoOp: isNoOp,
                collateral: collateral
            ))
        }

        var warnings: [ProposalWarning] = []

        if !sharedTypeTargets.isEmpty {
            let names = sharedTypeTargets.prefix(3).map(\.display).joined(separator: ", ")
            let more = sharedTypeTargets.count > 3 ? " and \(sharedTypeTargets.count - 3) more" : ""
            warnings.append(ProposalWarning(
                kind: .sharedType,
                message: "\(names)\(more) share a file type with unrelated formats. "
                       + "Wildcard binds these by extension so nothing else moves with them.",
                targets: sharedTypeTargets))
        }

        let systemPrompted = targets.filter(Self.macOSPromptsFor)
        if !systemPrompted.isEmpty {
            warnings.append(ProposalWarning(
                kind: .systemPrompt,
                message: "macOS controls the default browser and mail app itself. "
                       + "It may show its own confirmation, or reset these later.",
                targets: systemPrompted))
        }

        if !undeclared.isEmpty, let app {
            let names = undeclared.prefix(4).map(\.display).joined(separator: ", ")
            let more = undeclared.count > 4 ? " and \(undeclared.count - 4) more" : ""
            warnings.append(ProposalWarning(
                kind: .appDoesNotDeclare,
                message: "\(app.name) does not advertise support for \(names)\(more). "
                       + "It will usually still open them; any that refuse are reported after applying.",
                targets: undeclared))
        }

        return Proposal(title: title, source: source, items: items,
                        warnings: warnings, note: note)
    }

    /// Schemes macOS reserves to its own settings flow.
    public static func macOSPromptsFor(_ target: Target) -> Bool {
        guard case .urlScheme(let s) = target else { return false }
        return ["http", "https", "mailto"].contains(s.lowercased())
    }

    /// A proposal that puts a previous change back, using the recorded
    /// before-state rather than guessing.
    public func makeRollbackProposal(for entry: HistoryEntry) -> Proposal? {
        let items = entry.reversibleItems
        guard !items.isEmpty else { return nil }

        var reversed: [ChangeItem] = []
        for item in items {
            let now = state.binding(for: item.target)
            // Restoring an inherited binding means removing the explicit one,
            // not pinning the same app — that is what "exactly as it was" means.
            let restoreTo: AppRef? = item.fromOrigin == .explicit ? item.fromApp : nil
            let isNoOp: Bool = {
                guard let restoreTo else { return now.origin != .explicit }
                return now.handler?.id == restoreTo.id && now.origin == .explicit
            }()
            reversed.append(ChangeItem(
                target: item.target,
                fromApp: now.handler,
                fromOrigin: now.origin,
                toApp: restoreTo,
                isNoOp: isNoOp,
                collateral: item.collateral,
                // What it opened with before this change — the answer to the
                // question someone undoing actually has.
                expectedFallback: restoreTo == nil ? item.fromApp : nil))
        }

        return Proposal(
            title: "Undo “\(entry.title)”",
            source: .rollback,
            items: reversed,
            note: "Restores what these types opened with before \(Self.friendlyDate(entry.appliedAt)).",
            rollbackOf: entry.id)
    }

    public func makeRestoreProposal(for snapshot: Snapshot) -> Proposal {
        var items: [ChangeItem] = []
        let saved = snapshot.bindings
        let currentExplicit = LSDatabase()
            .explicitBindings(extensionsForType: SystemState.extensions(forType:))

        // Everything the snapshot recorded, plus anything explicitly bound since
        // (which must be cleared to genuinely return to that moment).
        var keys = Set(saved.keys)
        keys.formUnion(currentExplicit.keys.map(\.key))

        // Applications get uninstalled between a snapshot and its restore. The
        // write still succeeds — LaunchServices is happy to store a bundle id
        // that resolves to nothing — and the type then opens with nothing at all.
        // Saying so beforehand is the difference between a restore and a trap.
        var missing: [Target: String] = [:]

        for key in keys.sorted() {
            guard let target = Target(key: key) else { continue }
            let now = state.binding(for: target)
            let wanted = saved[key].map { id -> AppRef in
                guard let installed = inventory.app(id: id) else {
                    missing[target] = id
                    return AppRef(id: id, name: SystemState.friendlyName(forMissing: id))
                }
                return AppRef(id: id, name: installed.name)
            }
            let isNoOp: Bool = {
                guard let wanted else { return now.origin != .explicit }
                return now.handler?.id == wanted.id && now.origin == .explicit
            }()
            items.append(ChangeItem(target: target, fromApp: now.handler,
                                    fromOrigin: now.origin, toApp: wanted, isNoOp: isNoOp))
        }

        var warnings: [ProposalWarning] = []
        if !missing.isEmpty {
            let apps = Set(missing.values).sorted()
            let named = apps.prefix(3).joined(separator: ", ")
            let more = apps.count > 3 ? " and \(apps.count - 3) more" : ""
            let n = missing.count
            warnings.append(ProposalWarning(
                kind: .missingApp,
                message: "\(named)\(more) \(apps.count == 1 ? "is" : "are") no longer installed. "
                       + "\(n) \(n == 1 ? "type" : "types") would be pointed at "
                       + "\(apps.count == 1 ? "it" : "them") and open with nothing.",
                targets: missing.keys.sorted()))
        }

        return Proposal(
            title: "Restore “\(snapshot.name)”",
            source: .rollback,
            items: items,
            warnings: warnings,
            note: "Returns every file type to how it was on \(Self.friendlyDate(snapshot.createdAt)).")
    }

    // MARK: - Applying

    /// Apply an approved proposal. Snapshots first, verifies after, records
    /// history either way.
    @discardableResult
    public func apply(_ proposal: Proposal, rollingBack historyID: String? = nil) -> HistoryEntry {
        if store.settings.snapshotBeforeApply {
            let snap = runner.captureSnapshot(name: "Before “\(proposal.title)”", automatic: true)
            store.append(snapshot: snap)
        }

        let results = runner.apply(proposal)
        let entry = HistoryEntry(
            id: proposal.id,
            title: proposal.title,
            source: proposal.source,
            items: proposal.items,
            results: results)
        store.append(history: entry)

        if let historyID { store.markRolledBack(historyID: historyID, by: proposal.id) }

        refresh()
        return entry
    }

    // MARK: - The gap

    /// Types that nothing has decided about.
    ///
    /// The promise is that a new file type is never silently handed to whichever
    /// app claimed it first. Anything a rule clearly covers is adopted and logged;
    /// everything else is queued for a decision.
    ///
    /// "New" is the operative word. The first run records what is already on the
    /// machine as the baseline and queues nothing: arriving to an inbox of six
    /// hundred items would say nothing useful, and none of them are being taken
    /// by anybody — the Overview counts them and All file types can filter to
    /// them. What lands here afterwards is what genuinely turned up.
    public func findGaps() -> (adopt: [Target: Rule], decide: [PendingDecision]) {
        let previouslySeen = Set(store.settings.lastSeenExtensions)
        guard !previouslySeen.isEmpty else { return ([:], []) }
        let rules = store.rules.filter(\.isEnabled)
        let custom = store.customCategories

        var claimed: [Target: Rule] = [:]
        for rule in rules.sorted(by: { $0.priority < $1.priority }) {
            for t in rule.targets(in: catalog, custom: custom) { claimed[t] = rule }
        }

        var adopt: [Target: Rule] = [:]
        var decide: [PendingDecision] = []
        let alreadyPending = Set(store.pending.map(\.target))

        for target in universe {
            guard let row = rows[target] else { continue }
            guard target.isFileType, !previouslySeen.contains(target.raw) else { continue }

            if let rule = claimed[target] {
                // A rule covers it, but the system does not agree yet — either
                // way round, offer to put it right. Nothing is written here.
                if row.coverage != .covered, store.settings.autoAdoptWhenRuleMatches {
                    adopt[target] = rule
                }
                continue
            }

            guard !alreadyPending.contains(target) else { continue }

            let category = catalog.category(forExtension: target.raw)
            let suggestion = category.flatMap { c -> AppRef? in
                rules.first { rule in
                    if case .category(let id) = rule.scope { return id == c.id }
                    return false
                }.map { AppRef(id: $0.appID, name: $0.appName) }
            }

            decide.append(PendingDecision(
                target: target,
                // All three read as different sentences in the inbox: one Wildcard
                // can suggest an answer for, one it knows the shape of but has
                // been given no instruction about, and one it has never heard of.
                reason: category == nil ? .unknownType : (suggestion == nil ? .noRule : .newlySeen),
                currentHandler: row.binding.handler,
                suggestedCategoryID: category?.id,
                suggestedApp: suggestion))
        }

        return (adopt, decide)
    }

    /// Record what we have seen so the next run can tell what is new.
    public func markUniverseSeen() {
        store.rememberSeenExtensions(Set(universe.filter(\.isFileType).map(\.raw)))
    }

    // MARK: - Helpers

    static func friendlyDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
