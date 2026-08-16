import SwiftUI

/// The window's two columns, built by hand.
///
/// This deliberately does not use `NavigationSplitView`. On the macOS 26 SDK that
/// container applies the system's glass treatment to its sidebar — translucent,
/// inset from the window edges, floating on its own rounded rectangle — and there
/// is no modifier that opts out. The result looked nothing like the flat, calm,
/// opaque interface this app is meant to have, and none of the colours in
/// `Theme` could show through it.
///
/// Doing the split here costs one `HStack` and buys back full control of the
/// surface, the divider, and — because there is no `List` selection machinery
/// underneath — scrolling that behaves the same on every screen.
struct SplitShell<Sidebar: View, Detail: View>: View {
    var sidebarWidth: CGFloat = 244
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(Theme.sidebar)

            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
        // Both columns run to the top edge, under the transparent title bar, so
        // the sidebar tone reaches the corner instead of stopping at a grey
        // strip. Content inside each column pads itself past `Theme.titlebar`.
        .ignoresSafeArea()
    }
}

// MARK: - Page

/// The common shape of every screen: a heading that stays put, and a column of
/// content that scrolls under it.
///
/// The header is outside the `ScrollView` on purpose — the title of the thing you
/// are looking at should not slide away while you read it — and the `ScrollView`
/// is given the whole of the remaining height, so every screen scrolls whether or
/// not its content happens to overflow today.
///
/// Search belongs here rather than in the window toolbar. A `.searchable` field
/// placed in the toolbar is installed and removed as you move between screens,
/// which resizes the title bar and shifts both columns every time you click a
/// category.
struct Page<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String?
    var search: Binding<String>?
    var searchPrompt: String = "Search"
    var searchFocus: FocusState<Bool>.Binding?
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).titleStyle()
                    if let subtitle {
                        Text(subtitle)
                            .secondaryStyle()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.m)
                actions
            }
            if let search {
                SearchField(text: search, prompt: searchPrompt, focus: searchFocus)
                    .frame(maxWidth: 420)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.titlebar)
        .padding(.bottom, Theme.Space.m)
    }
}

extension Page where Actions == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        search: Binding<String>? = nil,
        searchPrompt: String = "Search",
        searchFocus: FocusState<Bool>.Binding? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, subtitle: subtitle, search: search,
            searchPrompt: searchPrompt, searchFocus: searchFocus,
            actions: { EmptyView() }, content: content)
    }
}

/// One search field, used on every screen that has one.
struct SearchField: View {
    @Binding var text: String
    var prompt: String
    var focus: FocusState<Bool>.Binding?

    @FocusState private var local: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            Group {
                if let focus {
                    TextField(prompt, text: $text).focused(focus)
                } else {
                    TextField(prompt, text: $text).focused($local)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("Clear the search")
                .help("Clear the search")
            }
        }
        .padding(.horizontal, Theme.Space.s + 2)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
