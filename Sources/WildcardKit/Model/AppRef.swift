import Foundation

/// A reference to an application, identified by bundle id.
///
/// LaunchServices stores handler bundle ids lower-cased, so `id` is always
/// normalised and `matches(_:)` should be used for comparison.
public struct AppRef: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let path: String?

    public init(id: String, name: String, path: String? = nil) {
        self.id = id.lowercased()
        self.name = name
        self.path = path
    }

    public func matches(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID.lowercased() == id
    }

    public var url: URL? { path.map { URL(fileURLWithPath: $0) } }
}

/// Where a binding came from — the distinction that makes undo honest.
public enum BindingOrigin: String, Sendable, Codable {
    /// Present in the LaunchServices preference file: someone chose this.
    case explicit
    /// No stored preference; LaunchServices picked whichever app claimed it.
    case implicit
    /// Nothing opens this at all.
    case none
}

/// What opens a target, and whether anyone chose it.
///
/// Named `Assignment` rather than `Binding` so it does not collide with
/// SwiftUI's property wrapper everywhere in the interface layer.
public struct Assignment: Hashable, Sendable, Codable {
    public let target: Target
    public let handler: AppRef?
    public let origin: BindingOrigin

    public init(target: Target, handler: AppRef?, origin: BindingOrigin) {
        self.target = target
        self.handler = handler
        self.origin = origin
    }
}
