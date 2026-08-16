import CoreServices
import Foundation
import WildcardKit

/// Watches the folders applications live in, so a newly installed app's file
/// types are noticed rather than discovered later by accident.
///
/// This is the other half of the promise that nothing is silently claimed: an
/// installer can add a `.foo` handler at any moment, and without this Wildcard
/// would only find out at the next launch. Directory-level events are enough —
/// an app appearing or disappearing changes the folder — so the stream is
/// deliberately coarse and cheap.
final class AppFolderWatcher: @unchecked Sendable {

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.wildcard.watch")
    private var settle: DispatchWorkItem?
    private let onChange: @Sendable () -> Void

    /// Long enough that a multi-file install lands as one event rather than
    /// twenty, short enough to feel immediate.
    private let settleDelay: TimeInterval = 3

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil else { return }
        let paths = AppInventory.searchPaths.filter {
            FileManager.default.fileExists(atPath: $0)
        }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<AppFolderWatcher>.fromOpaque(info).takeUnretainedValue().folderChanged()
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf))
        else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return
        }
        stream = s
    }

    func stop() {
        settle?.cancel()
        settle = nil
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    func setRunning(_ running: Bool) {
        running ? start() : stop()
    }

    private func folderChanged() {
        settle?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        settle = work
        queue.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }
}
