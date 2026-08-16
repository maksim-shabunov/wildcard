import AppKit
import SwiftUI
import WildcardKit

/// Settings, in the window rather than in a panel of their own.
///
/// A separate settings window is the Mac default, and it was the wrong shape for
/// these: half of what is here is about what the rest of the window does, and
/// the integration cards are things you read from and copy out of while looking
/// at it. So this is a screen like any other, reached from the sidebar — ⌘,
/// still works and now brings you here instead of opening a second window.
///
/// The two panels stay separate rather than becoming one long column: appearance
/// switches and MCP configuration have nothing to say to each other.
struct SettingsView: View {
    @State private var panel: Panel = .general

    enum Panel: String, CaseIterable, Identifiable {
        case general = "General"
        case integrations = "Integrations"
        var id: String { rawValue }
    }

    var body: some View {
        Page(title: "Settings", subtitle: subtitle) {
            Picker("", selection: $panel) {
                ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
            .accessibilityLabel("Settings panel")
        } content: {
            switch panel {
            case .general: GeneralSettings()
            case .integrations: IntegrationSettings()
            }
        }
        // The switches and the segmented controls are the only system controls
        // in the app, and in a settings window of their own nobody minded that
        // they came up in the system's blue. On the app's own page, next to its
        // own accent, they were the only blue in the window.
        .tint(Theme.accent)
    }

    private var subtitle: String {
        switch panel {
        case .general: return "How Wildcard behaves on this Mac."
        case .integrations: return "How agents and the command line reach it."
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel

    // No `ScrollView` of its own: the page this sits in already scrolls, and two
    // nested scroll views give the inner one a height that depends on its
    // content and a wheel that stops working halfway down.
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            group("Appearance") {
                Picker("", selection: Binding(
                    get: { model.settings.appearance },
                    set: { v in model.update { $0.appearance = v } })) {
                    Text("Match system").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            group("New file types") {
                setting(
                    "Watch for file types as they appear",
                    "Notices when an installed application starts claiming a type nothing has decided about.",
                    get: { model.settings.watchForNewTypes },
                    set: { v in model.update { $0.watchForNewTypes = v } })

                setting(
                    "Offer to apply matching rules",
                    "When a new type falls inside a rule you already set, Wildcard prepares the change and "
                  + "asks you to approve it. It is never applied on its own.",
                    get: { model.settings.autoAdoptWhenRuleMatches },
                    set: { v in model.update { $0.autoAdoptWhenRuleMatches = v } })
            }

            group("Safety") {
                setting(
                    "Take a snapshot before every change",
                    "A full copy of every assignment, so there is always a way back even if an undo goes wrong.",
                    get: { model.settings.snapshotBeforeApply },
                    set: { v in model.update { $0.snapshotBeforeApply = v } })
            }

            group("Where Wildcard keeps its files") {
                HStack {
                    Text(Store.directory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Store.directory])
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Text("Plain JSON. Rules, history and snapshots are all readable and editable by hand.")
                    .secondaryStyle()
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: title)
            Card { VStack(alignment: .leading, spacing: Theme.Space.m) { content() } }
        }
    }

    private func setting(_ title: String, _ detail: String,
                         get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bodyStyle()
                Text(detail).secondaryStyle().fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            Toggle("", isOn: Binding(get: get, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

// MARK: - Integrations

private struct IntegrationSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirming: Integrations.Client?
    @State private var message: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            enableCard
            if model.settings.agentAccessEnabled {
                clientsCard
                manualCard
                commandLineCard
            }
        }
        .alert(item: Binding(
            get: { confirming.map { ConfirmTarget(client: $0) } },
            set: { confirming = $0?.client })) { target in
            Alert(
                title: Text("Edit \(target.client.name)'s configuration?"),
                message: Text("Wildcard will add its MCP server to \(target.client.path.path). "
                            + "A copy of the current file is kept alongside it."),
                primaryButton: .default(Text("Add Wildcard")) { install(target.client) },
                secondaryButton: .cancel())
        }
    }

    private struct ConfirmTarget: Identifiable {
        let client: Integrations.Client
        var id: String { client.id }
    }

    private var enableCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Let agents operate Wildcard").headingStyle()
                        Text("Claude Code, Codex or a desktop AI client can read your associations and ask for "
                           + "changes. Wildcard makes no network calls and contains no AI of its own.")
                            .secondaryStyle()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.m)
                    Toggle("", isOn: Binding(
                        get: { model.settings.agentAccessEnabled },
                        set: { v in model.update { $0.agentAccessEnabled = v } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("Let agents operate Wildcard")
                }

                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Image(systemName: "lock")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 1)
                    Text("An agent can only ever propose. Every request appears in this window with the full "
                       + "list of what would change, and applies nothing until you approve it here. "
                       + "There is no setting that turns that off.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.s + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            }
        }
    }

    private var clientsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "Install",
                          subtitle: "Each of these edits that application's own configuration file, so it asks first.")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Integrations.all) { client in
                        HStack(spacing: Theme.Space.m) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.name).bodyStyle()
                                Text(client.isInstalled ? client.detail : "Not found on this Mac.")
                                    .secondaryStyle()
                            }
                            Spacer()
                            if Integrations.isInstalled(in: client) {
                                Tag(text: "Added", tint: Theme.accent, background: Theme.accentSoft)
                            }
                            Button(Integrations.isInstalled(in: client) ? "Update" : "Add") {
                                confirming = client
                            }
                            .buttonStyle(QuietButtonStyle())
                        }
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, 10)
                        if client.id != Integrations.all.last?.id { RowDivider() }
                    }
                }
            }
            if let message {
                Text(message).secondaryStyle()
            }
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.attention)
            }
        }
    }

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "Anywhere else",
                          subtitle: "Paste this into any MCP client's configuration.")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(Integrations.snippet)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                    HStack {
                        Spacer()
                        Button("Copy") { copy(Integrations.snippet) }.buttonStyle(QuietButtonStyle())
                    }
                }
            }
        }
    }

    private var commandLineCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "Command line",
                          subtitle: "The same helper is also a command-line tool. Writes wait for approval here, exactly like an agent's.")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(Integrations.commandLineSnippet)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy command") { copy(Integrations.commandLineSnippet) }
                            .buttonStyle(QuietButtonStyle())
                        Spacer()
                        Button(Integrations.symlinkExists ? "Relink to ~/.local/bin" : "Link to ~/.local/bin") {
                            do { message = try Integrations.installSymlink(); problem = nil }
                            catch { problem = error.localizedDescription }
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                }
            }
        }
    }

    private func install(_ client: Integrations.Client) {
        do {
            message = try Integrations.install(into: client)
            problem = nil
        } catch {
            problem = error.localizedDescription
            message = nil
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "Copied."
    }
}
