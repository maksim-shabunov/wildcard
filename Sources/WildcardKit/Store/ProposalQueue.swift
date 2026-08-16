import Foundation

/// The hand-off point between anything that asks for a change and the window
/// that approves it.
///
/// A directory of JSON files rather than a socket: the agent-facing helper is a
/// separate process from the app, the app may not even be running when a request
/// arrives, and a queue that survives a restart is worth more than one that is
/// fast. It is also inspectable — you can read exactly what an agent asked for
/// with any text editor.
public final class ProposalQueue: @unchecked Sendable {

    public static let shared = ProposalQueue()

    private let dir: URL
    private let fm = FileManager.default
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: CInt = -1

    /// Called on the main queue whenever the directory changes.
    public var onChange: (@Sendable () -> Void)?

    public init(directory: URL? = nil) {
        self.dir = directory ?? Store.directory.appendingPathComponent("Proposals", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Where the queue lives. Exposed so the app can show someone the file when
    /// it cannot make sense of one.
    public var directory: URL { dir }

    private func url(for id: String) -> URL {
        dir.appendingPathComponent("\(id).json")
    }

    // MARK: - Reading

    public func all() -> [Proposal] { contents().proposals }

    /// The queue as it reads right now: everything that decoded, and the names of
    /// any files that did not.
    ///
    /// The unreadable ones are reported rather than skipped. This directory is a
    /// documented hand-off point — something writes a file here and then tells a
    /// person to go and approve it in Wildcard. If that file cannot be read and
    /// the window simply shows nothing, someone has been sent to approve a
    /// request that never appears, with nothing anywhere saying why.
    public func contents() -> (proposals: [Proposal], unreadable: [String]) {
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return ([], []) }
        var proposals: [Proposal] = []
        var unreadable: [String] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let p = try? Self.decoder.decode(Proposal.self, from: data) {
                proposals.append(p)
            } else {
                unreadable.append(file.lastPathComponent)
            }
        }
        return (proposals.sorted { $0.createdAt > $1.createdAt }, unreadable.sorted())
    }

    public func unreadableFiles() -> [String] { contents().unreadable }

    /// Proposals still waiting for a person, with expired ones swept aside.
    public func awaitingApproval() -> [Proposal] {
        var out: [Proposal] = []
        for var p in all() {
            if p.isExpired {
                p.status = .expired
                try? write(p)
                continue
            }
            if p.status == .awaitingApproval { out.append(p) }
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    public func get(_ id: String) -> Proposal? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        var p = try? Self.decoder.decode(Proposal.self, from: data)
        if p?.isExpired == true { p?.status = .expired }
        return p
    }

    // MARK: - Writing

    public func write(_ proposal: Proposal) throws {
        let data = try Self.encoder.encode(proposal)
        try data.write(to: url(for: proposal.id), options: .atomic)
    }

    public func setStatus(_ id: String, _ status: ProposalStatus, results: [ApplyResult] = []) {
        guard var p = get(id) else { return }
        p.status = status
        if !results.isEmpty { p.results = results }
        try? write(p)
    }

    public func remove(_ id: String) { try? fm.removeItem(at: url(for: id)) }

    /// Drop finished proposals older than a day. Called on launch.
    public func prune() {
        let cutoff = Date().addingTimeInterval(-86_400)
        for p in all() where p.status != .awaitingApproval && p.createdAt < cutoff {
            remove(p.id)
        }
    }

    // MARK: - Waiting (used by the CLI and MCP `await_proposal`)

    /// Block until the proposal leaves `awaiting_approval`, or the deadline passes.
    /// Polling, deliberately: the alternative is a socket and a daemon, and this
    /// runs at most a few times per request.
    public func waitForDecision(_ id: String, timeout: TimeInterval) -> Proposal? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let p = get(id) else { return nil }
            if p.status != .awaitingApproval { return p }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return get(id)
    }

    // MARK: - Watching (used by the app)

    /// Watch the directory so an agent's request appears in the window without
    /// the user doing anything.
    public func startWatching() {
        stopWatching()
        watchedFD = open(dir.path, O_EVTONLY)
        guard watchedFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedFD, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.directoryChanged() }
        src.setCancelHandler { [fd = watchedFD] in close(fd) }
        src.resume()
        watcher = src
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watchedFD = -1
        rechecksLeft = 0
    }

    /// Something appeared, moved or vanished in the directory.
    ///
    /// A file shows up here the instant it is created, which for a writer that
    /// does not write atomically is before it contains any JSON — and the
    /// directory does not fire again as that file is filled in, only when one is
    /// created, renamed or removed. A single look would therefore drop the
    /// proposal for good. Wildcard's own writes are atomic and never hit this;
    /// a script or an editor dropping a file in here does, and the queue is
    /// meant to be usable that way.
    ///
    /// Main queue only — the source is bound to it, and so are the rechecks.
    private func directoryChanged() {
        onChange?()
        guard !unreadableFiles().isEmpty else { return }
        rechecksLeft = 4
        scheduleRecheck()
    }

    private var rechecksLeft = 0

    private func scheduleRecheck() {
        guard rechecksLeft > 0 else { return }
        rechecksLeft -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.onChange?()
            if !self.unreadableFiles().isEmpty { self.scheduleRecheck() }
        }
    }

    // MARK: - Coding

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
