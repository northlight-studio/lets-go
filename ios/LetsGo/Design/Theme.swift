import SwiftUI
import UIKit

/// Paperwhite: the app follows the phone's light and dark, the way Maps does. By day,
/// paper and near-black ink; after dark, charcoal paper and cream ink. The map is ours
/// (`PaperMap`, drawn from our own style), and it carries no colour but what's ours: the
/// red-orange accent marks what's on now and what you tapped, ink is the one prominent
/// button a screen, and you are the system blue dot. Chrome is the system's own Liquid
/// Glass (tab bar, toolbar buttons, sheets, the search field and the time rail); nothing
/// here draws behind it. The map's quick-decide mode (`Signal`) keeps its own black and lime.
enum Palette {
    /// The page: paper by day, charcoal after dark. The map's paper is the same colour.
    static let bg = Color(light: 0xF4F2EC, dark: 0x1C1C1A)
    /// Sheets and pages that sit on the map.
    static let surface = Color(light: 0xF8F6F1, dark: 0x22221F)
    /// A card on the page: white by day, a lift of the charcoal after dark.
    static let card = Color(light: 0xFFFFFF, dark: 0x2A2A27)
    /// Empty seats, unfilled bars, the quietest fills.
    static let raise = Color(light: 0xE6E2D8, dark: 0x34342F)
    /// Near-black on paper, cream on charcoal.
    static let ink = Color(light: 0x1B1A17, dark: 0xF1EDE3)
    static let muted = Color(light: 0x6E695F, dark: 0x9A958A)
    /// A step stronger than `muted`, for body copy on glass.
    static let soft = Color(light: 0x45423B, dark: 0xC9C4B8)
    /// Street names and the quietest labels: the map's label grey.
    static let faint = Color(light: 0x8C877C, dark: 0x7D786E)
    static let line = Color(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.1)
    /// The one prominent button a screen: ink, with paper on it.
    static let prominent = ink
    /// Text and glyphs on `prominent`.
    static let onProminent = Color(light: 0xF4F2EC, dark: 0x1C1C1A)
    /// Red-orange: on the map, only what's on now and what you tapped. Elsewhere, the
    /// small marks that are ours (a seat waiting for you, a full stop).
    static let accent = Color(light: 0xD9502A, dark: 0xF07A45)
    /// The accent as text on the page, a step darker by day so it reads on paper.
    static let accentSoft = Color(light: 0xB8401E, dark: 0xF49A6E)
    /// Paper on the accent, in both appearances.
    static let accentInk = Color(hex: 0xFFFFFF)
    static let star = Color(light: 0xD9952A, dark: 0xF2BE62)
    /// You: the system blue dot.
    static let me = Color(uiColor: .systemBlue)
    /// Kinds of things in lists (never on the map).
    static let compass = Color(light: 0x2F6FD6, dark: 0x8FB4E6)
    /// A friend who's in.
    static let live = Color(light: 0x1F9D55, dark: 0x6FD49A)
    /// A porch light: someone up for something.
    static let porch = Color(light: 0xE08A12, dark: 0xFFB547)
    static let porchSoft = Color(light: 0xB86E00, dark: 0xFFC88A)
    /// A slider's thumb (the time rail's): white, a touch of cream after dark.
    static let knob = Color(light: 0xFFFFFF, dark: 0xF1EDE3)
    static let shadow = Color(light: 0x000000, lightAlpha: 0.28, dark: 0x000000, darkAlpha: 0.5)
    /// A walking route on the plan and walk screens: the accent, since it goes to what you chose.
    /// (The main map draws its own hairlines; see `PaperMap`.)
    static let walk = accent
}

/// The map's own colours, as UIKit colours for MapLibre's views and overlays. They match
/// `Palette` and the bundled styles (`paperwhite-light.json`, `paperwhite-dark.json`).
enum MapInk {
    static let paper = UIColor(light: 0xF4F2EC, dark: 0x1C1C1A)
    static let ink = UIColor(light: 0x1B1A17, dark: 0xF1EDE3)
    static let accent = UIColor(light: 0xD9502A, dark: 0xF07A45)
    /// Paper-coloured text on a filled tag.
    static let onFill = UIColor(light: 0xFFFFFF, dark: 0x1C1C1A)
}

extension UIColor {
    /// One colour by day, another after dark.
    convenience init(light: UInt32, dark: UInt32) {
        let day = UIColor(hex: light), night = UIColor(hex: dark)
        self.init(dynamicProvider: Color.provider(day: day, night: night))
    }
}

/// The quick-decide look: black, white and one acid lime. Numbers instead of icons.
/// Left as it was: it's a deliberate night mode of its own, over a darkened map.
enum SignalPalette {
    static let bg = Color(hex: 0x050505)
    static let ink = Color.white
    static let muted = Color(hex: 0x9A9A9A)
    static let lime = Color(hex: 0xD4FF3A)
    static let panel = Color(hex: 0x121212, opacity: 0.72)
}

extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// One colour by day, another after dark; follows the view's appearance.
    init(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        self.init(uiColor: Self.adaptive(day: UIColor(hex: light, alpha: lightAlpha), night: UIColor(hex: dark, alpha: darkAlpha)))
    }

    /// The provider is made here, outside the main actor, on purpose: SwiftUI resolves
    /// colours off the main thread, and a closure formed in main-actor code would carry a
    /// main-actor check and crash there.
    nonisolated private static func adaptive(day: UIColor, night: UIColor) -> UIColor {
        UIColor(dynamicProvider: provider(day: day, night: night))
    }

    nonisolated static func provider(day: UIColor, night: UIColor) -> @Sendable (UITraitCollection) -> UIColor {
        { traits in traits.userInterfaceStyle == .dark ? night : day }
    }
}

extension Font {
    static let label = Font.system(size: 11, weight: .semibold)

    /// The printed poster's headline face (and Signal's LIVE. MORE.): tall, tight and
    /// heavy, like a gig poster. Screens use the system face; see `display`.
    static func poster(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    /// The quote and the quiet lines: the system face, upright and regular (no serif,
    /// no italic anywhere).
    static func quiet(_ size: CGFloat) -> Font {
        .system(size: size)
    }
}

extension View {
    /// Page and card titles: the system face, bold and a touch tight, like a large title.
    func display(_ size: CGFloat) -> some View {
        font(.system(size: size, weight: .bold)).tracking(size >= 24 ? -0.6 : -0.2)
    }

    /// A grouped block: a white card by day, a lift of the green after dark.
    func card(radius: CGFloat = 18) -> some View { modifier(CardStyle(radius: radius)) }

    /// A short line over a section or a title, in sentence case: "Out now · 3",
    /// "Thursday · 6:45".
    func eyebrow(_ color: Color = Palette.muted) -> some View {
        self.font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
    }

    /// A floating panel over the map: the system's own glass.
    func glassPanel(radius: CGFloat = 34) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: radius))
    }
}

struct CardStyle: ViewModifier {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(Palette.card, in: .rect(cornerRadius: radius))
            .overlay {
                if scheme == .dark { RoundedRectangle(cornerRadius: radius).stroke(Palette.line) }
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 10, y: 4)
    }
}

/// LIVE. MORE. with accent full stops. On one line, or stacked for the Signal header.
/// Shrinks to fit rather than wrap.
struct LiveMoreMark: View {
    var size: CGFloat = 46
    var stacked = false
    var dot: Color = Palette.accent
    var ink: Color = Palette.ink

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: -size * 0.16) {
                    word("LIVE")
                    word("MORE")
                }
            } else {
                Text("\(Text("LIVE").foregroundStyle(ink))\(Text(".").foregroundStyle(dot)) \(Text("MORE").foregroundStyle(ink))\(Text(".").foregroundStyle(dot))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .font(.poster(size, weight: .black))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live more.")
        .accessibilityAddTraits(.isHeader)
    }

    private func word(_ w: String) -> some View {
        Text("\(Text(w).foregroundStyle(ink))\(Text(".").foregroundStyle(dot))")
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}
