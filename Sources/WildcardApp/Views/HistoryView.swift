import SwiftUI
import WildcardKit

/// Everything that has been applied, where it came from, and how to put it back.
///
/// Changes made through the command line or by an agent appear here exactly like
/// changes made in the window — same detail, same undo.
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expanded: Set<String> = []
    @State private var snapshotName = ""
    @State private var namingSnapshot = false

    var body: some View {
        Page(title: "History", subtitle: subtitle) {
            Button("Save a snapshot") {
                snapshotName = ""
                namingSnapshot = true
            }
            .buttonStyle(QuietButtonStyle())
        } content: {
            if model.history.isEmpty {
                Card {
                    EmptyState(
                        icon: "clock.arrow.circlepath",
                        title: "Nothing has been changed yet",
                        message: "Every change Wildcard applies is recorded here with what it was before, "
                               + "so any of it can be put back.")
                }
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(model.history) { entry in
                            VStack(spacing: 0) {
                                HistoryRow(
                                    entry: entry,
                                    isExpanded: expanded.contains(entry.id),
                                    onToggle: { toggle(entry.id) },
                                    onUndo: { model.proposeRollback(of: entry) })
                                if expanded.contains(entry.id) { detail(entry) }
                            }
                            if entry.id != model.history.last?.id { RowDivider() }
                        }
                    }
                }
            }
            snapshots
        }
        .sheet(isPresented: $namingSnapshot) { snapshotSheet }
    }

    private var subtitle: String {
        model.history.isEmpty
            ? "Nothing yet."
            : "\(model.history.count) \(model.history.count == 1 ? "change" : "changes"), newest first."
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: - Per-entry detail

    private func detail(_ entry: HistoryEntry) -> some View {
        let outcomes = Dictionary(uniqueKeysWithValues: entry.results.map { ($0.target, $0.outcome) })
        return VStack(spacing: 0) {
            ForEach(entry.items.filter { !$0.isNoOp }) { item in
                HStack(spacing: Theme.Space.m) {
                    Text(item.target.display)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 110, alignment: .leading)
                    Text(item.fromApp?.name ?? "nothing")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                    Text(item.toApp?.name
                         ?? item.expectedFallback.map { "macOS default — \($0.name)" }
                         ?? "macOS default")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    outcomeTag(outcomes[item.target])
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 5)
            }
        }
        .padding(.vertical, Theme.Space.s)
        .background(Theme.surfaceRaised.opacity(0.5))
    }

    @ViewBuilder
    private func outcomeTag(_ outcome: ApplyResult.Outcome?) -> some View {
        switch outcome {
        case .applied: Tag(text: "Applied")
        case .unchanged: Tag(text: "No change")
        case .failed(let reason):
            Tag(text: reason, tint: Theme.attention, background: Theme.attentionSoft)
        case nil: EmptyView()
        }
    }

    // MARK: - Snapshots

    private var snapshots: some View {
        Group {
            if !model.snapshots.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader(
                        title: "Snapshots",
                        subtitle: "A full copy of every assignment. One is taken automatically before each change.")
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(model.snapshots) { snapshot in
                                HStack(spacing: Theme.Space.m) {
                                    Image(systemName: snapshot.isAutomatic ? "clock" : "bookmark")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textTertiary)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(snapshot.name).bodyStyle().lineLimit(1)
                                        Text("\(snapshot.count) assignments · \(Self.when(snapshot.createdAt))")
                                            .secondaryStyle()
                                    }
                                    Spacer()
                                    Button("Restore") { model.proposeRestore(of: snapshot) }
                                        .buttonStyle(QuietButtonStyle())
                                    Button {
                                        model.store.deleteSnapshot(id: snapshot.id)
                                    } label: {
                                        Image(systemName: "trash").font(.system(size: 11))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.textTertiary)
                                    .accessibilityLabel("Delete the snapshot “\(snapshot.name)”")
                                    .help("Delete this snapshot. Nothing about how files open changes.")
                                }
                                .padding(.horizontal, Theme.Space.m)
                                .padding(.vertical, 10)
                                if snapshot.id != model.snapshots.last?.id { RowDivider() }
                            }
                        }
                    }
                }
            }
        }
    }

    private var snapshotSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Save a snapshot").titleStyle()
            Text("Records what opens every file type right now, so you can come back to this exact state later.")
                .secondaryStyle()
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name it, e.g. Before trying Zed", text: $snapshotName)
                .textFieldStyle(.plain)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 6)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { namingSnapshot = false }.buttonStyle(QuietButtonStyle())
                Button("Save", action: save).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 420)
        .background(Theme.background)
    }

    private func save() {
        model.saveSnapshot(named: snapshotName)
        namingSnapshot = false
    }

    static func when(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// One applied change. Reads as a sentence, with the source named — an agent's
/// change is never anonymous.
struct HistoryRow: View {
    let entry: HistoryEntry
    var compact = false
    var isExpanded = false
    var onToggle: (() -> Void)?
    var onUndo: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if !compact {
                Button {
                    onToggle?()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide what this changed" : "Show what this changed")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).bodyStyle().lineLimit(1)
                HStack(spacing: 6) {
                    Text(HistoryView.when(entry.appliedAt)).secondaryStyle()
                    Text("·").foregroundStyle(Theme.textTertiary)
                    Text(entry.source.label).secondaryStyle()
                    if entry.failedCount > 0 {
                        Text("· \(entry.failedCount) did not take")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.attention)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(entry.appliedCount)")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)

            if entry.rolledBackAt != nil {
                Tag(text: "Undone")
            } else if !compact, entry.canRollBack {
                Button("Undo") { onUndo?() }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title), \(entry.appliedCount) changed, by \(entry.source.label)")
    }
}
