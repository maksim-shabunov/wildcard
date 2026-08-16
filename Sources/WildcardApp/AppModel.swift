import AppKit
import Combine
import SwiftUI
import WildcardKit

/// The window's view of everything. One object, owned by the app, handed to
/// every screen.
///
/// The rule it enforces: no screen applies anything. A screen composes a
/// `Proposal` and hands it here; this puts it in front of a person. That is the
/// same path an agent's request takes, which is why there is only one.
@MainActor
final class AppModel: ObservableObject {

    let engine = AssociationEngine()
    let queue = ProposalQueue.shared

    var store: Store { engine.store }
    var catalog: TypeCatalog { engine.catalog }
    var inventory: AppInventory { engine.inventory }

    // Published state. Any change re-renders the screens; the heavy tables are
    // read straight off the engine to avoid copying thousands of rows.
    @Published private(set) var revision = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var summary = CoverageSummary()

    @Published var settings = Store.Settings()
    @Published var rules: [Rule] = []
    @Published var decisions: [PendingDecision] = []
    @Published var history: [HistoryEntry] = []
    @Published var snapshots: [Snapshot] = []
    @Published var waitingProposals: [Proposal] = []
    /// Files left in the queue that could not be read as a request. Shown rather
    /// than skipped: something told a person to come here and approve one.
    @Published var unreadableRequests: [String] = []

    /// The proposal currently in the approval sheet.
    @Published var reviewing: Proposal?
    /// Set while an approved proposal is being written.
    @Published var applying = false
    /// A short, factual line about the last thing that happened.
    @Published var notice: Notice?

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isProblem = false
    }

    private var watcher: AppFolderWatcher?

    init() {
        settings = store.settings
        store.onChange = { [weak self] in
            Task { @MainActor in self?.reloadStoreState() }
        }
        queue.onChange = { [weak self] in
            Task { @MainActor in self?.reloadQueue() }
        }
        watcher = AppFolderWatcher { [weak self] in
            Task { @MainActor in self?.appFolderChanged() }
        }
    }

    // MARK: - Lifecycle

    func start() {
        applyAppearance()
        queue.prune()
        queue.startWatching()
        // The helper is a separate process. A rule an agent saves has to show up
        // here without a relaunch, or "visible in the app" is not true.
        store.startWatching()
        reloadStoreState()
        reloadQueue()
        refresh(thenFindGaps: true)
        watcher?.setRunning(settings.watchForNewTypes)
    }

    /// An application was installed, updated or removed. Rescan and run the gap
    /// check, which is the only thing that stops a new type being claimed quietly.
    private func appFolderChanged() {
        guard settings.watchForNewTypes else { return }
        refresh(thenFindGaps: true)
    }

    /// Rebuild the whole picture. Runs off the main thread — a full scan touches
    /// every installed bundle — then republishes in one step.
    func refresh(thenFindGaps findGaps: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            engine.refresh()
            let summary = engine.summary
            let gaps = findGaps ? engine.findGaps() : nil
            await MainActor.run {
                self.summary = summary
                self.isRefreshing = false
                self.revision &+= 1
                if let gaps { self.handle(gaps: gaps) }
            }
        }
    }

    private func reloadStoreState() {
        // A rule that arrived from the helper changes what counts as covered or
        // drifted, and that is computed in the engine rather than read from the
        // store — so noticing the rule is not enough, the picture has to be
        // recomputed too.
        let rulesChanged = store.rules != rules

        settings = store.settings
        rules = store.rules
        decisions = store.pending
        history = store.history
        snapshots = store.snapshots
        revision &+= 1
        applyAppearance()

        if rulesChanged { refresh() }
    }

    /// Apply the appearance choice to the whole application, not only to the
    /// SwiftUI content.
    ///
    /// The title bar, the sidebar material and the window's own background are
    /// AppKit's, and resolve against `NSApp.effectiveAppearance`. Setting only
    /// `preferredColorScheme` leaves those following the system, so choosing Dark
    /// in Wildcard while the Mac is in Light gives a light frame around dark
    /// content.
    private func applyAppearance() {
        switch settings.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    private func reloadQueue() {
        waitingProposals = queue.awaitingApproval()
        unreadableRequests = queue.unreadableFiles()
        // The sheet is a live control, not a receipt. If what it is showing has
        // since expired or been decided elsewhere, take it away rather than
        // leave a button that would apply a stale request.
        if let current = reviewing, queue.get(current.id)?.status != .awaitingApproval {
            reviewing = nil
        }
        // Something arrived from outside while nothing was on screen — show it.
        if reviewing == nil, let next = waitingProposals.first {
            reviewing = next
        }
    }

    // MARK: - The gap

    /// Handle types nothing has decided about.
    ///
    /// A rule that clearly covers a newly-seen type still produces a *proposal*,
    /// not a silent write. The promise in the brief is that nothing changes
    /// without being shown first, and "a rule already said so" is not an
    /// exception a person agreed to in advance.
    private func handle(gaps: (adopt: [Target: Rule], decide: [PendingDecision])) {
        store.add(pending: gaps.decide)
        engine.markUniverseSeen()

        guard settings.autoAdoptWhenRuleMatches, !gaps.adopt.isEmpty else { return }
        for (ruleID, targets) in Dictionary(grouping: gaps.adopt.keys, by: { gaps.adopt[$0]!.id }) {
            guard let rule = gaps.adopt.values.first(where: { $0.id == ruleID }) else { continue }
            let app = inventory.app(id: rule.appID)
            let proposal = engine.makeProposal(
                title: "New types matched “\(rule.name)”",
                targets: Array(targets),
                to: app,
                source: .autoAdopt,
                note: "These turned up since Wildcard last looked and fall inside a rule you already set.")
            try? queue.write(proposal)
        }
        reloadQueue()
    }

    func dismiss(decisions targets: [Target]) {
        store.dismissPending(targets)
    }

    /// Show the unreadable queue files in Finder.
    ///
    /// Wildcard will not guess at what a malformed request meant, and it will not
    /// quietly delete it either — the file is someone's intent, however garbled.
    /// Putting it in front of them is the honest end of the road.
    func revealUnreadableRequests() {
        let urls = unreadableRequests.map { queue.directory.appendingPathComponent($0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Proposing

    /// Compose a change and put it in front of the person. Nothing else in the
    /// app is allowed to reach `ApplyRunner`.
    func propose(title: String, targets: [Target], to app: InstalledApp?, source: ChangeSource = .gui, note: String? = nil) {
        guard !targets.isEmpty else {
            notice = Notice(text: "Nothing was selected, so there is nothing to change.")
            return
        }
        let proposal = engine.makeProposal(title: title, targets: targets, to: app, source: source, note: note)
        guard !proposal.effectiveItems.isEmpty else {
            notice = Notice(text: "Already the case — all \(proposal.items.count) already open with \(app?.name ?? "the macOS default").")
            return
        }
        try? queue.write(proposal)
        reviewing = proposal
        reloadQueue()
    }

    func proposeRollback(of entry: HistoryEntry) {
        guard let proposal = engine.makeRollbackProposal(for: entry) else {
            notice = Notice(text: "There is nothing left to undo in that change.")
            return
        }
        guard !proposal.effectiveItems.isEmpty else {
            notice = Notice(text: "Everything in that change is already back the way it was.")
            return
        }
        try? queue.write(proposal)
        reviewing = proposal
    }

    func proposeRestore(of snapshot: Snapshot) {
        let proposal = engine.makeRestoreProposal(for: snapshot)
        guard !proposal.effectiveItems.isEmpty else {
            notice = Notice(text: "Everything already matches that snapshot.")
            return
        }
        try? queue.write(proposal)
        reviewing = proposal
    }

    /// Make the system match a rule, for every type where it currently does not.
    ///
    /// Covers both halves of that: types something else took, and types the rule
    /// has simply never been applied to. The title says which, because "restore"
    /// and "apply" are different promises.
    func proposeRestoreRule(_ rule: Rule) {
        let rows = engine.rows.values.filter { $0.rule?.id == rule.id && $0.coverage != .covered }
        let verb = rows.contains { $0.coverage == .drifted } ? "Restore" : "Apply"
        propose(title: "\(verb) “\(rule.name)”",
                targets: rows.map(\.target),
                to: inventory.app(id: rule.appID),
                source: .ruleEnforcement)
    }

    /// Take a snapshot by hand, so there is a named point to come back to.
    func saveSnapshot(named name: String) {
        let runner = ApplyRunner(inventory: inventory)
        let snap = runner.captureSnapshot(name: name.isEmpty ? "Saved state" : name, automatic: false)
        store.append(snapshot: snap)
        notice = Notice(text: "Saved “\(snap.name)” — \(snap.count) assignments recorded.")
    }

    // MARK: - Deciding

    func approve(_ proposal: Proposal) {
        guard !applying else { return }
        // A sheet can sit on screen for a long time. Proposals expire, and one
        // that has expired has to be refused here too — otherwise the deadline
        // is decorative and a click ten minutes late still writes.
        guard queue.get(proposal.id)?.status == .awaitingApproval else {
            reviewing = nil
            reloadQueue()
            notice = Notice(text: "That request expired before it was approved. Nothing was changed.")
            return
        }
        applying = true
        reviewing = nil
        let engine = self.engine
        let queue = self.queue
        let rollingBack = proposal.rollbackOf

        Task.detached(priority: .userInitiated) {
            let entry = engine.apply(proposal, rollingBack: rollingBack)
            queue.setStatus(proposal.id, entry.failedCount > 0 && entry.appliedCount == 0 ? .failed : .applied,
                            results: entry.results)
            let summary = engine.summary
            await MainActor.run {
                self.applying = false
                self.summary = summary
                self.revision &+= 1
                self.reloadStoreState()
                self.reloadQueue()
                self.notice = Self.notice(for: entry)
            }
        }
    }

    func reject(_ proposal: Proposal) {
        queue.setStatus(proposal.id, .rejected)
        reviewing = nil
        reloadQueue()
        notice = Notice(text: "Rejected. Nothing was changed.")
    }

    private static func notice(for entry: HistoryEntry) -> Notice {
        if entry.appliedCount == 0 && entry.failedCount > 0 {
            return Notice(text: "Nothing changed — all \(entry.failedCount) were refused by LaunchServices.", isProblem: true)
        }
        if entry.failedCount > 0 {
            return Notice(text: "\(entry.appliedCount) changed, \(entry.failedCount) did not take. See History for which.", isProblem: true)
        }
        let n = entry.appliedCount
        return Notice(text: "\(n) \(n == 1 ? "type" : "types") changed. Undo from History, or press ⌘Z.")
    }

    /// ⌘Z — undo the most recent applied change.
    func undoLast() {
        guard let entry = history.first(where: \.canRollBack) else {
            notice = Notice(text: "There is nothing to undo yet.")
            return
        }
        proposeRollback(of: entry)
    }

    // MARK: - Rules

    func saveRule(_ rule: Rule) {
        store.upsert(rule: rule)
        refresh()
    }

    func deleteRule(_ rule: Rule) {
        store.deleteRule(id: rule.id)
        refresh()
    }

    func setRule(_ rule: Rule, enabled: Bool) {
        var r = rule
        r.isEnabled = enabled
        store.upsert(rule: r)
        refresh()
    }

    /// Turning a one-off assignment into a standing rule, offered right after
    /// a category is assigned.
    func makeRule(forCategory id: String, name: String, app: InstalledApp) {
        saveRule(Rule(name: name, scope: .category(id: id), appID: app.id, appName: app.name))
    }

    // MARK: - Custom categories

    func saveCustomCategory(_ category: CustomCategory) {
        store.upsert(category: category)
        refresh()
    }

    func deleteCustomCategory(_ id: String) {
        store.deleteCategory(id: id)
        refresh()
    }

    // MARK: - Settings

    func update(_ change: (inout Store.Settings) -> Void) {
        var s = settings
        change(&s)
        settings = s
        store.update(settings: s)
        watcher?.setRunning(s.watchForNewTypes)
        applyAppearance()
    }

    // MARK: - Lookups used across screens

    func rows(in categoryID: String) -> [CoverageRow] { engine.rows(inCategory: categoryID) }
    func row(for target: Target) -> CoverageRow? { engine.row(for: target) }

    var allRows: [CoverageRow] {
        engine.rows.values.sorted { $0.target < $1.target }
    }

    var driftedRows: [CoverageRow] { engine.driftedRows }
    var notAppliedRows: [CoverageRow] { engine.notAppliedRows }

    func dominantApp(in categoryID: String) -> (app: AppRef, share: Double)? {
        engine.dominantApp(inCategory: categoryID)
    }

    /// Every category, shipped and custom, in one list for the sidebar.
    var fileCategories: [CatalogCategory] { catalog.fileCategories }
    var schemeCategories: [CatalogCategory] { catalog.schemeCategories }

    func categoryName(_ id: String) -> String {
        catalog.category(id: id)?.name
            ?? store.customCategories.first { $0.id == id }?.name
            ?? id
    }

    /// Open a proposal by id — how `wildcard://proposal/<id>` arrives.
    func show(proposalID: String) {
        guard let p = queue.get(proposalID) else {
            notice = Notice(text: "That request has already been dealt with.")
            return
        }
        if p.status == .awaitingApproval { reviewing = p }
        else { notice = Notice(text: "That request was already \(p.status.rawValue.replacingOccurrences(of: "_", with: " ")).") }
    }
}
