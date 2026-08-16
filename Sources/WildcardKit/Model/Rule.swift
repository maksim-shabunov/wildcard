import Foundation

/// A standing intent: *this set of types should open with this app*.
///
/// Rules are what the user means; system state is what actually happened. Keeping
/// them apart is what lets Wildcard notice that something else changed a binding
/// behind your back, instead of silently accepting it.
public struct Rule: Identifiable, Hashable, Codable, Sendable {

    public enum Scope: Hashable, Codable, Sendable {
        /// Everything in a shipped or custom category.
        case category(id: String)
        /// One named subgroup of a category ("Code › Shell and terminal").
        case subgroup(categoryID: String, subgroupID: String)
        /// A hand-picked list.
        case explicit(targets: [Target])
    }

    public var id: UUID
    public var name: String
    public var scope: Scope
    public var appID: String          // bundle identifier, lower-cased
    public var appName: String        // remembered so a missing app still reads sensibly
    public var priority: Int          // higher wins where two rules overlap
    public var isEnabled: Bool
    /// Types the user has deliberately taken out of this rule.
    public var exclusions: Set<Target>
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        scope: Scope,
        appID: String,
        appName: String,
        priority: Int = 0,
        isEnabled: Bool = true,
        exclusions: Set<Target> = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.appID = appID.lowercased()
        self.appName = appName
        self.priority = priority
        self.isEnabled = isEnabled
        self.exclusions = exclusions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The targets this rule claims, resolved against the catalog.
    public func targets(in catalog: TypeCatalog, custom: [CustomCategory] = []) -> [Target] {
        let resolved: [Target]
        switch scope {
        case .explicit(let list):
            resolved = list
        case .category(let id):
            if let c = catalog.category(id: id) {
                resolved = c.targets
            } else if let c = custom.first(where: { $0.id == id }) {
                resolved = c.targets
            } else {
                resolved = []
            }
        case .subgroup(let categoryID, let subgroupID):
            guard let c = catalog.category(id: categoryID),
                  let g = c.subgroups.first(where: { $0.id == subgroupID })
            else { return [] }
            resolved = g.types.map { c.kind == .file ? .fileType(ext: $0.ext) : .urlScheme($0.ext) }
        }
        return resolved.filter { !exclusions.contains($0) }
    }

    public var scopeDescription: String {
        switch scope {
        case .category: return "category"
        case .subgroup: return "group"
        case .explicit(let t): return "\(t.count) chosen types"
        }
    }
}

/// A category the user made. Stored separately from the shipped catalog so an
/// update to `catalog.json` can never overwrite it.
public struct CustomCategory: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var kind: CategoryKind
    public var icon: String
    public var summary: String
    public var members: [Target]

    public init(
        id: String = "custom." + UUID().uuidString.prefix(8).lowercased(),
        name: String,
        kind: CategoryKind = .file,
        icon: String = "square.grid.2x2",
        summary: String = "",
        members: [Target] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.icon = icon
        self.summary = summary
        self.members = members
    }

    public var targets: [Target] { members }
}
