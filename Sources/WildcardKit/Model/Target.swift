import Foundation
import UniformTypeIdentifiers

/// One addressable thing whose default application can be set.
///
/// The file-extension case is the canonical unit rather than the UTI, because
/// many extensions have no declared type at all (`.kt`, `.rs`, `.toml`); macOS
/// invents a `dyn.*` identifier for those. Keying on the extension keeps the
/// model stable and lets the engine choose the right binding form at apply time.
public enum Target: Hashable, Sendable, Codable {
    case fileType(ext: String)
    case urlScheme(String)

    public var raw: String {
        switch self {
        case .fileType(let e): return e
        case .urlScheme(let s): return s
        }
    }

    public var isFileType: Bool {
        if case .fileType = self { return true }
        return false
    }

    /// Stable string key used in the store and over the wire: `ext:kt`, `scheme:mailto`.
    public var key: String {
        switch self {
        case .fileType(let e): return "ext:\(e)"
        case .urlScheme(let s): return "scheme:\(s)"
        }
    }

    public init?(key: String) {
        if key.hasPrefix("ext:") { self = .fileType(ext: String(key.dropFirst(4))) }
        else if key.hasPrefix("scheme:") { self = .urlScheme(String(key.dropFirst(7))) }
        else { return nil }
    }

    /// How this target reads in the interface: ".kt" or "mailto:".
    public var display: String {
        switch self {
        case .fileType(let e): return ".\(e)"
        case .urlScheme(let s): return "\(s):"
        }
    }

    public static func normalizedExtension(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasPrefix("*") { s.removeFirst() }
        while s.hasPrefix(".") { s.removeFirst() }
        return s
    }

    public static func fileType(normalizing raw: String) -> Target {
        .fileType(ext: normalizedExtension(raw))
    }
}

extension Target: Comparable {
    public static func < (a: Target, b: Target) -> Bool {
        if a.isFileType != b.isFileType { return a.isFileType }
        return a.raw < b.raw
    }
}

/// Resolution of an extension to a system content type.
public struct TypeResolution: Sendable, Hashable {
    public let identifier: String
    /// True when macOS invented the identifier because nothing declares this
    /// extension. Those must be bound by extension tag, not by content type.
    public let isDynamic: Bool

    public init(identifier: String, isDynamic: Bool) {
        self.identifier = identifier
        self.isDynamic = isDynamic
    }

    public static func resolve(ext: String) -> TypeResolution? {
        guard let t = UTType(filenameExtension: ext) else { return nil }
        return TypeResolution(identifier: t.identifier, isDynamic: t.identifier.hasPrefix("dyn."))
    }
}
