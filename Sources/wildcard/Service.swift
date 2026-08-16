import AppKit
import Foundation
import WildcardKit

/// Everything the CLI and the MCP server can do, in one place, so the two can
/// never drift apart in what they allow.
///
/// The important property: `propose` is the only way to change anything, and all
/// it does is put a file in the queue and ask the window to come forward. Nothing
/// here can apply a change. That is not a convention — there is no code path.
struct Service {

    let engine: AssociationEngine
    let queue = ProposalQueue.shared

    init() {
        engine = AssociationEngine()
        engine.refresh()
    }

    /// Whether the person has allowed anything outside the app to operate it.
    /// Read from disk on every check — this process may have been running since
    /// before they made up their mind.
    var agentAccessEnabled: Bool { engine.store.currentSettings.agentAccessEnabled }

    func requireAgentAccess() throws {
        guard agentAccessEnabled else { throw ServiceError.agentAccessDisabled }
    }

    // MARK: - Reading

    func categories() -> [[String: Any]] {
        let shipped = engine.catalog.categories.map { c -> [String: Any] in
            [
                "id": c.id,
                "name": c.name,
                "kind": c.kind.rawValue,
                "summary": c.summary,
                "type_count": c.count,
                "subgroups": c.subgroups.map { ["id": $0.id, "name": $0.name, "type_count": $0.types.count] },
                "current_app": currentAppSummary(categoryID: c.id) as Any,
            ]
        }
        let custom = engine.store.customCategories.map { c -> [String: Any] in
            [
                "id": c.id,
                "name": c.name,
                "kind": c.kind.rawValue,
                "summary": c.summary,
                "type_count": c.members.count,
                "custom": true,
                "current_app": currentAppSummary(categoryID: c.id) as Any,
            ]
        }
        return shipped + custom
    }

    private func currentAppSummary(categoryID: String) -> [String: Any]? {
        guard let (app, share) = engine.dominantApp(inCategory: categoryID) else { return nil }
        return ["name": app.name, "bundle_id": app.id, "share": (share * 100).rounded() / 100]
    }

    func category(id: String) -> [String: Any]? {
        let rows = engine.rows(inCategory: id)
        guard !rows.isEmpty else { return nil }
        let name = engine.catalog.category(id: id)?.name
            ?? engine.store.customCategories.first { $0.id == id }?.name
            ?? id
        return [
            "id": id,
            "name": name,
            "type_count": rows.count,
            "types": rows.map(describe),
        ]
    }

    func searchTypes(_ query: String, limit: Int) -> [[String: Any]] {
        engine.catalog.search(query, limit: limit).map { target, name, category in
            var d: [String: Any] = [
                "target": target.key,
                "display": target.display,
                "name": name,
                "category": category.id,
                "category_name": category.name,
            ]
            if let row = engine.row(for: target) {
                d["current_app"] = row.binding.handler?.name ?? NSNull()
                d["current_bundle_id"] = row.binding.handler?.id ?? NSNull()
            }
            return d
        }
    }

    enum Filter: String {
        case all, uncovered, drifted, unhandled, managed
        case notApplied = "not_applied"
    }

    func associations(category: String?, targets: [Target]?, filter: Filter) -> [[String: Any]] {
        var rows: [CoverageRow]
        if let category { rows = engine.rows(inCategory: category) }
        else if let targets { rows = targets.compactMap { engine.row(for: $0) } }
        else { rows = engine.rows.values.sorted { $0.target < $1.target } }

        switch filter {
        case .all: break
        case .uncovered: rows = rows.filter { $0.coverage == .uncovered }
        case .drifted: rows = rows.filter { $0.coverage == .drifted }
        case .notApplied: rows = rows.filter { $0.coverage == .notApplied }
        case .managed: rows = rows.filter { $0.coverage == .covered }
        case .unhandled: rows = rows.filter { $0.binding.origin == .none }
        }
        return rows.map(describe)
    }

    func describe(_ row: CoverageRow) -> [String: Any] {
        var d: [String: Any] = [
            "target": row.target.key,
            "display": row.target.display,
            "name": row.label,
            "opens_with": row.binding.handler?.name ?? NSNull(),
            "bundle_id": row.binding.handler?.id ?? NSNull(),
            "chosen": row.binding.origin.rawValue,
            "coverage": row.coverage.rawValue,
        ]
        if let c = row.categoryID { d["category"] = c }
        if let e = row.expected { d["rule_expects"] = e.name }
        return d
    }

    func applications() -> [[String: Any]] {
        engine.inventory.apps.map { app in
            [
                "name": app.name,
                "bundle_id": app.id,
                "path": app.path,
                "is_system": app.isSystem,
                "declared_extension_count": app.declaredExtensions.count,
                "declared_scheme_count": app.declaredSchemes.count,
            ]
        }
    }

    func summary() -> [String: Any] {
        let s = engine.summary
        return [
            "total_types": s.total,
            "managed_by_rules": s.managed,
            "drifted": s.drifted,
            "rule_not_applied_yet": s.notApplied,
            "not_covered_by_a_rule": s.uncovered,
            "nothing_opens_them": s.unhandled,
            "rules": engine.store.rules.count,
            "awaiting_decision": engine.store.pending.count,
            "pending_proposals": queue.awaitingApproval().count,
        ]
    }

    // MARK: - Rules

    func rules() -> [[String: Any]] { engine.store.rules.map(describe) }

    func describe(_ r: Rule) -> [String: Any] {
        var scope: [String: Any]
        switch r.scope {
        case .category(let id): scope = ["kind": "category", "category": id]
        case .subgroup(let c, let g): scope = ["kind": "subgroup", "category": c, "subgroup": g]
        case .explicit(let t): scope = ["kind": "explicit", "targets": t.map(\.key)]
        }
        return [
            "id": r.id.uuidString,
            "name": r.name,
            "scope": scope,
            "app": r.appName,
            "bundle_id": r.appID,
            "priority": r.priority,
            "enabled": r.isEnabled,
            "type_count": r.targets(in: engine.catalog, custom: engine.store.customCategories).count,
            "excluded": r.exclusions.map(\.key),
        ]
    }

    /// What a caller wants a rule to be. Every field is optional on update, so
    /// changing only the app leaves the scope and the exclusions alone.
    struct RuleRequest {
        var name: String?
        var scope: Rule.Scope?
        var appQuery: String?
        var priority: Int?
        var isEnabled: Bool?
        var exclusions: [Target]?
    }

    /// Save a rule. This deliberately changes no file associations.
    ///
    /// A rule is a statement of intent; the system state is a separate thing that
    /// Wildcard compares against it. Writing one here makes types show as covered
    /// or drifted in the window — it does not touch LaunchServices, which stays
    /// reachable only through `propose`.
    func createRule(_ request: RuleRequest) throws -> Rule {
        try requireAgentAccess()
        guard let scope = request.scope else { throw ServiceError.ruleNeedsScope }
        try validate(scope)
        guard let query = request.appQuery else { throw ServiceError.ruleNeedsApp }
        guard let app = engine.inventory.resolve(query) else { throw ServiceError.noSuchApp(query) }

        let rule = Rule(
            name: request.name?.isEmpty == false ? request.name! : defaultRuleName(scope: scope, app: app),
            scope: scope,
            appID: app.id,
            appName: app.name,
            priority: request.priority ?? 0,
            isEnabled: request.isEnabled ?? true,
            exclusions: Set(request.exclusions ?? []))
        engine.store.upsert(rule: rule)
        engine.refresh()
        return rule
    }

    func updateRule(id: String, _ request: RuleRequest) throws -> Rule {
        try requireAgentAccess()
        guard let uuid = UUID(uuidString: id), var rule = engine.store.rule(id: uuid) else {
            throw ServiceError.noSuchRule(id)
        }
        if let name = request.name, !name.isEmpty { rule.name = name }
        if let scope = request.scope {
            try validate(scope)
            rule.scope = scope
        }
        if let query = request.appQuery {
            guard let app = engine.inventory.resolve(query) else { throw ServiceError.noSuchApp(query) }
            rule.appID = app.id.lowercased()
            rule.appName = app.name
        }
        if let priority = request.priority { rule.priority = priority }
        if let enabled = request.isEnabled { rule.isEnabled = enabled }
        if let exclusions = request.exclusions { rule.exclusions = Set(exclusions) }

        engine.store.upsert(rule: rule)
        engine.refresh()
        return rule
    }

    /// Remove a rule and hand back exactly what it was, so a caller that deleted
    /// the wrong one can put it back. Deleting changes no associations either:
    /// whatever those types open with today, they still open with afterwards.
    @discardableResult
    func deleteRule(id: String) throws -> Rule {
        try requireAgentAccess()
        guard let uuid = UUID(uuidString: id), let rule = engine.store.rule(id: uuid) else {
            throw ServiceError.noSuchRule(id)
        }
        engine.store.deleteRule(id: uuid)
        engine.refresh()
        return rule
    }

    /// A scope naming a category that does not exist would silently claim
    /// nothing, and read as a working rule in the list. Refuse it instead.
    private func validate(_ scope: Rule.Scope) throws {
        switch scope {
        case .category(let id):
            _ = try targets(forCategory: id)
        case .subgroup(let categoryID, let subgroupID):
            guard let c = engine.catalog.category(id: categoryID) else {
                throw ServiceError.noSuchCategory(categoryID)
            }
            guard c.subgroups.contains(where: { $0.id == subgroupID }) else {
                throw ServiceError.noSuchSubgroup(category: categoryID, subgroup: subgroupID)
            }
        case .explicit(let targets):
            guard !targets.isEmpty else { throw ServiceError.noTargets }
        }
    }

    private func defaultRuleName(scope: Rule.Scope, app: InstalledApp) -> String {
        switch scope {
        case .category(let id):
            let name = engine.catalog.category(id: id)?.name
                ?? engine.store.customCategories.first { $0.id == id }?.name ?? id
            return "\(name) → \(app.name)"
        case .subgroup(let categoryID, let subgroupID):
            let name = engine.catalog.category(id: categoryID)?
                .subgroups.first { $0.id == subgroupID }?.name ?? subgroupID
            return "\(name) → \(app.name)"
        case .explicit(let targets):
            return "\(targets.count) types → \(app.name)"
        }
    }

    // MARK: - The only write path

    struct ProposalRequest {
        var title: String
        var targets: [Target]
        var appQuery: String?     // nil means "hand back to macOS"
        var source: ChangeSource
        var note: String?
    }

    enum ServiceError: LocalizedError {
        case noSuchApp(String)
        case noTargets
        case noSuchCategory(String)
        case noSuchSubgroup(category: String, subgroup: String)
        case noSuchProposal(String)
        case noSuchHistoryEntry(String)
        case noSuchSnapshot(String)
        case noSuchRule(String)
        case ruleNeedsScope
        case ruleNeedsApp
        case agentAccessDisabled

        var errorDescription: String? {
            switch self {
            case .noSuchApp(let q):
                return "No installed application matches “\(q)”. Use list_applications to see what is available."
            case .noTargets:
                return "That would not change anything — no file types or link types were selected."
            case .noSuchCategory(let id):
                return "There is no category called “\(id)”."
            case .noSuchSubgroup(let category, let subgroup):
                return "The category “\(category)” has no subgroup called “\(subgroup)”. "
                     + "Use get_category to see its subgroups."
            case .noSuchProposal(let id):
                return "There is no proposal with id \(id)."
            case .noSuchHistoryEntry(let id):
                return "There is no history entry with id \(id)."
            case .noSuchSnapshot(let id):
                return "There is no snapshot with id \(id)."
            case .noSuchRule(let id):
                return "There is no rule with id \(id). Use list_rules to see them."
            case .ruleNeedsScope:
                return "A rule needs something to cover: give a category, a category and subgroup, or a list of types."
            case .ruleNeedsApp:
                return "A rule needs an application to point at."
            case .agentAccessDisabled:
                return "Agent access is switched off, so Wildcard cannot be operated from outside the app. "
                     + "Turn on “Let agents operate Wildcard” in Wildcard → Settings → Integrations."
            }
        }
    }

    /// Build a proposal, queue it, and bring the window forward. Applies nothing.
    func propose(_ request: ProposalRequest) throws -> Proposal {
        // The gate lives here, on the write path itself, rather than only in the
        // MCP server: an agent with a shell can run this binary directly, and a
        // switch with a way around it is not a switch.
        try requireAgentAccess()
        guard !request.targets.isEmpty else { throw ServiceError.noTargets }

        var app: InstalledApp?
        if let q = request.appQuery {
            guard let found = engine.inventory.resolve(q) else { throw ServiceError.noSuchApp(q) }
            app = found
        }

        let proposal = engine.makeProposal(
            title: request.title,
            targets: request.targets,
            to: app,
            source: request.source,
            note: request.note)

        try queue.write(proposal)
        raiseApp(proposalID: proposal.id)
        return proposal
    }

    /// Build the undo without queueing it, for showing someone what it would do.
    ///
    /// Looking is not asking. Without this, the only way to see an undo's diff is
    /// to queue it, which puts an approval sheet on screen and leaves a decision
    /// hanging over a question that was never more than "what would this do?".
    func previewRollback(historyID: String) throws -> Proposal {
        guard let entry = engine.store.historyEntry(id: historyID) else {
            throw ServiceError.noSuchHistoryEntry(historyID)
        }
        guard let proposal = engine.makeRollbackProposal(for: entry) else {
            throw ServiceError.noTargets
        }
        return proposal
    }

    func proposeRollback(historyID: String) throws -> Proposal {
        try requireAgentAccess()
        let proposal = try previewRollback(historyID: historyID)
        try queue.write(proposal)
        raiseApp(proposalID: proposal.id)
        return proposal
    }

    func previewRestore(snapshotID: String) throws -> Proposal {
        guard let snap = engine.store.snapshot(id: snapshotID) else {
            throw ServiceError.noSuchSnapshot(snapshotID)
        }
        return engine.makeRestoreProposal(for: snap)
    }

    func proposeRestore(snapshotID: String) throws -> Proposal {
        try requireAgentAccess()
        let proposal = try previewRestore(snapshotID: snapshotID)
        try queue.write(proposal)
        raiseApp(proposalID: proposal.id)
        return proposal
    }

    /// Ask Wildcard to come forward showing this proposal. Dogfoods the URL
    /// scheme handling the app is for.
    private func raiseApp(proposalID: String) {
        guard let url = URL(string: "wildcard://proposal/\(proposalID)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Target resolution

    /// Turn what an agent or a person typed into concrete targets.
    /// Accepts `ext:kt`, `.kt`, `kt`, `scheme:http`, `http:`.
    static func parseTargets(_ raw: [String]) -> [Target] {
        var out: [Target] = []
        for token in raw {
            let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if let key = Target(key: t) { out.append(key); continue }
            if t.hasSuffix(":") { out.append(.urlScheme(String(t.dropLast()).lowercased())); continue }
            out.append(.fileType(normalizing: t))
        }
        return out
    }

    func targets(forCategory id: String) throws -> [Target] {
        if let c = engine.catalog.category(id: id) { return c.targets }
        if let c = engine.store.customCategories.first(where: { $0.id == id }) { return c.targets }
        throw ServiceError.noSuchCategory(id)
    }

    // MARK: - History

    func history(limit: Int) -> [[String: Any]] {
        engine.store.history.prefix(limit).map { e in
            [
                "id": e.id,
                "title": e.title,
                "source": e.source.label,
                "applied_at": ISO8601DateFormatter().string(from: e.appliedAt),
                "changed": e.appliedCount,
                "failed": e.failedCount,
                "can_roll_back": e.canRollBack,
                "rolled_back": e.rolledBackAt != nil,
                // What it actually did, not just how many. Without this the only
                // way to answer "what did that change?" is to propose undoing it,
                // which puts an approval sheet in front of someone who asked a
                // question.
                "changes": e.items.filter { !$0.isNoOp }.map { item in
                    [
                        "target": item.target.key,
                        "display": item.target.display,
                        "from": item.fromApp?.name ?? "nothing",
                        "to": item.toApp?.name ?? "macOS default",
                    ]
                },
            ]
        }
    }

    func snapshots() -> [[String: Any]] {
        engine.store.snapshots.map { s in
            [
                "id": s.id,
                "name": s.name,
                "created_at": ISO8601DateFormatter().string(from: s.createdAt),
                "automatic": s.isAutomatic,
                "binding_count": s.count,
            ]
        }
    }

    func describe(_ p: Proposal) -> [String: Any] {
        [
            "id": p.id,
            "title": p.title,
            "status": p.status.rawValue,
            "summary": p.summaryLine,
            "source": p.source.label,
            "expires_at": ISO8601DateFormatter().string(from: p.expiresAt),
            "already_correct": p.alreadyCorrectCount,
            "will_change": p.effectiveItems.count,
            "changes": p.effectiveItems.map { item -> [String: Any] in
                var change: [String: Any] = [
                    "target": item.target.key,
                    "display": item.target.display,
                    "from": item.fromApp?.name ?? "nothing",
                    "from_chosen": item.fromOrigin.rawValue,
                    "to": item.toApp?.name ?? "macOS default",
                ]
                // An undo removes the binding instead of pinning the old app, so
                // "macOS default" is the mechanism, not the answer. Say which app
                // that hands it back to, where it was recorded.
                if item.toApp == nil, let back = item.expectedFallback {
                    change["to_expected"] = back.name
                }
                if !item.collateral.isEmpty { change["shares_type_with"] = item.collateral }
                return change
            },
            "warnings": p.warnings.map { ["kind": $0.kind.rawValue, "message": $0.message] },
            "results": p.results.map { r -> [String: Any] in
                switch r.outcome {
                case .applied: return ["target": r.target.key, "outcome": "applied"]
                case .unchanged: return ["target": r.target.key, "outcome": "unchanged"]
                case .failed(let why): return ["target": r.target.key, "outcome": "failed", "reason": why]
                }
            },
        ]
    }
}
