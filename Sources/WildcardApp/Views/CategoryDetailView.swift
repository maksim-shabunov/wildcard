import SwiftUI
import WildcardKit

/// One category: what it contains, what opens it now, and the one control that
/// assigns the whole thing.
struct CategoryDetailView: View {
    @EnvironmentObject private var model: AppModel
    let categoryID: String

    @State private var search = ""
    @State private var selection = Set<Target>()
    @State private var offerRule: (app: InstalledApp, name: String)?

    var body: some View {
        // The filter lives in the page header, not in the window toolbar. As a
        // `.searchable(placement: .toolbar)` it was installed and torn down every
        // time a category was opened or left, which resized the title bar and
        // shifted the whole window each way.
        Page(title: name,
             subtitle: summaryLine,
             search: $search,
             searchPrompt: "Filter this category") {
            HStack(spacing: Theme.Space.s) {
                if !selection.isEmpty {
                    AppPicker(apps: model.inventory.apps,
                              title: "Open \(selection.count) selected with…") { app in
                        assign(Array(selection), to: app, label: "\(selection.count) types")
                    }
                } else {
                    AppPicker(apps: model.inventory.apps, title: "Open all with…") { app in
                        assign(targets, to: app, label: name)
                    }
                }
            }
        } content: {
            if let offerRule { ruleOffer(offerRule) }
            state
            if let subgroups, subgroups.count > 1 {
                ForEach(subgroups) { group in
                    subgroupCard(group)
                }
            } else {
                allRowsCard
            }
            if isCustom { customControls }
        }
    }

    // MARK: - Identity

    private var catalogCategory: CatalogCategory? { model.catalog.category(id: categoryID) }
    private var customCategory: CustomCategory? {
        model.store.customCategories.first { $0.id == categoryID }
    }
    private var isCustom: Bool { customCategory != nil }
    private var name: String { catalogCategory?.name ?? customCategory?.name ?? categoryID }
    private var blurb: String { catalogCategory?.summary ?? customCategory?.summary ?? "" }
    private var subgroups: [CatalogSubgroup]? { catalogCategory?.subgroups }

    private var rows: [CoverageRow] { model.rows(in: categoryID) }
    private var targets: [Target] { rows.map(\.target) }

    private var filteredRows: [CoverageRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        // Typing the dot is the natural thing to do — the rows themselves are
        // labelled ".kt". Matched the same way as the All file types search,
        // which already stripped it; here it silently found nothing.
        let stripped = q.hasPrefix(".") ? String(q.dropFirst()) : q
        return rows.filter {
            $0.target.raw.contains(stripped) || $0.label.lowercased().contains(q)
                || ($0.binding.handler?.name.lowercased().contains(q) ?? false)
        }
    }

    private var summaryLine: String {
        var parts: [String] = ["\(rows.count) types"]
        let apps = Set(rows.compactMap(\.binding.handler?.id))
        if apps.isEmpty { parts.append("nothing opens any of them") }
        else if apps.count == 1, let one = rows.compactMap(\.binding.handler).first {
            parts.append("all open with \(one.name)")
        } else {
            parts.append("spread across \(apps.count) applications")
        }
        let unhandled = rows.filter { $0.binding.origin == .none }.count
        if unhandled > 0, !apps.isEmpty { parts.append("\(unhandled) with no application at all") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Cards

    private var state: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if !blurb.isEmpty {
                    Text(blurb).bodyStyle().fixedSize(horizontal: false, vertical: true)
                }
                if let rule = governingRule {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                        Text("A rule keeps these on \(rule.appName).")
                            .secondaryStyle()
                        if drifted > 0 {
                            Text("· \(drifted) have been changed since.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.attention)
                            Button("Restore") { model.proposeRestoreRule(rule) }
                                .buttonStyle(.link)
                        } else if notApplied > 0 {
                            Text("· \(notApplied) not applied yet.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                            Button("Apply") { model.proposeRestoreRule(rule) }
                                .buttonStyle(.link)
                        }
                    }
                }
                if !selection.isEmpty {
                    HStack(spacing: Theme.Space.s) {
                        Text("\(selection.count) selected").secondaryStyle()
                        Button("Clear") { selection.removeAll() }.buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var governingRule: Rule? {
        model.rules.first { rule in
            if case .category(let id) = rule.scope { return id == categoryID && rule.isEnabled }
            return false
        }
    }

    private var drifted: Int { rows.filter { $0.coverage == .drifted }.count }
    private var notApplied: Int { rows.filter { $0.coverage == .notApplied }.count }

    private func subgroupCard(_ group: CatalogSubgroup) -> some View {
        let groupRows = filteredRows.filter { row in
            group.types.contains { $0.ext == row.target.raw }
        }
        return Group {
            if !groupRows.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack {
                        SectionHeader(title: group.name)
                        Spacer()
                        AppPicker(apps: model.inventory.apps, title: "Assign group") { app in
                            assign(groupRows.map(\.target), to: app, label: group.name)
                        }
                        .controlSize(.small)
                    }
                    Card(padding: 0) { rowList(groupRows) }
                }
            }
        }
    }

    private var allRowsCard: some View {
        Group {
            if filteredRows.isEmpty {
                Card {
                    EmptyState(
                        icon: search.isEmpty ? "tray" : "magnifyingglass",
                        title: search.isEmpty ? "Nothing in this category yet" : "No matches",
                        message: search.isEmpty
                            ? "Add file types to it below, then assign an application."
                            : "Nothing here matches “\(search)”.")
                }
            } else {
                Card(padding: 0) { rowList(filteredRows) }
            }
        }
    }

    private func rowList(_ list: [CoverageRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { row in
                Button {
                    toggle(row.target)
                } label: {
                    TypeRow(row: row, trailing: AnyView(
                        Image(systemName: selection.contains(row.target) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(selection.contains(row.target) ? Theme.accent : Theme.textTertiary)
                    ))
                }
                .buttonStyle(HoverRowStyle())
                .accessibilityAddTraits(selection.contains(row.target) ? .isSelected : [])
                .contextMenu {
                    // `display` rather than a hand-written dot: this screen also
                    // shows link categories, where the same string has to read
                    // "mailto:" and not ".mailto".
                    Button("Open \(row.target.display) with…") { }.disabled(true)
                    ForEach(candidates(for: row.target), id: \.id) { app in
                        Button(app.name) { assign([row.target], to: app, label: row.label) }
                    }
                    Divider()
                    Button("Let macOS decide") { assign([row.target], to: nil, label: row.label) }
                }
                if row.id != list.last?.id { RowDivider() }
            }
        }
    }

    /// The handful of apps that actually claim this type, offered first.
    private func candidates(for target: Target) -> [InstalledApp] {
        let urls = AppInventory.candidates(for: target)
        let ids = urls.compactMap { Bundle(url: $0)?.bundleIdentifier?.lowercased() }
        return Array(ids.compactMap { model.inventory.app(id: $0) }.prefix(8))
    }

    // MARK: - Custom category editing

    private var customControls: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("This is your category").headingStyle()
                Text("Add or remove file types. The shipped categories cannot be edited, but you can build your own from any of them.")
                    .secondaryStyle()
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    AddTypeField { target in
                        guard var c = customCategory else { return }
                        if !c.members.contains(target) { c.members.append(target) }
                        model.saveCustomCategory(c)
                    }
                    Spacer()
                    if !selection.isEmpty {
                        Button("Remove \(selection.count) from category") {
                            guard var c = customCategory else { return }
                            c.members.removeAll { selection.contains($0) }
                            model.saveCustomCategory(c)
                            selection.removeAll()
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                    Button("Delete category") {
                        model.deleteCustomCategory(categoryID)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    // MARK: - Actions

    private func toggle(_ target: Target) {
        if selection.contains(target) { selection.remove(target) } else { selection.insert(target) }
    }

    private func assign(_ targets: [Target], to app: InstalledApp?, label: String) {
        let destination = app?.name ?? "the macOS default"
        model.propose(title: "\(label) → \(destination)", targets: targets, to: app)
        selection.removeAll()
        // Offering a rule only makes sense when the whole category moved.
        if let app, targets.count == rows.count, governingRule == nil {
            offerRule = (app, name)
        }
    }

    private func ruleOffer(_ offer: (app: InstalledApp, name: String)) -> some View {
        Card {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "pin")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep \(offer.name) on \(offer.app.name)?").headingStyle()
                    Text("A rule also covers file types that appear later, and tells you if something changes them.")
                        .secondaryStyle()
                }
                Spacer()
                Button("Not now") { offerRule = nil }.buttonStyle(QuietButtonStyle())
                Button("Make it a rule") {
                    model.makeRule(forCategory: categoryID, name: offer.name, app: offer.app)
                    offerRule = nil
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

/// Type an extension to add it to a custom category. Accepts `.kt`, `kt`, or
/// `mailto:` — whatever someone naturally types.
struct AddTypeField: View {
    let onAdd: (Target) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            TextField("Add a file type, e.g. .kt", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 200)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 5)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .onSubmit(add)
            Button("Add", action: add).buttonStyle(QuietButtonStyle()).disabled(text.isEmpty)
        }
    }

    private func add() {
        let raw = text.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let target: Target = raw.hasSuffix(":")
            ? .urlScheme(String(raw.dropLast()).lowercased())
            : .fileType(normalizing: raw)
        guard !target.raw.isEmpty else { return }
        onAdd(target)
        text = ""
    }
}
