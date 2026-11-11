import SwiftUI

/// What kind of thing a gathering is. Food drops are always `.food`.
enum Genre: String, CaseIterable, Codable, Identifiable, Sendable {
    case play, move, music, party, food

    var id: String { rawValue }

    var label: String {
        switch self {
        case .play: "Play"
        case .move: "Move"
        case .music: "Music"
        case .party: "Hang"
        case .food: "Food"
        }
    }

    /// The chip on the map: "Sports", "Runs".
    var plural: String {
        switch self {
        case .play: "Sports"
        case .move: "Runs"
        case .music: "Music"
        case .party: "Hangs"
        case .food: "Food"
        }
    }

    /// How the app talks about it: "you're into pickup games".
    var noun: String {
        switch self {
        case .play: "pickup games"
        case .move: "runs and walks"
        case .music: "live music"
        case .party: "hangs and game nights"
        case .food: "home cooking"
        }
    }

    var symbol: String {
        switch self {
        case .play: "soccerball"
        case .move: "figure.run"
        case .music: "music.note"
        case .party: "dice.fill"
        case .food: "fork.knife"
        }
    }

    /// The pin's colour: orange for music, green for food, the compass's blue for the rest.
    var color: Color {
        switch self {
        case .music: Color(light: 0xF07A45, dark: 0xF07A45)
        case .food: Color(light: 0x3FA36B, dark: 0x6FD49A)
        case .play, .move, .party: Palette.compass
        }
    }

    /// The glyph on top of `color`: white by day, near-black after dark.
    var ink: Color { Color(light: 0xFFFFFF, dark: 0x11140F) }

    /// The kind's colour as text on the page: "4/6", "16 left".
    var light: Color {
        switch self {
        case .music: Color(light: 0xB24A18, dark: 0xFFB08A)
        case .food: Color(light: 0x1E7A47, dark: 0xA8EBC4)
        case .play, .move, .party: Color(light: 0x2457A8, dark: 0xBBD3F5)
        }
    }

    /// Words that point at this category, for search.
    var keywords: [String] {
        switch self {
        case .play: ["soccer", "football", "basketball", "hoops", "pickup", "volleyball", "tennis", "frisbee", "game", "sport", "play"]
        case .move: ["run", "jog", "walk", "hike", "bike", "ride", "yoga", "5k", "workout", "move"]
        case .music: ["music", "dj", "band", "jam", "set", "concert", "open mic", "sing", "jazz", "symphony"]
        case .party: ["party", "hang", "board game", "game night", "trivia", "drinks", "chill", "bbq", "cookout", "comedy", "stand-up", "standup", "improv"]
        case .food: ["food", "eat", "pizza", "ice cream", "tacos", "tamales", "curry", "dinner", "lunch", "dessert", "hungry", "bake"]
        }
    }
}
