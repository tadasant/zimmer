import SwiftUI
import UIKit
import ZimmerKit

/// The app's design tokens: one place for every colour, radius, type role and the handful of
/// components built from them. Shaped like the Motet app's `Theme` (a ground, a surface, ink at
/// three strengths, hairlines instead of shadows, small tracked labels), coloured like the
/// Zimmer web UI so moving between the two feels like one product.
///
/// Light is the web UI's own palette: Tailwind gray-50 page, white cards, gray-200 rules,
/// gray-900 ink, indigo-600 accent. The web UI has no dark mode; dark here is built on the
/// PWA manifest's navy (`background_color` #000E2B, `theme_color` #031942), the same navy as the
/// app mark, with the ink and rules swapped.
enum Theme {
    // MARK: - Ground and ink

    /// The page: every screen's background, behind cards and lists. gray-50 / manifest navy.
    static let ground = dynamic(light: 0xF9FAFB, dark: 0x000E2B)
    /// Cards and grouped cells, one step up from the ground. white / manifest theme navy.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x031942)
    /// Fields, unselected chips and wells: one step down from a surface in light, up in dark.
    static let well = dynamic(light: 0xF3F4F6, dark: 0x0B2555)
    /// Titles and body text. gray-900 / gray-100.
    static let ink = dynamic(light: 0x111827, dark: 0xF3F4F6)
    /// Secondary text: subtitles, metadata. gray-600 / slate-300.
    static let inkSoft = dynamic(light: 0x4B5563, dark: 0xB4BFD3)
    /// Tertiary text and glyphs: ids, chevrons, placeholders. gray-400 / slate-500.
    static let inkMute = dynamic(light: 0x9CA3AF, dark: 0x6B7A96)
    /// Hairlines: card borders, dividers. gray-200 / white at 12%.
    static let rule = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.12) : UIColor(hex: 0xE5E7EB)
    })

    // MARK: - Accent and signature

    /// The web UI's one brand colour (`indigo-600`, buttons, links, focus rings), lifted to
    /// indigo-400 on navy so it still reads.
    static let accent = dynamic(light: 0x4F46E5, dark: 0x818CF8)
    /// The accent as a fill under white words and glyphs: indigo-600 / indigo-500, which keep
    /// white legible where indigo-400 would not.
    static let accentFill = dynamic(light: 0x4F46E5, dark: 0x6366F1)
    /// The gold ring of the app mark. A signature, used sparingly — a hairline under the
    /// primary button, the ring around an empty state, the favourite star — never for words.
    static let gold = dynamic(light: 0xE0A526, dark: 0xF2B947)
    /// The gold as a fill, the same in both appearances: the build strip.
    static let signatureGold = Color(uiColor: UIColor(hex: 0xF2B947))
    /// The mark's navy, the same in both appearances: the build strip's words.
    static let navy = Color(uiColor: UIColor(hex: 0x031942))

    /// Errors and destructive swipes. red-600 / red-400.
    static let danger = dynamic(light: 0xDC2626, dark: 0xF87171)
    /// Warnings: a failed trigger, an unusable root. orange-700 / orange-300, AA on both grounds.
    static let warning = dynamic(light: 0xC2410C, dark: 0xFDBA74)
    /// Success and "go": restore, invoke. green-600 / green-400.
    static let success = dynamic(light: 0x16A34A, dark: 0x4ADE80)
    /// Snooze and visibility: the web UI's indigo, a step away from the accent.
    static let snooze = dynamic(light: 0x6366F1, dark: 0xA5B4FC)

    // MARK: - Shape

    static let smallRadius: CGFloat = 12
    static let largeRadius: CGFloat = 18
    /// The horizontal margin every screen's content keeps from the edge.
    static let margin: CGFloat = 16

    // MARK: - Type

    /// Screen and detail titles. System sans, as the web UI's `font-sans` is on an iPhone.
    static func title(_ style: Font.TextStyle = .title2) -> Font { .system(style, weight: .bold) }
    /// A card or row title.
    static func headline(emphasized: Bool = false) -> Font { .system(.body, weight: emphasized ? .semibold : .medium) }
    /// The web UI's `font-mono` ids and branch lines.
    static let mono = Font.system(.caption, design: .monospaced)
    /// Small tracked labels: section heads, card heads.
    static func label(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .semibold) }

    // MARK: - Status

    /// A session status's colours: the web UI's `status_badge_classes` (`bg-*-100 text-*-800`)
    /// in light, the same hues at 300 on a deep wash in dark, and the 500 for a dot.
    struct StatusColors {
        let text: Color
        let fill: Color
        let dot: Color
    }

    static func status(_ status: SessionStatus) -> StatusColors {
        switch status {
        case .needsInput:
            return StatusColors(text: dynamic(light: 0x1E40AF, dark: 0x93C5FD), fill: wash(light: 0xDBEAFE, dark: 0x1E3A8A), dot: Color(uiColor: UIColor(hex: 0x3B82F6)))
        case .running:
            return StatusColors(text: dynamic(light: 0x166534, dark: 0x86EFAC), fill: wash(light: 0xDCFCE7, dark: 0x14532D), dot: Color(uiColor: UIColor(hex: 0x22C55E)))
        case .waiting:
            return StatusColors(text: dynamic(light: 0x6B21A8, dark: 0xD8B4FE), fill: wash(light: 0xF3E8FF, dark: 0x581C87), dot: Color(uiColor: UIColor(hex: 0xA855F7)))
        case .failed:
            return StatusColors(text: dynamic(light: 0x9A3412, dark: 0xFDBA74), fill: wash(light: 0xFFEDD5, dark: 0x7C2D12), dot: Color(uiColor: UIColor(hex: 0xF97316)))
        case .archived, .unknown:
            return StatusColors(text: dynamic(light: 0x1F2937, dark: 0xD1D5DB), fill: wash(light: 0xF3F4F6, dark: 0x374151), dot: Color(uiColor: UIColor(hex: 0x9CA3AF)))
        }
    }

    /// Swipe actions carry the system's white label, so their fills are the 600s in both
    /// appearances rather than the lighter dark-mode tints.
    enum Swipe {
        static let favorite = Color(uiColor: UIColor(hex: 0xCA8A04))
        static let restore = Color(uiColor: UIColor(hex: 0x16A34A))
        static let trash = Color(uiColor: UIColor(hex: 0xDC2626))
        static let snooze = Color(uiColor: UIColor(hex: 0x4F46E5))
    }

    /// A pull request's state colour, the web UI's `pr_icon_color_class`.
    static func pullRequest(_ state: String?) -> Color {
        switch state {
        case "merged": return dynamic(light: 0x9333EA, dark: 0xC084FC)
        case "open": return success
        case "closed": return danger
        default: return inkMute
        }
    }

    /// A CI result's dot, the web UI's `ci_status_bg_class`.
    static func ci(_ result: String) -> Color {
        switch result {
        case "pass": return Color(uiColor: UIColor(hex: 0x22C55E))
        case "fail": return Color(uiColor: UIColor(hex: 0xEF4444))
        case "pending": return Color(uiColor: UIColor(hex: 0xEAB308))
        default: return inkMute
        }
    }

    // MARK: - Construction

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: dynamicUIColor(light: light, dark: dark))
    }

    fileprivate static func dynamicUIColor(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    /// A badge fill: the web UI's pastel in light, a translucent deep shade on navy.
    private static func wash(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(hex: dark).withAlphaComponent(0.55) : UIColor(hex: light)
        })
    }

    // MARK: - UIKit chrome

    /// The navigation bar's title colours, set once at launch. Only the text: the bars keep the
    /// system's own material, so they stay native on every iOS. The tint is `ZimmerApp`'s.
    @MainActor
    static func applyBarAppearance() {
        let ink = dynamicUIColor(light: 0x111827, dark: 0xF3F4F6)
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.foregroundColor: ink]
        bar.titleTextAttributes = [.foregroundColor: ink, .font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Modifiers

extension View {
    /// A card: a surface fill and a 1pt hairline, no shadow — the web UI's white card on gray,
    /// drawn the way Motet draws its cards.
    func themeCard(radius: CGFloat = Theme.largeRadius, fill: Color = Theme.surface) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Theme.rule, lineWidth: 1)
                )
        )
    }

    /// A small uppercase tracked label: a card's head, a section's head.
    func themeLabel(size: CGFloat = 11, color: Color = Theme.inkSoft) -> some View {
        font(Theme.label(size))
            .textCase(.uppercase)
            .tracking(size * 0.12)
            .foregroundStyle(color)
    }

    /// The ground behind a List, Form or ScrollView, replacing the system's grouped gray.
    func themeGround() -> some View {
        scrollContentBackground(.hidden).background(Theme.ground)
    }

    /// List or Form rows on the theme's surface and hairline, in place of the system's grays.
    /// On a `Group` around a list's sections it reaches every row in them.
    func themeRows() -> some View {
        listRowBackground(Theme.surface).listRowSeparatorTint(Theme.rule)
    }

    /// A List row drawn as a free-standing card on the ground. In an inset-grouped list the
    /// section already keeps its margin, so the row adds none of its own.
    func themeCardRow(inset: CGFloat = 0) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .themeCard()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: inset, bottom: 4, trailing: inset))
    }
}

// MARK: - Components

/// The one filled button: a full-width capsule in the accent, with the mark's gold as a
/// hairline along its foot. Presses to 0.85.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline))
            .foregroundStyle(.white)
            .padding(.vertical, 15)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .background(Theme.accentFill.opacity(isEnabled ? 1 : 0.4))
            .overlay(alignment: .bottom) {
                if isEnabled { Theme.gold.frame(height: 2.5) }
            }
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A capsule for a choice or a short action: outlined at rest, filled when selected. The
/// filter chips and the quick replies.
struct Pill<Content: View>: View {
    var selected = false
    /// A smaller pill, for a row of choices that should not crowd what they sit under.
    var compact = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .font(.system(compact ? .footnote : .subheadline, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.white : Theme.ink)
            .padding(.horizontal, compact ? 11 : 14)
            .frame(minHeight: compact ? 28 : 34)
            .background(Capsule().fill(selected ? Theme.accentFill : Theme.surface))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.rule, lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// An empty or finished list: one symbol inside the mark's gold ring, a title, a sentence.
struct EmptyState: View {
    let title: String
    let symbol: String
    var message: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Theme.surface))
                .overlay(Circle().strokeBorder(Theme.gold.opacity(0.85), lineWidth: 1.5))
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSoft)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }
}

/// A list or screen still loading: a small spinner and a word, on the ground.
struct LoadingState: View {
    var text = "Loading…"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.subheadline).foregroundStyle(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A titled card: the label in the corner, an optional action opposite it, then the content.
struct ThemeCard<Content: View, Action: View>: View {
    let title: String
    @ViewBuilder var action: Action
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).themeLabel()
                Spacer()
                action.font(.footnote.weight(.medium))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .themeCard()
    }
}
