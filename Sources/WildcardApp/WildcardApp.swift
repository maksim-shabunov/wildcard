import AppKit
import SwiftUI
import WildcardKit

/// A normal Mac application: one window, a real menu bar, and deliberately no
/// status item. Wildcard is something you open, use, and close.
@main
struct WildcardApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var chrome = WindowChrome()

    var body: some Scene {
        Window("Wildcard", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(chrome)
                .frame(minWidth: 940, minHeight: 620)
                // Applied out here as well as inside the shell: the minimum-size
                // frame above establishes its own layout container, and without
                // this the columns stop at the title bar and leave a strip of
                // window background across the top of both of them.
                .ignoresSafeArea()
                // What was making the top of the window a strip with nothing in
                // it but the traffic lights. On macOS 26 SwiftUI fills the
                // window's toolbar area with glass even when the window has no
                // toolbar, and that fill is drawn over the content: a cool grey
                // neither column uses, sampled from whatever is behind the
                // window, covering the first 32pt of both of them. None of the
                // `NSWindow` title bar flags touch it — this is the one that
                // does, and it is why the sidebar can put its name up there.
                .toolbarBackground(.hidden, for: .windowToolbar)
                // And the window's own title with it. The toolbar that gives the
                // header its height also draws the title at the leading edge,
                // which put a second, greyer "Wildcard" on top of the sidebar's
                // wordmark. `titleVisibility` does not hold — SwiftUI owns this
                // one and puts it back after the window is configured.
                .modifier(TitleRemoved())
                .preferredColorScheme(scheme)
                .onAppear { model.start() }
                .onOpenURL { url in handle(url) }
                .background(WindowConfigurator(chrome: chrome))
        }
        .defaultSize(width: 1100, height: 740)
        .commands { WildcardCommands(model: model) }
    }

    private var scheme: ColorScheme? {
        switch model.settings.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// `wildcard://proposal/<id>` — how the CLI and the MCP server ask for a
    /// person's attention. The app is its own first consumer of URL handling.
    private func handle(_ url: URL) {
        guard url.scheme == "wildcard" else { return }
        NSApp.activate(ignoringOtherApps: true)
        if url.host == "proposal" {
            let id = url.lastPathComponent
            if !id.isEmpty, id != "proposal" { model.show(proposalID: id) }
        }
    }
}

/// `.regular` activation policy, and nothing else. There is no `NSStatusItem`
/// anywhere in this codebase, by design.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Takes the window's title out of the toolbar where the system draws it. The
/// modifier that does this arrived in macOS 15; on 14 the app keeps the title
/// bar it had before, which has nowhere to draw a title anyway.
private struct TitleRemoved: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// Where the window's own controls are, measured rather than assumed.
///
/// The traffic lights belong to the window, not to any view, so the sidebar's
/// first row has to be laid out around them: the wordmark begins past the zoom
/// button and is centred on the line the buttons sit on, which is what stops the
/// title bar from being a band with nothing in it but three circles.
///
/// Their metrics are the system's and have moved between macOS releases, so they
/// are read off the buttons instead of written down here — and in full screen,
/// where there are no buttons, the row gives the space back.
final class WindowChrome: ObservableObject {

    /// How far in the first row's content has to start to clear the buttons.
    @Published private(set) var leadingInset: CGFloat = Theme.Space.m

    /// The height of that row: twice the drop from the top of the window to the
    /// middle of the buttons, so centring something in it lands on their line.
    @Published private(set) var rowHeight: CGFloat = bareRow

    /// What the row is worth with no buttons to sit beside.
    private static let bareRow: CGFloat = 28

    func measure(in window: NSWindow) {
        guard
            !window.styleMask.contains(.fullScreen),
            let content = window.contentView,
            let close = window.standardWindowButton(.closeButton),
            let zoom = window.standardWindowButton(.zoomButton),
            let container = close.superview,
            !close.isHidden
        else {
            leadingInset = Theme.Space.m
            rowHeight = Self.bareRow
            return
        }

        let buttons = container.convert(close.frame.union(zoom.frame), to: content)
        leadingInset = buttons.maxX + Theme.Space.m
        // The row is laid out from the top of the window. A SwiftUI hosting view
        // is flipped and already counts from there; a plain AppKit view counts up
        // from the bottom. Getting this backwards makes the row as tall as the
        // window and pushes the whole sidebar off the bottom of it.
        let middle = content.isFlipped ? buttons.midY : content.bounds.height - buttons.midY
        rowHeight = middle * 2
    }
}

/// The window itself: content drawn full-size behind an empty, transparent title
/// bar, so the sidebar's colour reaches the top-left corner rather than stopping
/// under a strip of system grey.
///
/// `.fullSizeContentView` is what actually moves the content up; making the title
/// bar transparent on its own only removes its fill. The window's own background
/// is the sidebar tone because the sidebar is the column that touches the corners
/// during a live resize.
private struct WindowConfigurator: NSViewRepresentable {
    let chrome: WindowChrome

    func makeCoordinator() -> Coordinator { Coordinator(chrome: chrome) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            // No line under the title bar either. Now that the wordmark sits on
            // the same row as the buttons, a separator would draw the header
            // this layout exists to get rid of.
            window.titlebarSeparatorStyle = .none
            // An empty toolbar, purely for its height: `.unified` gives the
            // window a title bar deep enough to be a header row and centres the
            // traffic lights in it, instead of the 32pt strip that leaves them
            // pinned to the top edge. Nothing is ever put in the toolbar — the
            // header is drawn by the app, in the app's own type.
            let toolbar = NSToolbar(identifier: "app.wildcard.header")
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            // After the toolbar, not before: a unified toolbar puts the window's
            // title back, and it landed on top of the sidebar's own wordmark.
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(Theme.sidebar)
            window.isMovableByWindowBackground = false
            context.coordinator.watch(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Keeps `WindowChrome` honest. The buttons do not move as the window is
    /// resized, but full screen takes them away and gives them back, and the
    /// content view they are measured against changes height with it.
    final class Coordinator {
        private let chrome: WindowChrome
        private var observers: [NSObjectProtocol] = []

        init(chrome: WindowChrome) { self.chrome = chrome }

        func watch(_ window: NSWindow) {
            chrome.measure(in: window)
            for name in [NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [chrome] _ in
                        chrome.measure(in: window)
                    })
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

// MARK: - Menus

/// A proper app menu. Every action here is also reachable in the window; the
/// menu exists so the keyboard works the way it does in any other Mac app.
struct WildcardCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        // ⌘, without a `Settings` scene. Settings are a screen in the window
        // now, so the menu item takes you to it rather than opening a second
        // window that would cover the one the setting is about.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                NotificationCenter.default.post(name: .showSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .undoRedo) {
            Button("Undo Last Change") { model.undoLast() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.history.contains(where: \.canRollBack))
        }

        CommandMenu("File Types") {
            Button("Refresh") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Find a File Type…") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Save a Snapshot") {
                model.saveSnapshot(named: "Saved \(Self.stamp())")
            }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Review Waiting Requests") {
                if let next = model.waitingProposals.first { model.reviewing = next }
            }
            .disabled(model.waitingProposals.isEmpty)
        }

        CommandGroup(replacing: .help) {
            Button("Wildcard Help") {
                NotificationCenter.default.post(name: .showHelp, object: nil)
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date())
    }
}

extension Notification.Name {
    static let focusSearch = Notification.Name("app.wildcard.focusSearch")
    static let showHelp = Notification.Name("app.wildcard.showHelp")
    static let showSettings = Notification.Name("app.wildcard.showSettings")
}
