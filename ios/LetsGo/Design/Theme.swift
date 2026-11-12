import SwiftUI
import UIKit

/// Neighborhood color: the app follows the phone's light and dark, the way Maps does. By
/// day, warm cream and near-black ink; after dark, a city at night: deep navy and cream
/// ink. The map is ours (`PaperMap`, drawn from our own style) and it has life in it:
/// blocks and buildings, green parks, blue water, warm main roads. On it the red-orange
/// accent marks only what's on now and what you tapped; ink is the one prominent button a
/// screen; you are the system blue dot. Chrome is the system's own Liquid Glass (tab bar,
/// toolbar buttons, sheets, the search field, the chips and the time rail); nothing here
/// draws behind it. The map's quick-decide mode (`Signal`) keeps its own black and lime.
enum Palette {
    /// The page: cream by day, navy after dark. The map's land is the same colour.
    static let bg = Color(light: 0xF2EEE6, dark: 0x121A2B)
    /// Sheets and pages that sit on the map.
    static let surface = Color(light: 0xF7F4EE, dark: 0x172134)
    /// A card on the page: white by day, a lift of the navy after dark.
    static let card = Color(light: 0xFFFFFF, dark: 0x1E2A42)
    /// Empty seats, unfilled bars, the quietest fills.
    static let raise = Color(light: 0xE6E0D4, dark: 0x2B3755)
    /// Near-black on cream, cream on navy.
    static let ink = Color(light: 0x1B1A17, dark: 0xF2F0EA)
    static let muted = Color(light: 0x6B665C, dark: 0x9AA3BC)
    /// A step stronger than `muted`, for body copy on glass.
    static let soft = Color(light: 0x45423B, dark: 0xC6CCDD)
    /// The quietest labels: the map's label colour, a step back.
    static let faint = Color(light: 0x857B6A, dark: 0x8D97B3)
    static let line = Color(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.1)
    /// The one prominent button a screen: ink, with the page's colour on it.
    static let prominent = ink
    /// Text and glyphs on `prominent`.
    static let onProminent = Color(light: 0xF2EEE6, dark: 0x121A2B)
    /// Red-orange: on the map, only what's on now and what you tapped. Elsewhere, the
    /// small marks that are ours (a seat waiting for you, a full stop).
    static let accent = Color(light: 0xD9502A, dark: 0xFF8A5B)
    /// The accent as text on the page, a step darker by day so it reads on cream.
    static let accentSoft = Color(light: 0xB8401E, dark: 0xFFA982)
    /// Paper on the accent, in both appearances.
    static let accentInk = Color(hex: 0xFFFFFF)
    static let star = Color(light: 0xD9952A, dark: 0xF2BE62)
    /// You: the system blue dot.
    static let me = Color(uiColor: .systemBlue)
    /// Kinds of things in lists.
    static let compass = Color(light: 0x2F6FD6, dark: 0x8FB4E6)
    /// A friend who's in.
    static let live = Color(light: 0x1F9D55, dark: 0x6FD49A)
    /// A porch light: someone up for something.
    static let porch = Color(light: 0xE08A12, dark: 0xFFB547)
    static let porchSoft = Color(light: 0xB86E00, dark: 0xFFC88A)
    /// A slider's thumb (the time rail's): white, a touch of cream after dark.
    static let knob = Color(light: 0xFFFFFF, dark: 0xF2F0EA)
    static let shadow = Color(light: 0x000000, lightAlpha: 0.28, dark: 0x000000, darkAlpha: 0.5)
    /// A walking route on the plan and walk screens: the accent, since it goes to what you chose.
    /// (The main map draws its own; see `PaperMap`.)
    static let walk = accent
}

/// The map's own colours, as UIKit colours for MapLibre's pins and overlays. They match
/// `Palette` and the bundled styles (`neighborhood-light.json`, `neighborhood-dark.json`).
enum MapInk {
    /// The land, under everything.
    static let paper = UIColor(light: 0xF2EEE6, dark: 0x121A2B)
    static let ink = UIColor(light: 0x1B1A17, dark: 0xF2F0EA)
    static let accent = UIColor(light: 0xD9502A, dark: 0xFF8A5B)
    /// White text on a filled pin (the accent), in both appearances.
    static let onFill = UIColor(hex: 0xFFFFFF)
    /// An event's pill: white by day, a navy lift after dark.
    static let pill = UIColor(light: 0xFFFFFF, dark: 0x1E2A42)
    static let pillText = UIColor(light: 0x1B1A17, dark: 0xF2F0EA)
    /// The short name after the time.
    static let pillName = UIColor(light: 0x6B665C, dark: 0x9AA3BC)
    /// The pill's hairline after dark, so it lifts off the navy.
    static let pillEdge = UIColor(light: 0x000000, lightAlpha: 0, dark: 0xFFFFFF, darkAlpha: 0.08)
    /// The white ring round a kitchen's photo and a friend's face.
    static let ring = UIColor(hex: 0xFFFFFF)
    /// The kitchen's price tag: black with white figures, in both appearances.
    static let tag = UIColor(hex: 0x1B1A17)
    static let onTag = UIColor(hex: 0xFFFFFF)
    /// A merged count: ink, with the land's colour on it.
    static let count = ink
    static let onCount = paper
    static let shadow = UIColor(light: 0x000000, lightAlpha: 0.2, dark: 0x000000, darkAlpha: 0.45)

    /// The dot on an event's pill, by kind. Never the red-orange: that's for now and tapped.
    static func dot(_ genre: Genre) -> UIColor {
        switch genre {
        case .play: UIColor(light: 0x2F80ED, dark: 0x6AA6FF)
        case .move: UIColor(light: 0x1FA36B, dark: 0x5FD49C)
        case .music: UIColor(light: 0x8B5CF6, dark: 0xB59BFF)
        case .party: UIColor(light: 0xE9A100, dark: 0xFFC94D)
        case .food: UIColor(light: 0xE0567A, dark: 0xFF8FB0)
        }
    }
}

extension UIColor {
    /// One colour by day, another after dark.
    convenience init(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        let day = UIColor(hex: light, alpha: lightAlpha), night = UIColor(hex: dark, alpha: darkAlpha)
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

    /// A grouped block: a white card by day, a lift of the navy after dark.
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
