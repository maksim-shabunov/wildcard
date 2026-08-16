import AppKit
import Foundation
import UniformTypeIdentifiers

/// What an installed application says it can open.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public let id: String          // lower-cased bundle id
    public let name: String
    public let path: String
    public let declaredExtensions: Set<String>
    public let declaredSchemes: Set<String>
    public let isSystem: Bool

    public var ref: AppRef { AppRef(id: id, name: name, path: path) }
    public var url: URL { URL(fileURLWithPath: path) }
}

/// Scans installed applications for everything they declare they can open.
///
/// This is what lets Wildcard show associations the user never consciously set:
/// the union of what apps claim, what the catalog knows, and what already has a
/// stored binding. Measured at ~0.06s for a full scan, so it is re-run freely.
public final class AppInventory: @unchecked Sendable {

    public private(set) var apps: [InstalledApp] = []
    public private(set) var allDeclaredExtensions: Set<String> = []
    public private(set) var allDeclaredSchemes: Set<String> = []

    private var byID: [String: InstalledApp] = [:]

    public static let searchPaths: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    public init() {}

    public func app(id: String) -> InstalledApp? { byID[id.lowercased()] }

    /// Resolve a user-typed app name ("Cursor", "cursor.app", a bundle id, a path)
    /// to an installed app. Used by the CLI and the MCP layer.
    public func resolve(_ query: String) -> InstalledApp? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return nil }
        if let exact = byID[q.lowercased()] { return exact }
        if q.hasPrefix("/"), let a = apps.first(where: { $0.path == q || $0.path == q + ".app" }) { return a }
        let stripped = q.hasSuffix(".app") ? String(q.dropLast(4)) : q
        let lowered = stripped.lowercased()
        if let byName = apps.first(where: { $0.name.lowercased() == lowered }) { return byName }
        return apps.first { $0.name.lowercased().hasPrefix(lowered) }
    }

    @discardableResult
    public func scan() -> [InstalledApp] {
        var found: [String: InstalledApp] = [:]
        var exts = Set<String>()
        var schemes = Set<String>()
        let fm = FileManager.default

        for dir in Self.searchPaths {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = "\(dir)/\(item)"
                guard let app = Self.read(bundleAt: path) else { continue }
                // First one wins: /Applications shadows /System/Applications.
                if found[app.id] == nil { found[app.id] = app }
                exts.formUnion(app.declaredExtensions)
                schemes.formUnion(app.declaredSchemes)
            }
        }

        let list = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.apps = list
        self.byID = found
        self.allDeclaredExtensions = exts
        self.allDeclaredSchemes = schemes
        return list
    }

    // MARK: - Bundle reading

    private static func read(bundleAt path: String) -> InstalledApp? {
        let plistPath = "\(path)/Contents/Info.plist"
        guard let d = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
              let bundleID = d["CFBundleIdentifier"] as? String, !bundleID.isEmpty
        else { return nil }

        var exts = Set<String>()
        var schemes = Set<String>()

        if let docTypes = d["CFBundleDocumentTypes"] as? [[String: Any]] {
            for dt in docTypes {
                if let e = dt["CFBundleTypeExtensions"] as? [String] {
                    exts.formUnion(e.map { Target.normalizedExtension($0) })
                }
                if let types = dt["LSItemContentTypes"] as? [String] {
                    for id in types {
                        guard let t = UTType(id), let tags = t.tags[.filenameExtension] else { continue }
                        exts.formUnion(tags.map { Target.normalizedExtension($0) })
                    }
                }
            }
        }
        for key in ["UTExportedTypeDeclarations", "UTImportedTypeDeclarations"] {
            guard let decls = d[key] as? [[String: Any]] else { continue }
            for decl in decls {
                guard let tags = decl["UTTypeTagSpecification"] as? [String: Any],
                      let raw = tags["public.filename-extension"] else { continue }
                if let one = raw as? String { exts.insert(Target.normalizedExtension(one)) }
                if let many = raw as? [String] { exts.formUnion(many.map { Target.normalizedExtension($0) }) }
            }
        }
        if let urlTypes = d["CFBundleURLTypes"] as? [[String: Any]] {
            for ut in urlTypes {
                if let s = ut["CFBundleURLSchemes"] as? [String] {
                    schemes.formUnion(s.map { $0.lowercased() })
                }
            }
        }

        exts = exts.filter(isPlausibleExtension)
        schemes = schemes.filter { !$0.isEmpty && $0.count <= 40 }

        let name = (d["CFBundleDisplayName"] as? String)
            ?? (d["CFBundleName"] as? String)
            ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")

        return InstalledApp(
            id: bundleID.lowercased(),
            name: name,
            path: path,
            declaredExtensions: exts,
            declaredSchemes: schemes,
            isSystem: path.hasPrefix("/System/")
        )
    }

    /// Bundles declare junk — `*`, `000`–`015`, whole filenames. Keep what could
    /// plausibly be an extension a person would recognise.
    private static func isPlausibleExtension(_ e: String) -> Bool {
        guard !e.isEmpty, e.count <= 12 else { return false }
        guard e.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "-+"))) == nil
        else { return false }
        // Purely numeric "extensions" are codec part-files, not user-facing types.
        if e.allSatisfy(\.isNumber) { return false }
        return true
    }

    // MARK: - Candidates

    /// Applications LaunchServices considers able to open a target.
    public static func candidates(for target: Target) -> [URL] {
        switch target {
        case .fileType(let ext):
            guard let t = UTType(filenameExtension: ext) else { return [] }
            return NSWorkspace.shared.urlsForApplications(toOpen: t)
        case .urlScheme(let s):
            guard let u = URL(string: "\(s):") else { return [] }
            return NSWorkspace.shared.urlsForApplications(toOpen: u)
        }
    }
}
