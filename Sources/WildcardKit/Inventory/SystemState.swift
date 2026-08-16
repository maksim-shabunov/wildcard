import AppKit
import Foundation
import UniformTypeIdentifiers

/// The current association picture: what opens what, and whether anyone chose it.
///
/// Explicit bindings are read straight from the LaunchServices preference file
/// rather than asked of `NSWorkspace`, for two reasons: Wildcard writes that file
/// so it is always the freshest source, and `NSWorkspace` caches handler lookups
/// for the lifetime of a process (verified — a live process keeps reporting the
/// old app after a successful change). Implicit defaults still come from
/// `NSWorkspace`, but those only move when applications are installed or removed.
public final class SystemState: @unchecked Sendable {

    public private(set) var bindings: [Target: Assignment] = [:]
    public let inventory: AppInventory
    private let db = LSDatabase()

    public init(inventory: AppInventory) {
        self.inventory = inventory
    }

    /// Extensions covered by a declared content type — used to map content-type
    /// rows back onto the extensions a person actually thinks in.
    public static func extensions(forType uti: String) -> [String] {
        guard let t = UTType(uti), let tags = t.tags[.filenameExtension] else { return [] }
        return tags.map { Target.normalizedExtension($0) }
    }

    /// Extensions that share a target's content type. When this is larger than
    /// one, a content-type binding has collateral reach and the UI must say so.
    public static func siblings(of ext: String) -> [String] {
        guard let r = TypeResolution.resolve(ext: ext), !r.isDynamic else { return [] }
        return extensions(forType: r.identifier).filter { $0 != ext.lowercased() }
    }

    public func refresh(targets: [Target]) {
        let explicit = db.explicitBindings(extensionsForType: Self.extensions(forType:))
        var out: [Target: Assignment] = [:]
        out.reserveCapacity(targets.count)

        for target in targets {
            if let bundleID = explicit[target] {
                let app = inventory.app(id: bundleID)
                out[target] = Assignment(
                    target: target,
                    handler: app?.ref ?? AppRef(id: bundleID, name: Self.friendlyName(forMissing: bundleID)),
                    origin: .explicit
                )
            } else if let url = Self.systemHandler(for: target) {
                out[target] = Assignment(target: target, handler: Self.ref(for: url, inventory: inventory), origin: .implicit)
            } else {
                out[target] = Assignment(target: target, handler: nil, origin: .none)
            }
        }
        bindings = out
    }

    public func binding(for target: Target) -> Assignment {
        bindings[target] ?? Assignment(target: target, handler: nil, origin: .none)
    }

    // MARK: - Helpers

    /// What macOS says opens this, right now, in *this* process.
    ///
    /// Public because the helper's `resolve` command is the only honest way to
    /// check a change: `NSWorkspace` caches its answer for the life of a process,
    /// so a fresh one has to be asked.
    public static func systemHandler(for target: Target) -> URL? {
        switch target {
        case .fileType(let ext):
            guard let t = UTType(filenameExtension: ext) else { return nil }
            return NSWorkspace.shared.urlForApplication(toOpen: t)
        case .urlScheme(let s):
            guard let u = URL(string: "\(s):") else { return nil }
            return NSWorkspace.shared.urlForApplication(toOpen: u)
        }
    }

    static func ref(for url: URL, inventory: AppInventory) -> AppRef {
        if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
           let known = inventory.app(id: id) {
            return known.ref
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        let id = Bundle(url: url)?.bundleIdentifier ?? url.lastPathComponent
        return AppRef(id: id, name: name, path: url.path)
    }

    /// A binding can name an application that is no longer installed.
    static func friendlyName(forMissing bundleID: String) -> String {
        let tail = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return tail.prefix(1).uppercased() + tail.dropFirst() + " (not installed)"
    }
}
