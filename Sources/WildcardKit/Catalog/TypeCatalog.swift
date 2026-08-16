import Foundation

public enum CategoryKind: String, Sendable, Codable {
    case file
    case scheme
}

public struct CatalogType: Sendable, Hashable, Identifiable, Codable {
    public let ext: String        // extension, or scheme name for scheme categories
    public let name: String       // "Kotlin source"
    public var id: String { ext }
}

public struct CatalogSubgroup: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let types: [CatalogType]
}

public struct CatalogCategory: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let kind: CategoryKind
    public let icon: String
    public let summary: String
    public let subgroups: [CatalogSubgroup]

    public var types: [CatalogType] { subgroups.flatMap(\.types) }
    public var targets: [Target] {
        types.map { kind == .file ? .fileType(ext: $0.ext) : .urlScheme($0.ext) }
    }
    public var count: Int { subgroups.reduce(0) { $0 + $1.types.count } }
}

/// The curated knowledge that means the user never has to write an extension
/// list by hand — including the obscure ones nobody remembers.
public final class TypeCatalog: @unchecked Sendable {

    public private(set) var categories: [CatalogCategory] = []

    /// extension -> (category, human name). Built once, used everywhere.
    private var index: [String: (category: CatalogCategory, type: CatalogType)] = [:]

    public static let shared = TypeCatalog()

    public init() { load() }

    public var fileCategories: [CatalogCategory] { categories.filter { $0.kind == .file } }
    public var schemeCategories: [CatalogCategory] { categories.filter { $0.kind == .scheme } }

    public func category(id: String) -> CatalogCategory? { categories.first { $0.id == id } }

    /// The category an extension belongs to, if the catalog knows it.
    public func category(forExtension ext: String) -> CatalogCategory? {
        index[Target.normalizedExtension(ext)]?.category
    }

    public func displayName(for target: Target) -> String? {
        index[target.raw.lowercased()]?.type.name
    }

    /// Human label for a target, falling back to something readable rather than
    /// a bare extension: ".kt" -> "Kotlin source", ".xyz" -> "XYZ file".
    public func label(for target: Target) -> String {
        if let n = displayName(for: target) { return n }
        switch target {
        case .fileType(let e): return "\(e.uppercased()) file"
        case .urlScheme(let s): return "\(s): links"
        }
    }

    public func search(_ query: String, limit: Int = 60) -> [(Target, String, CatalogCategory)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var out: [(Target, String, CatalogCategory)] = []
        for (ext, entry) in index {
            let matches = ext.hasPrefix(q) || entry.type.name.lowercased().contains(q)
                || entry.category.name.lowercased().contains(q)
            guard matches else { continue }
            let t: Target = entry.category.kind == .file ? .fileType(ext: ext) : .urlScheme(ext)
            out.append((t, entry.type.name, entry.category))
        }
        return Array(out.sorted { $0.0.raw < $1.0.raw }.prefix(limit))
    }

    public var allTargets: [Target] { categories.flatMap(\.targets) }

    // MARK: - Loading

    /// Where `catalog.json` is, whoever is asking.
    ///
    /// Three very different callers load it: the app (`Contents/Resources`), the
    /// helper binary sitting beside the app in `Contents/Helpers`, and `swift
    /// build` runs and tests where SwiftPM leaves a `Wildcard_WildcardKit.bundle`
    /// next to the executable. `Bundle.module` only covers the last of those and
    /// traps outright when it is wrong, so the search is done by hand.
    static func catalogURL() -> URL? {
        let fm = FileManager.default
        if let direct = Bundle.main.url(forResource: "catalog", withExtension: "json") {
            return direct
        }

        var bases: [URL] = []
        if let r = Bundle.main.resourceURL { bases.append(r) }
        bases.append(Bundle.main.bundleURL)
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            bases.append(exe)                                          // build dir, or Contents/Helpers
            bases.append(exe.deletingLastPathComponent()
                .appendingPathComponent("Resources"))                  // helper -> Contents/Resources
        }
        let token = Bundle(for: CatalogToken.self)
        bases.append(token.bundleURL)
        bases.append(token.bundleURL.deletingLastPathComponent())       // test bundle -> build dir
        if let r = token.resourceURL { bases.append(r) }

        for base in bases {
            for candidate in [base.appendingPathComponent("catalog.json"),
                              base.appendingPathComponent("Wildcard_WildcardKit.bundle/catalog.json"),
                              base.appendingPathComponent("Wildcard_WildcardKit.bundle/Contents/Resources/catalog.json")]
            where fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private struct File: Decodable {
        let version: Int
        let categories: [Raw]
        struct Raw: Decodable {
            let id: String
            let name: String
            let kind: CategoryKind
            let icon: String
            let summary: String
            let subgroups: [RawGroup]
        }
        struct RawGroup: Decodable {
            let id: String
            let name: String
            let types: [String: String]
        }
    }

    private func load() {
        guard let url = Self.catalogURL(),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            assertionFailure("catalog.json missing or malformed")
            return
        }

        categories = file.categories.map { raw in
            CatalogCategory(
                id: raw.id, name: raw.name, kind: raw.kind, icon: raw.icon, summary: raw.summary,
                subgroups: raw.subgroups.map { g in
                    CatalogSubgroup(
                        id: g.id, name: g.name,
                        types: g.types
                            .map { CatalogType(ext: $0.key.lowercased(), name: $0.value) }
                            .sorted { $0.ext < $1.ext }
                    )
                }
            )
        }

        var idx: [String: (CatalogCategory, CatalogType)] = [:]
        for c in categories {
            for t in c.types where idx[t.ext] == nil {
                idx[t.ext] = (c, t)
            }
        }
        index = idx
    }
}

/// Only exists so `Bundle(for:)` can name the framework this code was linked
/// into, for the resource search above.
private final class CatalogToken {}
