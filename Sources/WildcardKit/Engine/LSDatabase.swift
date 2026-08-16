import Foundation

/// Direct reader/writer for the LaunchServices handler preferences.
///
/// Why not `NSWorkspace.setDefaultApplication`? On macOS 26 that API raises a
/// system confirmation dialog for *every* change, returning `userCanceledErr`
/// (-128) when it is not answered. Assigning a whole category would mean
/// hundreds of dialogs, so it cannot express what this app is for.
///
/// Writing the preference domain directly and restarting `lsd` applies an
/// entire batch behind Wildcard's own single confirmation. This is the
/// long-established mechanism used by `duti` and SwiftDefaultApps.
///
/// Verified on macOS 26.5: batch write -> `killall lsd` -> handlers resolve to
/// the new app in a freshly launched process.
public struct LSDatabase: Sendable {

    public static let domain = "com.apple.LaunchServices/com.apple.launchservices.secure"
    private static let handlersKey = "LSHandlers"

    public init() {}

    // MARK: - Entry

    /// One row of the `LSHandlers` array. Unknown keys are preserved verbatim so
    /// Wildcard never destroys state written by macOS or another tool. That
    /// `extra` dictionary is why this is not `Sendable`; entries never leave the
    /// call that produced them.
    public struct Entry {
        public enum Form: Sendable, Hashable {
            /// Bound by declared content type — `LSHandlerContentType`.
            case contentType(String)
            /// Bound by filename extension — `LSHandlerContentTag`. This is what
            /// macOS itself uses for extensions with no declared type.
            case contentTag(ext: String)
            case urlScheme(String)
        }

        public var form: Form
        public var roleAll: String?
        public var extra: [String: Any]

        public init(form: Form, roleAll: String?, extra: [String: Any] = [:]) {
            self.form = form
            self.roleAll = roleAll
            self.extra = extra
        }

        var dictionary: [String: Any] {
            var d = extra
            switch form {
            case .contentType(let uti):
                d["LSHandlerContentType"] = uti
                d.removeValue(forKey: "LSHandlerContentTag")
                d.removeValue(forKey: "LSHandlerContentTagClass")
            case .contentTag(let ext):
                d["LSHandlerContentTag"] = ext
                d["LSHandlerContentTagClass"] = "public.filename-extension"
                d.removeValue(forKey: "LSHandlerContentType")
            case .urlScheme(let s):
                d["LSHandlerURLScheme"] = s
            }
            if let roleAll {
                d["LSHandlerRoleAll"] = roleAll
                // Some rows carry a viewer role as well; keep it consistent so
                // the two cannot disagree about who opens the file.
                if d["LSHandlerRoleViewer"] != nil { d["LSHandlerRoleViewer"] = roleAll }
            }
            d["LSHandlerModificationDate"] = Date().timeIntervalSinceReferenceDate
            if d["LSHandlerPreferredVersions"] == nil {
                d["LSHandlerPreferredVersions"] = ["LSHandlerRoleAll": "-"]
            }
            return d
        }

        init?(dictionary d: [String: Any]) {
            var extra = d
            let role = (d["LSHandlerRoleAll"] as? String) ?? (d["LSHandlerRoleViewer"] as? String)
            if let uti = d["LSHandlerContentType"] as? String {
                form = .contentType(uti)
            } else if let tag = d["LSHandlerContentTag"] as? String {
                form = .contentTag(ext: tag.lowercased())
            } else if let scheme = d["LSHandlerURLScheme"] as? String {
                form = .urlScheme(scheme.lowercased())
            } else {
                return nil
            }
            for k in ["LSHandlerContentType", "LSHandlerContentTag", "LSHandlerContentTagClass",
                      "LSHandlerURLScheme", "LSHandlerRoleAll", "LSHandlerModificationDate"] {
                extra.removeValue(forKey: k)
            }
            self.roleAll = role
            self.extra = extra
        }
    }

    // MARK: - Read

    public func readAll() -> [Entry] {
        let raw = CFPreferencesCopyAppValue(Self.handlersKey as CFString, Self.domain as CFString)
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap(Entry.init(dictionary:))
    }

    /// Every explicit binding, keyed by target. Content-type rows are mapped back
    /// onto the extensions they cover so the caller can think in extensions.
    public func explicitBindings(extensionsForType: (String) -> [String]) -> [Target: String] {
        var out: [Target: String] = [:]
        for e in readAll() {
            guard let role = e.roleAll, !role.isEmpty, role != "-" else { continue }
            switch e.form {
            case .contentTag(let ext):
                out[.fileType(ext: ext)] = role
            case .urlScheme(let s):
                out[.urlScheme(s)] = role
            case .contentType(let uti):
                for ext in extensionsForType(uti) where out[.fileType(ext: ext)] == nil {
                    out[.fileType(ext: ext)] = role
                }
            }
        }
        return out
    }

    // MARK: - Write

    public enum WriteError: Error, LocalizedError {
        case synchronizeFailed
        public var errorDescription: String? {
            "Could not save the LaunchServices preferences."
        }
    }

    /// Apply a batch of bindings in one write. `reload()` must follow for the
    /// system to observe them.
    public func write(_ changes: [(form: Entry.Form, bundleID: String)]) throws {
        guard !changes.isEmpty else { return }
        var entries = readAll()

        for change in changes {
            if let idx = entries.firstIndex(where: { $0.form == change.form }) {
                entries[idx].roleAll = change.bundleID.lowercased()
            } else {
                entries.append(Entry(form: change.form, roleAll: change.bundleID.lowercased()))
            }
        }

        let array = entries.map(\.dictionary) as CFArray
        CFPreferencesSetAppValue(Self.handlersKey as CFString, array, Self.domain as CFString)
        guard CFPreferencesAppSynchronize(Self.domain as CFString) else {
            throw WriteError.synchronizeFailed
        }
    }

    /// Remove bindings entirely, returning a target to whatever macOS would
    /// choose on its own. Used when undoing a change whose previous origin
    /// was `.implicit` or `.none`.
    public func remove(_ forms: [Entry.Form]) throws {
        guard !forms.isEmpty else { return }
        let set = Set(forms)
        let kept = readAll().filter { !set.contains($0.form) }
        CFPreferencesSetAppValue(Self.handlersKey as CFString, kept.map(\.dictionary) as CFArray,
                                 Self.domain as CFString)
        guard CFPreferencesAppSynchronize(Self.domain as CFString) else {
            throw WriteError.synchronizeFailed
        }
    }

    /// Restart the LaunchServices daemon so it re-reads the preferences.
    ///
    /// `lsd` runs as the user and launchd restarts it immediately, so this needs
    /// no privileges. Without it, writes sit on disk unobserved.
    @discardableResult
    public func reload() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["lsd"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        // Give launchd a moment to bring it back before anything reads.
        Thread.sleep(forTimeInterval: 1.2)
        return p.terminationStatus == 0
    }

    /// Choose the binding form for a target.
    ///
    /// Extensions with a *declared* type bind by content type. Extensions macOS
    /// only knows dynamically must bind by extension tag — and so must extensions
    /// whose declared type is shared with unrelated formats (`.ts` resolves to
    /// `public.mpeg-2-transport-stream`), where a content-type binding would drag
    /// genuine video files along with it.
    public static func form(for target: Target, narrowBinding: Bool) -> Entry.Form {
        switch target {
        case .urlScheme(let s):
            return .urlScheme(s.lowercased())
        case .fileType(let ext):
            let e = ext.lowercased()
            guard !narrowBinding, let r = TypeResolution.resolve(ext: e), !r.isDynamic else {
                return .contentTag(ext: e)
            }
            return .contentType(r.identifier)
        }
    }
}
