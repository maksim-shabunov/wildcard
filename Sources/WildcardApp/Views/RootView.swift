import SwiftUI
import WildcardKit

enum Screen: Hashable {
    case overview
    case decisions
    case rules
    case allTypes
    case links
    case history
    case settings
    case category(String)
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var screen: Screen = .overview
    @State private var showHelp = false

    var body: some View {
        SplitShell {
            Sidebar(screen: $screen)
        } detail: {
            detail
        }
        .sheet(item: $model.reviewing) { proposal in
            ProposalSheet(proposal: proposal).environmentObject(model)
        }
        .sheet(isPresented: $showHelp) { HelpSheet() }
        .overlay(alignment: .bottom) { NoticeBar() }
        .overlay { if model.applying { ApplyingOverlay() } }
        .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { _ in showHelp = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in findAType() }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in screen = .settings }
    }

    /// ⌘F from anywhere.
    ///
    /// Only the searchable screens listen for this, so pressing ⌘F while looking
    /// at History used to do nothing at all — a menu item that silently does
    /// nothing is worse than no menu item. Open the list first, then let it take
    /// the focus. Already somewhere searchable, leave it alone: someone on Links
    /// means to search links, and someone inside a category means to filter it.
    private func findAType() {
        if case .category = screen { return }
        guard screen != .allTypes, screen != .links else { return }
        screen = .allTypes
        // The list has to exist before it can be focused, so the notification
        // goes out again once this screen change has been drawn. The guard above
        // stops that second one from looping.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .focusSearch, object: nil)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch screen {
        case .overview: OverviewView(screen: $screen)
        case .decisions: DecisionsView()
        case .rules: RulesView(screen: $screen)
        case .allTypes: AllTypesView(kind: .file)
        case .links: AllTypesView(kind: .scheme)
        case .history: HistoryView()
        case .settings: SettingsView()
        // Identified by category, so moving between two categories starts the
        // new one at the top with an empty filter rather than inheriting the
        // scroll position and search text of the one before it.
        case .category(let id): CategoryDetailView(categoryID: id).id(id)
        }
    }
}

// MARK: - Sidebar

/// A plain scrolling column of buttons.
///
/// Deliberately not a `List`. The sidebar list style is what pulls in the
/// system's glass panel, and its selection binding fought the navigation links
/// that used to sit inside it — there was no `navigationDestination` for those
/// links to reach, so between the two the column could stop scrolling entirely
/// once a category had been clicked. A `ScrollView` of buttons has one source of
/// truth for what is selected, and scrolls unconditionally.
private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var chrome: WindowChrome
    @Binding var screen: Screen
    @State private var categoriesExpanded = true
    @State private var linksExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordmark

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    row(.overview, "Overview", "square.grid.2x2")
                    row(.decisions, "Needs a decision", "questionmark.circle", badge: model.decisions.count)
                    row(.rules, "Rules", "list.bullet.rectangle")

                    groupLabel("File types")
                    disclosure("Categories", "folder", isExpanded: $categoriesExpanded) {
                        ForEach(model.fileCategories) { category in
                            row(.category(category.id), category.name, category.icon, indented: true)
                        }
                        // Yours go last, under the shipped ones, and are not
                        // filtered by kind. A category you built by typing “.kt”
                        // and “mailto:” into the same box is neither a file
                        // category nor a link one, and filtering on the field
                        // that claims otherwise is how it would disappear from
                        // the only list that leads to it.
                        ForEach(model.store.customCategories) { category in
                            row(.category(category.id), category.name, category.icon, indented: true)
                        }
                    }
                    row(.allTypes, "All file types", "doc.text.magnifyingglass")

                    groupLabel("Links")
                    disclosure("Link categories", "link", isExpanded: $linksExpanded) {
                        ForEach(model.schemeCategories) { category in
                            row(.category(category.id), category.name, category.icon, indented: true)
                        }
                    }
                    row(.links, "All links", "globe")

                    groupLabel("Record")
                    row(.history, "History", "clock.arrow.circlepath")
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.bottom, Theme.Space.m)
            }

            WaitingBanner(screen: $screen)
            settings
        }
    }

    /// Pinned under the list instead of sitting in it. Settings are not one of
    /// the things you came here to look at — they are where you change how the
    /// rest of them behave — and the list above scrolls, which would carry a row
    /// like this out of reach on a Mac with a lot of categories.
    private var settings: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            row(.settings, "Settings", "gearshape")
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.s)
        }
    }

    /// The app's own name, on the traffic lights' own line — where a Mac app's
    /// title would be, and reading as one row: close, minimise, zoom, Wildcard.
    ///
    /// It used to start below the whole title bar, which left that strip holding
    /// nothing but the three buttons: a header for the window's furniture and
    /// none of its content. `WindowChrome` measures where the buttons end and how
    /// tall their line is, so the name clears them by a margin rather than by a
    /// number that would be wrong the next time Apple moves them.
    private var wordmark: some View {
        Text("Wildcard")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.leading, chrome.leadingInset)
            .padding(.trailing, Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: chrome.rowHeight, alignment: .leading)
            .padding(.bottom, Theme.Space.s)
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .sectionLabelStyle()
            .padding(.horizontal, Theme.Space.s)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.xs)
    }

    private func row(
        _ target: Screen,
        _ title: String,
        _ icon: String,
        badge: Int? = nil,
        indented: Bool = false
    ) -> some View {
        SidebarRow(
            title: title,
            icon: icon,
            badge: badge,
            indented: indented,
            isSelected: screen == target,
            action: { screen = target })
    }

    /// Built by hand rather than with `DisclosureGroup`, which carries the list
    /// styling this column exists to avoid.
    @ViewBuilder
    private func disclosure<Content: View>(
        _ title: String,
        _ icon: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SidebarRow(
            title: title,
            icon: icon,
            chevron: isExpanded.wrappedValue ? "chevron.down" : "chevron.right",
            isSelected: false,
            action: { isExpanded.wrappedValue.toggle() })
            .accessibilityHint(isExpanded.wrappedValue ? "Collapse" : "Expand")

        if isExpanded.wrappedValue { content() }
    }
}

/// One line in the sidebar. Hover and selection are tonal steps, nothing else.
private struct SidebarRow: View {
    let title: String
    let icon: String
    var badge: Int?
    var chevron: String?
    var indented = false
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: Theme.Space.xs)

                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.accent, in: Capsule())
                }
                if let chevron {
                    Image(systemName: chevron)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.leading, indented ? Theme.Space.l : Theme.Space.s)
            .padding(.trailing, Theme.Space.s)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                background,
                in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(badge.map { $0 > 0 ? "\(title), \($0) waiting" : title } ?? title)
    }

    private var background: Color {
        if isSelected { return Theme.sidebarSelected }
        return hovering ? Theme.sidebarHover : .clear
    }
}

/// Requests that came from outside the window. Kept visible rather than a
/// notification you can miss.
private struct WaitingBanner: View {
    @EnvironmentObject private var model: AppModel
    @Binding var screen: Screen

    var body: some View {
        // Nothing at all when there is nothing to say — not an empty box with
        // padding, which would leave a gap under the sidebar.
        if model.waitingProposals.isEmpty && model.unreadableRequests.isEmpty {
            EmptyView()
        } else {
            banners
        }
    }

    private var banners: some View {
        VStack(spacing: 6) {
            Rectangle().fill(Theme.hairline).frame(height: 1)

            if let first = model.waitingProposals.first {
                banner(
                    icon: "hand.raised",
                    tint: Theme.accent,
                    background: Theme.accentSoft,
                    title: model.waitingProposals.count == 1
                        ? "A request is waiting"
                        : "\(model.waitingProposals.count) requests waiting",
                    detail: "From \(first.source.label)",
                    action: { model.reviewing = first })
            }
            // Something was left in the queue that Wildcard cannot read. Saying so
            // is the whole point: whoever wrote it has probably already told
            // someone to come here and approve it.
            if let bad = model.unreadableRequests.first {
                banner(
                    icon: "exclamationmark.triangle",
                    tint: Theme.attention,
                    background: Theme.attentionSoft,
                    title: model.unreadableRequests.count == 1
                        ? "A request could not be read"
                        : "\(model.unreadableRequests.count) requests could not be read",
                    // The word that matters goes at the end, where middle
                    // truncation keeps it. "broken01.json — nothing from it
                    // will be applied" clipped down to "broken01.json…it will
                    // be applied", which says the opposite of the truth.
                    detail: "\(bad) — ignored",
                    action: { model.revealUnreadableRequests() })
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
    }

    private func banner(
        icon: String,
        tint: Color,
        background: Color,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.s + 2)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(detail)")
    }
}

// MARK: - Transient feedback

/// One factual sentence about what just happened. No colour beyond the one case
/// that went wrong.
private struct NoticeBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let notice = model.notice {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: notice.isProblem ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(notice.isProblem ? Theme.attention : Theme.textSecondary)
                Text(notice.text).bodyStyle()
                Button {
                    model.notice = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("Dismiss this message")
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 10)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .padding(.bottom, Theme.Space.l)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: notice.id) {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if model.notice?.id == notice.id { model.notice = nil }
            }
        }
    }
}

private struct ApplyingOverlay: View {
    var body: some View {
        ZStack {
            Theme.background.opacity(0.7)
            VStack(spacing: Theme.Space.m) {
                ProgressView().controlSize(.small)
                Text("Applying, then checking each one took effect…")
                    .secondaryStyle()
            }
            .padding(Theme.Space.l)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .ignoresSafeArea()
    }
}

// MARK: - Help

private struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("How Wildcard works").titleStyle()

            paragraph("macOS lets you set a default application one file extension at a time. "
                    + "Wildcard works in categories instead: pick “Code” and an app, and every "
                    + "extension in it moves together — including the ones nobody remembers.")

            paragraph("Nothing is ever applied straight away. Every change — yours, the command "
                    + "line's, or an agent's — becomes a request you see in full and approve. "
                    + "Every applied change is listed in History and can be undone.")

            paragraph("“Needs a decision” collects file types that turned up with nothing deciding "
                    + "where they should go, so a new type is never quietly handed to whichever "
                    + "app claimed it first.")

            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 480)
        .background(Theme.background)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
