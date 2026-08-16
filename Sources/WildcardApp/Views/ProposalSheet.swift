import SwiftUI
import WildcardKit

/// The gate. Nothing reaches LaunchServices except through a person reading
/// this and pressing Apply — whether the request came from this window, the
/// command line, or an agent.
struct ProposalSheet: View {
    @EnvironmentObject private var model: AppModel
    let proposal: Proposal

    @State private var showAll = false

    private var items: [ChangeItem] { proposal.effectiveItems }
    private var shown: [ChangeItem] { showAll ? items : Array(items.prefix(12)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let note = proposal.note, !note.isEmpty {
                        Text(note)
                            .secondaryStyle()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(proposal.warnings) { warning in
                        WarningBox(warning: warning)
                    }
                    diff
                }
                .padding(Theme.Space.l)
            }

            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: 620, height: 560)
        .background(Theme.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(proposal.title).titleStyle()
                Spacer()
                if proposal.source.isExternal || proposal.source == .autoAdopt {
                    Tag(text: "Requested by \(proposal.source.label)",
                        tint: Theme.accent, background: Theme.accentSoft)
                }
            }
            Text(proposal.summaryLine)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
        .padding(Theme.Space.l)
        .padding(.bottom, Theme.Space.m - Theme.Space.s)
    }

    // MARK: - Diff

    private var diff: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "What will change")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(shown) { item in
                        DiffRow(item: item)
                        if item.id != shown.last?.id { RowDivider() }
                    }
                }
            }
            if items.count > shown.count {
                Button("Show all \(items.count)") { showAll = true }
                    .buttonStyle(.link)
            }
            if proposal.alreadyCorrectCount > 0 {
                Text("\(proposal.alreadyCorrectCount) already open correctly and will be left alone.")
                    .secondaryStyle()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text(expiryText).secondaryStyle()
            Spacer()
            Button("Reject") { model.reject(proposal) }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(applyTitle) { model.approve(proposal) }
                .buttonStyle(PrimaryButtonStyle())
                // Return applies your own change, because you asked for it a
                // moment ago and confirming it is the expected next keystroke.
                // A request from the command line or an agent puts this sheet in
                // front of you unbidden, possibly mid-sentence in another app —
                // there, Return must not be enough to rewrite how your files
                // open. Escape still rejects either way; refusing is always the
                // cheap key.
                .keyboardShortcut(proposal.source.isExternal ? nil : .defaultAction)
                .disabled(items.isEmpty)
        }
        .padding(Theme.Space.m)
    }

    private var applyTitle: String {
        items.count == 1 ? "Apply 1 change" : "Apply \(items.count) changes"
    }

    private var expiryText: String {
        let remaining = Int(proposal.expiresAt.timeIntervalSinceNow / 60)
        if remaining <= 0 { return "This request has expired." }
        return "Expires in \(remaining) minute\(remaining == 1 ? "" : "s") if not decided."
    }
}

/// One line of the diff: what it is, what opens it now, what would open it.
private struct DiffRow: View {
    let item: ChangeItem

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.target.display)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                if !item.collateral.isEmpty {
                    Text("shares a type with .\(item.collateral.prefix(3).joined(separator: ", ."))")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 130, alignment: .leading)

            HStack(spacing: 5) {
                AppLabel(ref: item.fromApp, placeholder: "Nothing", size: 14)
                    .opacity(0.65)
                if item.fromOrigin == .implicit, item.fromApp != nil {
                    Text("(inherited)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)

            VStack(alignment: .leading, spacing: 1) {
                AppLabel(ref: item.toApp, placeholder: "macOS decides", size: 14)
                // Undo takes the binding away rather than pinning the old app,
                // so name the app that gets it back — "macOS decides" on its
                // own is true and tells you nothing.
                if item.toApp == nil, let back = item.expectedFallback {
                    Text("back to \(back.name)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let now = item.fromApp?.name ?? "nothing"
        guard item.toApp == nil else {
            return "\(item.target.display), currently \(now), will become \(item.toApp!.name)"
        }
        if let back = item.expectedFallback {
            return "\(item.target.display), currently \(now), goes back to macOS choosing, "
                + "which opened it with \(back.name) before"
        }
        return "\(item.target.display), currently \(now), will become the macOS default"
    }
}

/// Says the awkward thing before it happens, in the words someone would use.
private struct WarningBox: View {
    let warning: ProposalWarning

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.attention)
                .padding(.top, 1)
            Text(warning.message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.attentionSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }

    private var icon: String {
        switch warning.kind {
        case .sharedType: return "arrow.triangle.branch"
        case .systemPrompt: return "exclamationmark.bubble"
        case .appDoesNotDeclare: return "questionmark.app"
        case .missingApp: return "xmark.app"
        }
    }
}
