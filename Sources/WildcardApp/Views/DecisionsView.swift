import SwiftUI
import WildcardKit

/// The inbox for file types nothing has decided about.
///
/// This screen is the promise in the brief made visible: a type that turns up
/// with no rule covering it is not handed to whichever app claimed it first —
/// it waits here until someone says what should happen.
struct DecisionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = Set<Target>()

    var body: some View {
        Page(title: "Needs a decision", subtitle: subtitle) {
            if !selection.isEmpty {
                HStack(spacing: Theme.Space.s) {
                    Button("Ignore \(selection.count)") {
                        model.dismiss(decisions: Array(selection))
                        selection.removeAll()
                    }
                    .buttonStyle(QuietButtonStyle())
                    AppPicker(apps: model.inventory.apps, title: "Open \(selection.count) with…") { app in
                        assign(Array(selection), to: app)
                    }
                }
            }
        } content: {
            if model.decisions.isEmpty {
                Card {
                    EmptyState(
                        icon: "checkmark.circle",
                        title: "Nothing waiting",
                        message: "When a file type appears that no rule covers, it lands here rather than "
                               + "being quietly assigned to whichever application claimed it first.")
                }
            } else {
                ForEach(grouped, id: \.reason) { group in
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionHeader(title: Self.title(for: group.reason),
                                      subtitle: Self.explanation(for: group.reason))
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(group.items) { decision in
                                    row(decision)
                                    if decision.id != group.items.last?.id { RowDivider() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        model.decisions.isEmpty
            ? "Nothing is waiting on you."
            : "\(model.decisions.count) file types have turned up with nothing deciding where they should go."
    }

    private var grouped: [(reason: PendingDecision.Reason, items: [PendingDecision])] {
        let order: [PendingDecision.Reason] = [.newlySeen, .noRule, .unknownType]
        return order.compactMap { reason in
            let items = model.decisions.filter { $0.reason == reason }
            return items.isEmpty ? nil : (reason, items)
        }
    }

    private func row(_ decision: PendingDecision) -> some View {
        HStack(spacing: Theme.Space.m) {
            Button {
                toggle(decision.target)
            } label: {
                Image(systemName: selection.contains(decision.target) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selection.contains(decision.target) ? Theme.accent : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose \(model.catalog.label(for: decision.target))")
            .accessibilityAddTraits(selection.contains(decision.target) ? .isSelected : [])

            VStack(alignment: .leading, spacing: 2) {
                Text(model.catalog.label(for: decision.target)).bodyStyle()
                HStack(spacing: 6) {
                    Text(decision.target.display)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    if let id = decision.suggestedCategoryID {
                        Text("· looks like \(model.categoryName(id))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AppLabel(ref: decision.currentHandler, placeholder: "Nothing opens it")
                .frame(width: 160, alignment: .leading)

            if let suggested = decision.suggestedApp,
               let app = model.inventory.app(id: suggested.id) {
                Button {
                    assign([decision.target], to: app)
                } label: {
                    HStack(spacing: 4) {
                        AppIcon(ref: suggested, size: 13)
                        Text("Use \(suggested.name)")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            Menu {
                ForEach(candidates(for: decision.target), id: \.id) { app in
                    Button(app.name) { assign([decision.target], to: app) }
                }
                Divider()
                Button("Ignore this type") { model.dismiss(decisions: [decision.target]) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .accessibilityLabel("More for \(model.catalog.label(for: decision.target))")
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 9)
    }

    private func candidates(for target: Target) -> [InstalledApp] {
        let ids = AppInventory.candidates(for: target)
            .compactMap { Bundle(url: $0)?.bundleIdentifier?.lowercased() }
        let known = ids.compactMap { model.inventory.app(id: $0) }
        return known.isEmpty ? Array(model.inventory.apps.prefix(10)) : Array(known.prefix(10))
    }

    private func toggle(_ target: Target) {
        if selection.contains(target) { selection.remove(target) } else { selection.insert(target) }
    }

    private func assign(_ targets: [Target], to app: InstalledApp?) {
        let label = targets.count == 1
            ? model.catalog.label(for: targets[0])
            : "\(targets.count) types"
        model.propose(title: "\(label) → \(app?.name ?? "the macOS default")", targets: targets, to: app)
        model.dismiss(decisions: targets)
        selection.removeAll()
    }

    private static func title(for reason: PendingDecision.Reason) -> String {
        switch reason {
        case .newlySeen: return "New since you last looked"
        case .noRule: return "No rule covers these"
        case .unknownType: return "Wildcard does not recognise these"
        }
    }

    private static func explanation(for reason: PendingDecision.Reason) -> String {
        switch reason {
        case .newlySeen:
            return "An application appeared that claims these file types."
        case .noRule:
            return "Wildcard knows what these are, but nothing you have set covers them."
        case .unknownType:
            return "Not in the catalog. Assign an application, or add them to a category of your own."
        }
    }
}
