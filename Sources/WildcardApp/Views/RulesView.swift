import SwiftUI
import WildcardKit

/// Rules are the standing intent — *this category opens with this app* — and
/// the reason Wildcard can tell you when something else has changed a binding.
struct RulesView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var screen: Screen
    @State private var editing: Rule?
    @State private var creatingCategory = false

    var body: some View {
        Page(title: "Rules", subtitle: subtitle) {
            HStack(spacing: Theme.Space.s) {
                Button("New category") { creatingCategory = true }
                    .buttonStyle(QuietButtonStyle())
                Button("New rule") { editing = blankRule }
                    .buttonStyle(PrimaryButtonStyle())
            }
        } content: {
            if model.rules.isEmpty {
                Card {
                    EmptyState(
                        icon: "list.bullet.rectangle",
                        title: "No rules yet",
                        message: "A rule keeps a whole category on one application — including file types "
                               + "that only appear later — and tells you when something changes one behind your back.")
                }
            } else {
                ForEach(model.rules) { rule in
                    ruleCard(rule)
                }
            }
            customCategories
        }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule).environmentObject(model)
        }
        .sheet(isPresented: $creatingCategory) {
            CategoryEditor().environmentObject(model)
        }
    }

    private var subtitle: String {
        model.rules.isEmpty
            ? "Nothing is being kept in place yet."
            : "\(model.rules.count) \(model.rules.count == 1 ? "rule" : "rules"), covering \(coveredCount) types."
    }

    private var coveredCount: Int {
        Set(model.rules.filter(\.isEnabled)
            .flatMap { $0.targets(in: model.catalog, custom: model.store.customCategories) }).count
    }

    private var blankRule: Rule {
        Rule(name: "", scope: .category(id: model.fileCategories.first?.id ?? "code"),
             appID: "", appName: "")
    }

    private func ruleCard(_ rule: Rule) -> some View {
        let rows = targetsRows(for: rule)
        // Two different sentences: "something took these" and "this has never
        // been applied". Both need the same button; only one is alarming.
        let drifted = rows.filter { $0.coverage == .drifted }
        let notApplied = rows.filter { $0.coverage == .notApplied }
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Toggle("", isOn: Binding(
                        get: { rule.isEnabled },
                        set: { model.setRule(rule, enabled: $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel("\(rule.name) enabled")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.name.isEmpty ? "Untitled rule" : rule.name).headingStyle()
                        Text(scopeText(rule)).secondaryStyle()
                    }
                    Spacer()
                    AppLabel(ref: AppRef(id: rule.appID, name: rule.appName))
                    Menu {
                        Button("Edit") { editing = rule }
                        Button("Apply now") { applyNow(rule) }
                        Divider()
                        Button("Delete", role: .destructive) { model.deleteRule(rule) }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 13))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                    .accessibilityLabel("More for the rule “\(rule.name.isEmpty ? "Untitled rule" : rule.name)”")
                }

                if !drifted.isEmpty {
                    ruleNotice(
                        icon: "exclamationmark.triangle",
                        tint: Theme.attention,
                        background: Theme.attentionSoft,
                        text: "\(drifted.count) \(drifted.count == 1 ? "type has" : "types have") been changed since: "
                            + drifted.prefix(4).map(\.target.display).joined(separator: ", "),
                        button: "Restore") { model.proposeRestoreRule(rule) }
                } else if !notApplied.isEmpty {
                    ruleNotice(
                        icon: "clock",
                        tint: Theme.textSecondary,
                        background: Theme.surfaceRaised,
                        text: "\(notApplied.count) \(notApplied.count == 1 ? "type is" : "types are") still opening with "
                            + "whatever macOS picked. This rule has not been applied to them.",
                        button: "Apply") { model.proposeRestoreRule(rule) }
                }
            }
        }
    }

    private func ruleNotice(icon: String, tint: Color, background: Color,
                            text: String, button: String,
                            action: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action).buttonStyle(PrimaryButtonStyle())
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }

    private func targetsRows(for rule: Rule) -> [CoverageRow] {
        rule.targets(in: model.catalog, custom: model.store.customCategories)
            .compactMap { model.row(for: $0) }
    }

    private func scopeText(_ rule: Rule) -> String {
        let count = rule.targets(in: model.catalog, custom: model.store.customCategories).count
        switch rule.scope {
        case .category(let id): return "\(model.categoryName(id)) · \(count) types"
        case .subgroup(let c, let g): return "\(model.categoryName(c)) › \(g) · \(count) types"
        case .explicit: return "\(count) chosen types"
        }
    }

    private func applyNow(_ rule: Rule) {
        let targets = rule.targets(in: model.catalog, custom: model.store.customCategories)
        model.propose(title: rule.name.isEmpty ? "Apply rule" : "Apply “\(rule.name)”",
                      targets: targets,
                      to: model.inventory.app(id: rule.appID),
                      source: .ruleEnforcement)
    }

    // MARK: - Custom categories

    private var customCategories: some View {
        Group {
            if !model.store.customCategories.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader(title: "Your categories",
                                  subtitle: "Kept separate from the built-in ones, so an update can never overwrite them.")
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(model.store.customCategories) { category in
                                Button {
                                    screen = .category(category.id)
                                } label: {
                                    HStack(spacing: Theme.Space.s) {
                                        Image(systemName: category.icon)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.accent)
                                            .frame(width: 18)
                                        Text(category.name).bodyStyle()
                                        Spacer()
                                        Text("\(category.members.count) types").secondaryStyle()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                    .padding(.horizontal, Theme.Space.m)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(HoverRowStyle())
                                if category.id != model.store.customCategories.last?.id { RowDivider() }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Rule editor

struct RuleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    @State private var chosenApp: InstalledApp?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(rule.name.isEmpty ? "New rule" : "Edit rule").titleStyle()

            field("Name") {
                TextField("Code goes to Cursor", text: $rule.name)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    // The caption above names this field on screen, but nothing
                    // connects the two for VoiceOver, which would otherwise read
                    // out the placeholder — "Code goes to Cursor" sounds like a
                    // value already in the box rather than an example.
                    .accessibilityLabel("Name")
            }

            field("Applies to") {
                Picker("", selection: scopeBinding) {
                    ForEach(model.fileCategories) { c in Text(c.name).tag(c.id) }
                    ForEach(model.schemeCategories) { c in Text(c.name).tag(c.id) }
                    ForEach(model.store.customCategories) { c in Text(c.name).tag(c.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("Applies to")
            }

            field("Opens with") {
                HStack {
                    AppLabel(ref: appRef, placeholder: "Choose an application")
                    Spacer()
                    AppPicker(apps: model.inventory.apps, title: "Choose…", includeSystemDefault: false) { app in
                        guard let app else { return }
                        chosenApp = app
                        rule.appID = app.id
                        rule.appName = app.name
                    }
                }
            }

            field("Priority") {
                HStack(spacing: Theme.Space.s) {
                    Stepper(value: $rule.priority, in: 0...100) {
                        Text("\(rule.priority)").monospacedDigit().bodyStyle()
                    }
                    Text("Higher wins where two rules claim the same type.").secondaryStyle()
                }
            }

            Text("\(targetCount) file types are in this rule. Saving it does not change anything on its own — "
               + "use Apply now, and approve the change like any other.")
                .secondaryStyle()
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button("Save rule") {
                    model.saveRule(rule)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(rule.appID.isEmpty || rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 480)
        .background(Theme.background)
    }

    private var appRef: AppRef? {
        rule.appID.isEmpty ? nil : AppRef(id: rule.appID, name: rule.appName)
    }

    private var targetCount: Int {
        rule.targets(in: model.catalog, custom: model.store.customCategories).count
    }

    private var scopeBinding: Binding<String> {
        Binding(
            get: {
                if case .category(let id) = rule.scope { return id }
                if case .subgroup(let c, _) = rule.scope { return c }
                return model.fileCategories.first?.id ?? ""
            },
            set: { rule.scope = .category(id: $0) })
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).sectionLabelStyle()
            content()
        }
    }
}

// MARK: - Custom category editor

struct CategoryEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var members: [Target] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("New category").titleStyle()
            Text("Group the file types you care about, however you think about them. "
               + "Your categories sit alongside the built-in ones and are never overwritten.")
                .secondaryStyle()
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name, e.g. Work documents", text: $name)
                .textFieldStyle(.plain)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 6)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))

            TextField("What it is for (optional)", text: $summary)
                .textFieldStyle(.plain)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 6)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))

            AddTypeField { target in
                if !members.contains(target) { members.append(target) }
            }

            if !members.isEmpty {
                ScrollView {
                    FlowRow(members) { target in
                        HStack(spacing: 4) {
                            Text(target.display).font(.system(size: 11, design: .monospaced))
                            Button {
                                members.removeAll { $0 == target }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Take \(target.display) out of this rule")
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.surfaceRaised, in: Capsule())
                    }
                }
                .frame(maxHeight: 140)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button("Create") {
                    model.saveCustomCategory(CustomCategory(
                        name: name, kind: .file, icon: "square.grid.2x2",
                        summary: summary, members: members))
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 480)
        .background(Theme.background)
    }
}

/// Wrapping row of chips. `LazyVGrid` cannot do variable-width wrapping, and a
/// list of extensions is exactly that.
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { content($0) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Six per line reads well at this chip size and avoids a layout pass.
    private var rows: [[Item]] {
        stride(from: 0, to: items.count, by: 6).map {
            Array(items[$0..<min($0 + 6, items.count)])
        }
    }
}
