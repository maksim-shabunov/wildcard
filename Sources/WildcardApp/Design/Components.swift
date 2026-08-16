import AppKit
import SwiftUI
import WildcardKit

// MARK: - Surfaces

/// A panel: a lighter rectangle with a hairline around it.
///
/// Flat on purpose. Every card used to carry a drop shadow, which made a screen
/// of them look like a pile of loose paper floating over the window instead of
/// one printed page.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.m
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).sectionLabelStyle()
            if let subtitle { Text(subtitle).secondaryStyle() }
        }
    }
}

/// What the app says when there is genuinely nothing to show. Never a dead end —
/// it says why, in a sentence.
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title).headingStyle()
            Text(message)
                .secondaryStyle()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }
}

// MARK: - Application identity

/// An app's real icon, read from its bundle. Falls back to a neutral glyph so a
/// missing app still reads as an app rather than as a broken image.
struct AppIcon: View {
    let ref: AppRef?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = Self.image(for: ref) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .resizable()
                    .foregroundStyle(Theme.textTertiary)
                    .padding(1)
            }
        }
        .frame(width: size, height: size)
    }

    private static var cache: [String: NSImage] = [:]

    private static func image(for ref: AppRef?) -> NSImage? {
        guard let ref else { return nil }
        if let hit = cache[ref.id] { return hit }
        let url = ref.url ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: ref.id)
        guard let url else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        cache[ref.id] = icon
        return icon
    }
}

/// "Cursor" with its icon, or a plain statement that nothing opens this.
struct AppLabel: View {
    let ref: AppRef?
    var placeholder = "Nothing opens this"
    var size: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            if ref != nil { AppIcon(ref: ref, size: size) }
            Text(ref?.name ?? placeholder)
                .font(.system(size: 13))
                .foregroundStyle(ref == nil ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
        }
    }
}

// MARK: - Status

/// Coverage as a word, not a coloured dot. The one case that gets colour is the
/// one that needs a decision.
struct CoverageTag: View {
    let coverage: Coverage
    let origin: BindingOrigin

    var body: some View {
        switch coverage {
        case .drifted:
            Tag(text: "Changed", tint: Theme.attention, background: Theme.attentionSoft)
        case .notApplied:
            Tag(text: "Not applied", tint: Theme.textSecondary, background: Theme.surfaceRaised)
        case .covered:
            Tag(text: "By rule", tint: Theme.accent, background: Theme.accentSoft)
        case .uncovered:
            if origin == .explicit {
                Tag(text: "Set by hand", tint: Theme.textSecondary, background: Theme.surfaceRaised)
            } else if origin == .none {
                Tag(text: "Unassigned", tint: Theme.textTertiary, background: Theme.surfaceRaised)
            } else {
                Tag(text: "macOS default", tint: Theme.textTertiary, background: Theme.surfaceRaised)
            }
        }
    }
}

struct Tag: View {
    let text: String
    var tint: Color = Theme.textSecondary
    var background: Color = Theme.surfaceRaised

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
    }
}

/// A count with its label. Monospaced digits so the numbers do not jitter as
/// they update.
struct StatTile: View {
    let value: Int
    let label: String
    var tint: Color = Theme.textPrimary
    var action: (() -> Void)?

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 26, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value) \(label)")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Controls

/// The primary action. The only place the accent appears as a fill.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Theme.accent.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }
}

/// Everything that is not the primary action: a plain surface with a hairline,
/// so it reads as a control without competing with the accent.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                configuration.isPressed ? Theme.surfaceRaised : Theme.surface,
                in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Choose an installed application. Searchable, because there are usually a
/// hundred of them and scrolling a menu is not a way to find one.
struct AppPicker: View {
    let apps: [InstalledApp]
    let title: String
    var includeSystemDefault = true
    /// nil means "hand it back to macOS".
    let onChoose: (InstalledApp?) -> Void

    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        Button {
            query = ""
            isPresented = true
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            picker
        }
    }

    private var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return apps }
        return apps.filter { $0.name.lowercased().contains(q) || $0.id.contains(q) }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search applications", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 10)

            Divider().overlay(Theme.hairline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if includeSystemDefault {
                        row(icon: nil, name: "Let macOS decide",
                            detail: "Remove the assignment") {
                            onChoose(nil)
                            isPresented = false
                        }
                        Divider().overlay(Theme.hairline).padding(.horizontal, Theme.Space.s)
                    }
                    ForEach(filtered) { app in
                        row(icon: app.ref, name: app.name, detail: app.id) {
                            onChoose(app)
                            isPresented = false
                        }
                    }
                }
                .padding(Theme.Space.xs)
            }
            .frame(height: 300)
        }
        .frame(width: 320)
        .background(Theme.surface)
    }

    private func row(icon: AppRef?, name: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                if let icon {
                    AppIcon(ref: icon, size: 18)
                } else {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11))
                        .frame(width: 18)
                        .foregroundStyle(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).bodyStyle().lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

/// Rows highlight on hover with a tonal step, not a border.
struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                (configuration.isPressed || hovering) ? Theme.surfaceRaised : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .onHover { hovering = $0 }
    }
}

// MARK: - Type rows

/// One file type or link type, as it reads everywhere in the app:
/// "Kotlin source · .kt — opens with Warp".
struct TypeRow: View {
    let row: CoverageRow
    var showCategory = false
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).bodyStyle().lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.target.display)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    if showCategory, let name = row.categoryName {
                        Text("·").foregroundStyle(Theme.textTertiary)
                        Text(name).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let expected = row.expected {
                HStack(spacing: 4) {
                    Text("should be")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    AppLabel(ref: expected, size: 14)
                }
            }

            AppLabel(ref: row.binding.handler)
                .frame(width: 170, alignment: .leading)

            CoverageTag(coverage: row.coverage, origin: row.binding.origin)
                .frame(width: 104, alignment: .leading)

            if let trailing { trailing }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let opener = row.binding.handler?.name ?? "nothing"
        var text = "\(row.label), \(row.target.display), opens with \(opener)"
        if let e = row.expected {
            text += row.coverage == .drifted
                ? ", but a rule expects \(e.name)"
                : "; a rule asks for \(e.name) and has not been applied"
        }
        return text
    }
}

/// Separates rows inside a card without drawing a box around each one.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.leading, Theme.Space.m)
    }
}
