import SwiftUI
import UIKit

/// Daylight map: the app follows the phone's light and dark, the way Maps does (iOS's
/// Automatic appearance turns dark at sunset). By day, paper surfaces, green-black ink
/// and white cards; after dark, deep trail green with glass over the map. The colours
/// come from the compass icon and the map: yellow for the one thing to press (and the
/// walk ring and route), blue for most pins, orange for music, green for food, and the
/// system blue dot for you. Chrome is the system's own Liquid Glass (tab bar, toolbar
/// buttons, sheets, search); nothing here draws behind it. The map's quick-decide mode
/// (`Signal`) keeps its own black and lime.
enum Palette {
    /// The page: paper by day, trail green after dark.
    static let bg = Color(light: 0xEFEDE6, dark: 0x0C1D15)
    /// Sheets and pages that sit on the map.
    static let surface = Color(light: 0xF6F4EE, dark: 0x10241A)
    /// A card on the page: white by day, a lift of the green after dark.
    static let card = Color(light: 0xFFFFFF, dark: 0x173025)
    /// Empty seats, unfilled bars, the quietest fills.
    static let raise = Color(light: 0xE2DFD6, dark: 0x22392D)
    static let ink = Color(light: 0x1B231E, dark: 0xF3F0E4)
    static let muted = Color(light: 0x5F6A62, dark: 0xA7B5AA)
    /// A step stronger than `muted`, for body copy on glass.
    static let soft = Color(light: 0x3E4942, dark: 0xCAD4CB)
    /// Street names and the quietest labels.
    static let faint = Color(light: 0x7C867F, dark: 0x7F9A8A)
    static let line = Color(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.1)
    /// The compass's yellow: the one prominent button a screen, the selected chip, the
    /// walk ring, the route, Wren.
    static let accent = Color(light: 0xF2A516, dark: 0xF5B82E)
    /// Yellow as text or a glyph on the page (plain yellow is too light to read on paper).
    static let accentSoft = Color(light: 0x9A6200, dark: 0xF7C85A)
    /// Dark ink on yellow, in both appearances.
    static let accentInk = Color(hex: 0x1C1404)
    static let star = Color(light: 0xE09A10, dark: 0xFFC766)
    /// You: the system blue dot.
    static let me = Color(uiColor: .systemBlue)
    /// The compass's blue: most pins.
    static let compass = Color(light: 0x2F6FD6, dark: 0x8FB4E6)
    /// "On now", and a friend who's in.
    static let live = Color(light: 0x1F9D55, dark: 0x6FD49A)
    /// A porch light: someone up for something.
    static let porch = Color(light: 0xE08A12, dark: 0xFFB547)
    static let porchSoft = Color(light: 0xB86E00, dark: 0xFFC88A)
    /// The walk ring and route lines: the accent.
    static let walk = accent
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
        // Built out here: the provider runs off the main actor.
        let day = UIColor(hex: light, alpha: lightAlpha)
        let night = UIColor(hex: dark, alpha: darkAlpha)
        self.init(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? night : day })
    }
}

extension Font {
    static let label = Font.system(size: 11, weight: .semibold)

    /// The printed poster's headline face (and Signal's LIVE. MORE.): tall, tight and
    /// heavy, like a gig poster. Screens use the system face; see `display`.
    static func poster(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    /// The quote and the quiet lines: the system serif.
    static func serif(_ size: CGFloat) -> Font {
        .system(size: size, design: .serif)
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

/// LIVE. MORE. with yellow full stops. On one line, or stacked for the Signal header.
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
