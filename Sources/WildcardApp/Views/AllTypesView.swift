import SwiftUI
import WildcardKit

/// Every file type, or every link type, in one searchable table.
///
/// This is the screen that answers "what opens this?" for anything at all,
/// including the many associations nobody ever consciously set.
struct AllTypesView: View {
    @EnvironmentObject private var model: AppModel
    let kind: CategoryKind

    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var selection = Set<Target>()
    @FocusState private var searchFocused: Bool

    enum Filter: String, CaseIterable {
        case all = "Everything"
        case unhandled = "Nothing opens them"
        case drifted = "Changed"
        case notApplied = "Not applied"
        case uncovered = "No rule"
        case explicit = "Set by hand"
    }

    var body: some View {
        Page(title: kind == .file ? "All file types" : "Links",
             subtitle: subtitle,
             search: $search,
             searchPrompt: kind == .file
                ? "Search by extension, name or application"
                : "Search links",
             searchFocus: $searchFocused) {
            actions
        } content: {
            table
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            searchFocused = true
        }
    }

    // MARK: - Header

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            if !selection.isEmpty {
                AppPicker(apps: model.inventory.apps, title: "Open \(selection.count) with…") { app in
                    let targets = Array(selection)
                    model.propose(
                        title: "\(targets.count) \(targets.count == 1 ? "type" : "types") → \(app?.name ?? "the macOS default")",
                        targets: targets, to: app)
                    selection.removeAll()
                }
            }

            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 190)
            .accessibilityLabel("Show")

            Text("\(rows.count) shown")
                .secondaryStyle()
                .monospacedDigit()
        }
    }

    private var subtitle: String {
        kind == .file
            ? "Everything this Mac knows how to open — including associations you never set."
            : "Which application handles each kind of link, from web pages to ssh."
    }

    // MARK: - Table

    /// No `ScrollView` of its own: the page it sits in already scrolls, and
    /// nesting the two gave this screen a scroll view whose height depended on
    /// what happened to be above it. The `LazyVStack` still only builds the rows
    /// on screen, which is what keeps two thousand types cheap.
    private var table: some View {
        Group {
            if rows.isEmpty {
                Card {
                    EmptyState(
                        icon: "magnifyingglass",
                        title: "Nothing matches",
                        message: search.isEmpty
                            ? "No types fall into this filter right now."
                            : "Nothing matches “\(search)”. Try an extension like “kt”, or an application name.")
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button {
                            toggle(row.target)
                        } label: {
                            TypeRow(row: row, showCategory: true, trailing: AnyView(
                                Image(systemName: selection.contains(row.target) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(selection.contains(row.target) ? Theme.accent : Theme.textTertiary)
                            ))
                        }
                        .buttonStyle(HoverRowStyle())
                        .accessibilityAddTraits(selection.contains(row.target) ? .isSelected : [])
                        .contextMenu { menu(for: row) }
                        if row.id != rows.last?.id { RowDivider() }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1))
            }
        }
    }

    @ViewBuilder
    private func menu(for row: CoverageRow) -> some View {
        ForEach(candidates(for: row.target), id: \.id) { app in
            Button(app.name) {
                model.propose(title: "\(row.label) → \(app.name)", targets: [row.target], to: app)
            }
        }
        Divider()
        Button("Let macOS decide") {
            model.propose(title: "\(row.label) → the macOS default", targets: [row.target], to: nil)
        }
        if case .fileType(let ext) = row.target {
            Divider()
            Section("System type") {
                Text(TypeResolution.resolve(ext: ext)?.identifier ?? "none declared")
            }
        }
    }

    private func candidates(for target: Target) -> [InstalledApp] {
        AppInventory.candidates(for: target)
            .compactMap { Bundle(url: $0)?.bundleIdentifier?.lowercased() }
            .compactMap { model.inventory.app(id: $0) }
            .prefix(10)
            .map { $0 }
    }

    private func toggle(_ target: Target) {
        if selection.contains(target) { selection.remove(target) } else { selection.insert(target) }
    }

    // MARK: - Filtering

    private var rows: [CoverageRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var list = model.allRows.filter { kind == .file ? $0.target.isFileType : !$0.target.isFileType }

        switch filter {
        case .all: break
        case .unhandled: list = list.filter { $0.binding.origin == .none }
        case .drifted: list = list.filter { $0.coverage == .drifted }
        case .notApplied: list = list.filter { $0.coverage == .notApplied }
        case .uncovered: list = list.filter { $0.coverage == .uncovered }
        case .explicit: list = list.filter { $0.binding.origin == .explicit }
        }

        guard !q.isEmpty else { return list }
        let stripped = q.hasPrefix(".") ? String(q.dropFirst()) : q
        return list.filter {
            $0.target.raw.contains(stripped)
                || $0.label.lowercased().contains(q)
                || ($0.binding.handler?.name.lowercased().contains(q) ?? false)
                || ($0.categoryName?.lowercased().contains(q) ?? false)
        }
    }
}
