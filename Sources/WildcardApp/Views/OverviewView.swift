import SwiftUI
import WildcardKit

/// The page that answers the first question: what is the state of this Mac.
struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var screen: Screen

    var body: some View {
        Page(title: "Overview", subtitle: subtitle) {
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(model.isRefreshing)
        } content: {
            counts
            if !model.driftedRows.isEmpty { drift }
            if !model.notAppliedRows.isEmpty { waiting }
            if !model.decisions.isEmpty { decisions }
            categoriesAtAGlance
            if !model.history.isEmpty { recent }
        }
    }

    private var subtitle: String {
        let s = model.summary
        if s.total == 0 { return "Looking at what this Mac has…" }
        let categories = model.fileCategories.count + model.schemeCategories.count
            + model.store.customCategories.count
        return "\(s.total) file and link types, across \(categories) categories."
    }

    // MARK: - Counts

    /// Only the counts that are true right now. The two states a rule can be in
    /// besides "fine" are usually zero, and a permanent row of zeroes reads as
    /// a machine reporting rather than an app telling you something.
    private var counts: some View {
        Card {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                let tiles = countTiles
                ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                    if index > 0 { divider }
                    StatTile(value: tile.value, label: tile.label, tint: tile.tint,
                             action: tile.screen.map { s in { screen = s } })
                }
            }
        }
    }

    private struct Tile {
        var value: Int
        var label: String
        var tint: Color = Theme.textPrimary
        var screen: Screen?
    }

    private var countTiles: [Tile] {
        let s = model.summary
        var tiles = [Tile(value: s.managed, label: "Managed by a rule", screen: .rules)]
        if s.notApplied > 0 {
            tiles.append(Tile(value: s.notApplied, label: "Waiting to be applied", screen: .rules))
        }
        if s.drifted > 0 {
            tiles.append(Tile(value: s.drifted, label: "Changed by something else", tint: Theme.attention))
        }
        tiles.append(Tile(value: s.uncovered, label: "No rule covers them", screen: .allTypes))
        tiles.append(Tile(value: s.unhandled, label: "Nothing opens them"))
        return tiles
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 40)
    }

    // MARK: - Where a rule and the system disagree

    /// Something deliberately took these — an installer, or the person, before
    /// the rule existed. Worth saying out loud, because otherwise it surfaces
    /// as the wrong app launching.
    private var drift: some View {
        ruleGap(
            title: "Not what your rule says",
            subtitle: "Something set these on purpose — usually an installer — and it disagrees with a rule.",
            rows: model.driftedRows,
            verb: "Restore")
    }

    /// A rule exists but has never been applied to these. Nothing was taken;
    /// there is simply nothing on the system yet saying what should open them.
    private var waiting: some View {
        ruleGap(
            title: "Waiting to be applied",
            subtitle: "A rule covers these, but macOS is still picking for them. Applying it is one step.",
            rows: model.notAppliedRows,
            verb: "Apply")
    }

    private func ruleGap(title: String, subtitle: String, rows: [CoverageRow], verb: String) -> some View {
        let shown = Array(rows.prefix(6))
        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).headingStyle()
                        Text(subtitle).secondaryStyle().fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.m)
                    ForEach(rules(in: rows), id: \.id) { rule in
                        Button("\(verb) \(rule.name)") { model.proposeRestoreRule(rule) }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding(Theme.Space.m)

                RowDivider()
                ForEach(shown) { row in
                    TypeRow(row: row, showCategory: true)
                    if row.id != shown.last?.id { RowDivider() }
                }
                if rows.count > shown.count {
                    Text("and \(rows.count - shown.count) more")
                        .secondaryStyle()
                        .padding(Theme.Space.m)
                }
            }
        }
    }

    private func rules(in rows: [CoverageRow]) -> [Rule] {
        var seen = Set<UUID>()
        return rows.compactMap(\.rule).filter { seen.insert($0.id).inserted }
    }

    // MARK: - Decisions

    private var decisions: some View {
        Card {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.decisions.count) \(model.decisions.count == 1 ? "type is" : "types are") waiting for a decision")
                        .headingStyle()
                    Text("These turned up with no rule covering them. Nothing has been assigned on your behalf.")
                        .secondaryStyle()
                }
                Spacer()
                Button("Review") { screen = .decisions }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: - Categories

    /// Every category, in the two groups the sidebar uses.
    ///
    /// Both grids are here because the line at the top of this page counts file
    /// and link categories together. Showing only the file ones made that count
    /// wrong by eight, and a category someone built themselves — the one they
    /// are most likely to be looking for — was the only kind that never appeared
    /// on the page called Overview.
    private var categoriesAtAGlance: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            grid(title: "Categories", cards: fileCards)
            grid(title: "Links", cards: linkCards)
        }
    }

    private func grid(title: String, cards: [CategoryCard.Model]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: Theme.Space.m)],
                      spacing: Theme.Space.m) {
                ForEach(cards) { card in
                    CategoryCard(category: card) { screen = .category(card.id) }
                }
            }
        }
    }

    private var fileCards: [CategoryCard.Model] {
        model.fileCategories.map(CategoryCard.Model.init)
            + model.store.customCategories.map(CategoryCard.Model.init)
    }

    private var linkCards: [CategoryCard.Model] {
        model.schemeCategories.map(CategoryCard.Model.init)
    }

    // MARK: - Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                SectionHeader(title: "Recently changed")
                Spacer()
                Button("All history") { screen = .history }.buttonStyle(.link)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(model.history.prefix(4))) { entry in
                        HistoryRow(entry: entry, compact: true)
                        if entry.id != model.history.prefix(4).last?.id { RowDivider() }
                    }
                }
            }
        }
    }
}

/// A category with the app most of it opens with — and, honestly, when it is
/// not one app at all.
struct CategoryCard: View {
    /// The four things a card draws, so shipped and hand-made categories — which
    /// are separate types by design, because an update must never overwrite the
    /// second — can share one card rather than one card each.
    struct Model: Identifiable, Hashable {
        var id: String
        var name: String
        var icon: String
        var count: Int

        init(id: String, name: String, icon: String, count: Int) {
            self.id = id
            self.name = name
            self.icon = icon
            self.count = count
        }

        init(_ c: CatalogCategory) {
            self.init(id: c.id, name: c.name, icon: c.icon, count: c.count)
        }

        init(_ c: CustomCategory) {
            self.init(id: c.id, name: c.name, icon: c.icon, count: c.members.count)
        }
    }

    @EnvironmentObject private var appModel: AppModel
    let category: Model
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Two lines are kept for the name whether or not it needs
                // them, so every card in the grid is the same height and not
                // just every card in a row. Everything on the row hangs off
                // the first line, which is where a one-line name sits.
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Image(systemName: category.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 20)
                    Text(category.name).headingStyle().lineLimit(2, reservesSpace: true)
                    Spacer()
                    Text("\(category.count)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
                // A grid row is as tall as the tallest card in it, so a name
                // that wraps to two lines left its neighbours short and
                // floating in a taller cell. The gap takes the difference and
                // the app line sits on the bottom edge, level across the row.
                Spacer(minLength: Theme.Space.s)
                HStack(spacing: 6) {
                    if let (app, share) = appModel.dominantApp(in: category.id) {
                        AppIcon(ref: app, size: 14)
                        Text(share > 0.85
                             ? app.name
                             : "\(app.name) and \(otherCount) \(otherCount == 1 ? "other" : "others")")
                            .secondaryStyle()
                            .lineLimit(1)
                    } else {
                        Text("Nothing opens these").secondaryStyle()
                    }
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                hovering ? Theme.surfaceRaised : Theme.surface,
                in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(category.name), \(category.count) types")
    }

    private var otherCount: Int {
        let apps = Set(appModel.rows(in: category.id).compactMap(\.binding.handler?.id))
        return max(apps.count - 1, 1)
    }
}
