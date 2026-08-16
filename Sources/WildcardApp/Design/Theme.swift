import AppKit
import SwiftUI

/// The visual language: warm neutrals, flat surfaces, one muted plum accent.
///
/// Two deliberate rules, both of which the first attempt broke:
///
/// **Nothing is translucent.** Every surface is an opaque colour. Vibrancy and
/// glass materials pick up whatever is behind the window, which makes a warm
/// palette read as grey and makes panels look like they are floating over the
/// app rather than being part of it.
///
/// **Depth comes from tone and a hairline, never from a drop shadow.** A card is
/// a lighter rectangle with a one-pixel border. Shadows under every panel make an
/// interface look like a stack of loose paper; this one should look like one
/// printed page.
///
/// Colours are built as dynamic `NSColor`s so light and dark are two chosen
/// palettes rather than one palette with its brightness inverted.
enum Theme {

    // MARK: - Colour

    /// The content area. Warm paper, never a neutral grey.
    static let background = dynamic(light: 0xFAF9F5, dark: 0x262624)
    /// The sidebar: one step deeper than the page, so the split reads without a
    /// heavy divider.
    static let sidebar = dynamic(light: 0xF0EEE6, dark: 0x1F1E1D)
    /// Cards and rows sitting on the page.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x30302E)
    /// One step further forward — hover, selection, nested wells, inputs.
    static let surfaceRaised = dynamic(light: 0xECE9DF, dark: 0x3A3A37)
    /// Hover in the sidebar, which is already darker than the page.
    static let sidebarHover = dynamic(light: 0xE5E2D6, dark: 0x2B2A28)
    /// The selected sidebar row.
    static let sidebarSelected = dynamic(light: 0xDCD8C9, dark: 0x3A3A37)

    static let textPrimary = dynamic(light: 0x33322E, dark: 0xF0EEE6)
    static let textSecondary = dynamic(light: 0x6E6B63, dark: 0xA8A5A0)
    static let textTertiary = dynamic(light: 0x97938B, dark: 0x7C7975)

    /// The accent. Primary actions and active state only — the rest of the
    /// interface is deliberately neutral.
    static let accent = dynamic(light: 0x8A6A82, dark: 0xB08FA8)
    static let accentSoft = dynamic(light: 0xF0E9EE, dark: 0x3A3038)

    /// Reserved for the one thing that genuinely warrants attention: a binding a
    /// rule claims that something else has changed.
    static let attention = dynamic(light: 0xA8732E, dark: 0xD3A15C)
    static let attentionSoft = dynamic(light: 0xF6EFE3, dark: 0x3A3227)

    /// The one-pixel line that gives a surface its edge. Borders around panels,
    /// separators inside them, and the split between sidebar and page.
    static let hairline = dynamic(light: 0xE4E1D6, dark: 0x3D3C39)

    // MARK: - Shape

    enum Radius {
        /// Inputs, tags, small controls.
        static let small: CGFloat = 6
        /// Buttons and sidebar rows.
        static let medium: CGFloat = 8
        /// Panels and cards.
        static let large: CGFloat = 10
    }

    /// 8pt rhythm, generous.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    /// How far the page column's heading sits below the top of the window.
    ///
    /// The window draws its content full-size behind a transparent title bar so
    /// the sidebar colour reaches the top edge. That strip still belongs to the
    /// title bar — it is the window's drag region — so nothing interactive may be
    /// placed in it. The sidebar's wordmark is text, and sits up there beside the
    /// traffic lights; the page's title is clear of them and keeps its air.
    static let titlebar: CGFloat = 52

    // MARK: - Building blocks

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

// MARK: - Text

extension View {
    func titleStyle() -> some View {
        font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.textPrimary)
    }

    func headingStyle() -> some View {
        font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
    }

    func bodyStyle() -> some View {
        font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
    }

    func secondaryStyle() -> some View {
        font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
    }

    /// The small label above a group. Sentence case, not shouted — the previous
    /// all-caps treatment competed with the headings it was meant to sit under.
    func sectionLabelStyle() -> some View {
        font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
    }
}
