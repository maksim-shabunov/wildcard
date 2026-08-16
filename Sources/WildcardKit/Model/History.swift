import Foundation

/// A record of something that was applied, with enough before-state to put it
/// back exactly as it was — including whether the previous handler was chosen
/// deliberately or merely inherited from macOS.
public struct HistoryEntry: Identifiable, Codable, Sendable {
    public var id: String
    public var title: String
    public var source: ChangeSource
    public var appliedAt: Date
    public var items: [ChangeItem]
    public var results: [ApplyResult]
    /// Set once this entry has been rolled back, so it cannot be undone twice.
    public var rolledBackAt: Date?
    public var rolledBackBy: String?

    public init(
        id: String = Proposal.newID(),
        title: String,
        source: ChangeSource,
        appliedAt: Date = Date(),
        items: [ChangeItem],
        results: [ApplyResult],
        rolledBackAt: Date? = nil,
        rolledBackBy: String? = nil
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.appliedAt = appliedAt
        self.items = items
        self.results = results
        self.rolledBackAt = rolledBackAt
        self.rolledBackBy = rolledBackBy
    }

    public var appliedCount: Int { results.filter { $0.outcome == .applied }.count }
    public var failedCount: Int { results.filter { $0.outcome.isFailure }.count }
    public var canRollBack: Bool { rolledBackAt == nil && appliedCount > 0 }

    /// The items to reverse: only the ones that actually took effect.
    public var reversibleItems: [ChangeItem] {
        let applied = Set(results.filter { $0.outcome == .applied }.map(\.target))
        return items.filter { applied.contains($0.target) }
    }
}

/// A complete capture of every explicit handler at a moment in time. Taken
/// automatically before each apply, so there is always a way back even if a
/// rollback itself goes wrong.
public struct Snapshot: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var isAutomatic: Bool
    /// target key -> bundle id. Absent means "no explicit binding at the time".
    public var bindings: [String: String]

    public init(
        id: String = Proposal.newID(),
        name: String,
        createdAt: Date = Date(),
        isAutomatic: Bool,
        bindings: [String: String]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.isAutomatic = isAutomatic
        self.bindings = bindings
    }

    public var count: Int { bindings.count }
}

/// A file type that turned up with nothing deciding where it should go.
///
/// The point of this type is the promise in the brief: a new extension is never
/// silently handed to whatever app claimed it first. Either a rule adopts it and
/// that is logged, or it waits here for a decision.
public struct PendingDecision: Identifiable, Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable {
        case newlySeen        // an app appeared that declares it
        case noRule           // in the catalog but no rule covers it
        case unknownType      // not in the catalog at all
    }

    public var id: String { target.key }
    public var target: Target
    public var reason: Reason
    public var noticedAt: Date
    public var currentHandler: AppRef?
    /// The catalog's best guess, if it has one.
    public var suggestedCategoryID: String?
    public var suggestedApp: AppRef?
    public var dismissedAt: Date?

    public init(
        target: Target,
        reason: Reason,
        noticedAt: Date = Date(),
        currentHandler: AppRef? = nil,
        suggestedCategoryID: String? = nil,
        suggestedApp: AppRef? = nil,
        dismissedAt: Date? = nil
    ) {
        self.target = target
        self.reason = reason
        self.noticedAt = noticedAt
        self.currentHandler = currentHandler
        self.suggestedCategoryID = suggestedCategoryID
        self.suggestedApp = suggestedApp
        self.dismissedAt = dismissedAt
    }
}
