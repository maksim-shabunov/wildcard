import Foundation

/// Everything Wildcard remembers, as plain JSON in Application Support.
///
/// Deliberately readable and hand-editable: this app's job is to make an opaque
/// part of the system legible, so its own state should not be opaque either.
/// Writes are atomic, and a corrupt file is renamed aside rather than deleted.
public final class Store: @unchecked Sendable {

    public struct Settings: Codable, Sendable {
        /// Adopt a new type automatically when a rule clearly covers it.
        public var autoAdoptWhenRuleMatches: Bool = true
        /// Watch application folders and notice types as they appear.
        public var watchForNewTypes: Bool = true
        /// Put a snapshot aside before every apply.
        public var snapshotBeforeApply: Bool = true
        /// Serve MCP and accept CLI proposals.
        public var agentAccessEnabled: Bool = false
        public var appearance: String = "system"   // system | light | dark
        public var lastSeenExtensions: [String] = []

        public init() {}
    }

    private struct Root: Codable {
        var version: Int = 1
        var settings = Settings()
        var rules: [Rule] = []
        var customCategories: [CustomCategory] = []
        var history: [HistoryEntry] = []
        var snapshots: [Snapshot] = []
        var pending: [PendingDecision] = []
    }

    public static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Wildcard", isDirectory: true)
    }()

    private let url: URL
    private let queue = DispatchQueue(label: "app.wildcard.store")
    private var root = Root()

    /// What was on disk the last time this process read or wrote it. Two
    /// processes share this file — the window and the agent-facing helper — so
    /// "what I have in memory" and "what is on disk" are different questions.
    private var stamp: FileStamp?
    private var lockFD: CInt = -1
    private var watcher: DispatchSourceFileSystemObject?

    /// Bumped on every mutation so the UI can observe cheaply.
    public private(set) var revision: Int = 0
    public var onChange: (@Sendable () -> Void)?

    public static let shared = Store()

    public init(url: URL? = nil) {
        self.url = url ?? Self.directory.appendingPathComponent("store.json")
        try? FileManager.default.createDirectory(
            at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        load()
    }

    deinit {
        watcher?.cancel()
        if lockFD >= 0 { close(lockFD) }
    }

    // MARK: - Reading

    public var settings: Settings { queue.sync { root.settings } }

    /// Settings as they are *now*, not as they were when this process started.
    /// The agent-facing helper is long-running and the person may have flicked a
    /// switch in the window since it launched.
    public var currentSettings: Settings {
        reloadIfChanged()
        return settings
    }
    public var rules: [Rule] { queue.sync { root.rules.sorted { $0.priority > $1.priority } } }
    public var customCategories: [CustomCategory] { queue.sync { root.customCategories } }
    public var history: [HistoryEntry] { queue.sync { root.history.sorted { $0.appliedAt > $1.appliedAt } } }
    public var snapshots: [Snapshot] { queue.sync { root.snapshots.sorted { $0.createdAt > $1.createdAt } } }
    public var pending: [PendingDecision] {
        queue.sync { root.pending.filter { $0.dismissedAt == nil }.sorted { $0.noticedAt > $1.noticedAt } }
    }

    public func historyEntry(id: String) -> HistoryEntry? { queue.sync { root.history.first { $0.id == id } } }
    public func snapshot(id: String) -> Snapshot? { queue.sync { root.snapshots.first { $0.id == id } } }
    public func rule(id: UUID) -> Rule? { queue.sync { root.rules.first { $0.id == id } } }

    // MARK: - Writing

    public func update(settings: Settings) { mutate { $0.settings = settings } }

    public func upsert(rule: Rule) {
        mutate {
            var r = rule
            r.updatedAt = Date()
            if let i = $0.rules.firstIndex(where: { $0.id == rule.id }) { $0.rules[i] = r }
            else { $0.rules.append(r) }
        }
    }

    public func deleteRule(id: UUID) { mutate { $0.rules.removeAll { $0.id == id } } }

    public func upsert(category: CustomCategory) {
        mutate {
            if let i = $0.customCategories.firstIndex(where: { $0.id == category.id }) {
                $0.customCategories[i] = category
            } else {
                $0.customCategories.append(category)
            }
        }
    }

    public func deleteCategory(id: String) {
        mutate {
            $0.customCategories.removeAll { $0.id == id }
            $0.rules.removeAll { if case .category(let c) = $0.scope { return c == id }; return false }
        }
    }

    public func append(history entry: HistoryEntry) {
        mutate {
            $0.history.append(entry)
            // Keep the list useful rather than unbounded; snapshots cover the rest.
            if $0.history.count > 500 {
                $0.history.sort { $0.appliedAt > $1.appliedAt }
                $0.history = Array($0.history.prefix(500))
            }
        }
    }

    public func markRolledBack(historyID: String, by rollbackID: String) {
        mutate {
            guard let i = $0.history.firstIndex(where: { $0.id == historyID }) else { return }
            $0.history[i].rolledBackAt = Date()
            $0.history[i].rolledBackBy = rollbackID
        }
    }

    public func append(snapshot: Snapshot) {
        mutate {
            $0.snapshots.append(snapshot)
            // Automatic snapshots are noise after a while; manual ones are kept.
            let autos = $0.snapshots.filter(\.isAutomatic).sorted { $0.createdAt > $1.createdAt }
            if autos.count > 30 {
                let drop = Set(autos.dropFirst(30).map(\.id))
                $0.snapshots.removeAll { drop.contains($0.id) }
            }
        }
    }

    public func deleteSnapshot(id: String) { mutate { $0.snapshots.removeAll { $0.id == id } } }

    public func add(pending items: [PendingDecision]) {
        guard !items.isEmpty else { return }
        mutate {
            let known = Set($0.pending.map(\.target))
            $0.pending.append(contentsOf: items.filter { !known.contains($0.target) })
        }
    }

    public func dismissPending(_ targets: [Target]) {
        let set = Set(targets)
        mutate {
            for i in $0.pending.indices where set.contains($0.pending[i].target) {
                $0.pending[i].dismissedAt = Date()
            }
        }
    }

    public func clearPending() { mutate { $0.pending.removeAll() } }

    public func rememberSeenExtensions(_ exts: Set<String>) {
        mutate { $0.settings.lastSeenExtensions = exts.sorted() }
    }

    // MARK: - Sharing the file with the other process

    /// Pick up anything the other process wrote. Returns whether it found any.
    ///
    /// Cheap enough to call on every file-system event: it compares a `stat`
    /// against the last one and only decodes when the file has actually moved on.
    @discardableResult
    public func reloadIfChanged() -> Bool {
        let changed = queue.sync { reloadIfChangedLocked() }
        if changed { onChange?() }
        return changed
    }

    /// Notice when the helper writes a rule, so it appears in the window rather
    /// than waiting for a relaunch. Watches the directory, not the file: an
    /// atomic write replaces the inode and a file watch would die with it.
    public func startWatching() {
        stopWatching()
        let dir = url.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.reloadIfChanged() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    // MARK: - Persistence

    /// Read, change, write — under a lock, and starting from what is on disk
    /// rather than from what this process last saw.
    ///
    /// Without the reload, the window and the helper each hold a whole copy of
    /// the file and the second one to save wins outright: an agent creates a
    /// rule, the person toggles a setting, and the rule is gone. Nothing would
    /// report an error, which is the worst version of that bug.
    private func mutate(_ body: (inout Root) -> Void) {
        queue.sync {
            withFileLock {
                reloadIfChangedLocked()
                body(&root)
                revision &+= 1
                save()
            }
        }
        onChange?()
    }

    @discardableResult
    private func reloadIfChangedLocked() -> Bool {
        let current = FileStamp(of: url)
        guard current != stamp else { return false }
        load()
        return true
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            root = try Self.decoder.decode(Root.self, from: data)
            stamp = FileStamp(of: url)
        } catch {
            // Never throw away someone's rules because of a decode error.
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("store-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            NSLog("Wildcard: could not read store (%@). Kept the old file at %@",
                  String(describing: error), aside.path)
            root = Root()
            stamp = nil
        }
    }

    private func save() {
        do {
            let data = try Self.encoder.encode(root)
            try data.write(to: url, options: .atomic)
            // Record what we just wrote, so our own save does not read back as
            // somebody else's change the moment the watcher fires.
            stamp = FileStamp(of: url)
        } catch {
            NSLog("Wildcard: could not save store: %@", String(describing: error))
        }
    }

    /// An advisory lock held across the read-modify-write. It lives in its own
    /// file because the store itself is replaced by every atomic write, and a
    /// lock on a replaced inode stops meaning anything.
    private func withFileLock(_ body: () -> Void) {
        if lockFD < 0 {
            let path = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).lock").path
            lockFD = open(path, O_CREAT | O_RDWR, 0o644)
        }
        guard lockFD >= 0 else { return body() }   // no lock is better than no save
        flock(lockFD, LOCK_EX)
        defer { flock(lockFD, LOCK_UN) }
        body()
    }

    /// Enough of a `stat` to tell "the same file" from "a newer one". Inode is
    /// in there because an atomic write always changes it, even within a second.
    private struct FileStamp: Equatable {
        var inode: UInt64
        var size: Int64
        var seconds: Int
        var nanoseconds: Int

        init?(of url: URL) {
            var s = stat()
            guard stat(url.path, &s) == 0 else { return nil }
            inode = s.st_ino
            size = s.st_size
            seconds = s.st_mtimespec.tv_sec
            nanoseconds = s.st_mtimespec.tv_nsec
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
