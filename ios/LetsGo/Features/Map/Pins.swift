import Foundation
import CoreLocation

/// What each pin on the map says and how much room it takes, worked out in plain code so
/// it's tested (`PinsTests`). Food from home kitchens is a round photo with a price tag
/// ("$6"); events are pills with a dot by kind, the time and a short name ("7:30 Jazz in
/// the park", or "Now"); friends are their initials with a speech bubble when they're up
/// for something ("walk?"). Pins that would overlap merge into a count (`Timetable.merge`).
enum Pins {
    // MARK: Events

    /// The longest name a pill carries before it's cut at a word.
    static let nameLimit = 18

    /// "Jazz in the park" stays; "Thursday night jazz at the Royal Cuckoo" becomes
    /// "Thursday night…". Cut at the last whole word that fits, never mid-word unless
    /// the first word alone is too long.
    static func shortName(_ title: String, limit: Int = nameLimit) -> String {
        let t = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard t.count > limit else { return t }
        var out = ""
        for word in t.split(separator: " ") {
            let next = out.isEmpty ? String(word) : out + " " + word
            if next.count > limit - 1 { break }
            out = next
        }
        if out.isEmpty { out = String(t.prefix(limit - 1)) }
        // No dangling joiners before the ellipsis: "Jazz &…" reads as a mistake.
        while let last = out.split(separator: " ").last, ["&", "-", "·", "at", "and", "in", "of", "the", "with", "+"].contains(last.lowercased()),
              out.contains(" ") {
            out = String(out.dropLast(last.count + 1))
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ,:;-–—·"))
        return out + "…"
    }

    /// A pill's time: "Now" for what's on, otherwise its start ("7:30").
    static func time(_ c: Candidate, now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        Timetable.tag(c, now: now, calendar: calendar, locale: locale)
    }

    // MARK: Food

    /// The black tag under a kitchen's photo: its cheapest dish, "$6" or "$6.50".
    static func priceTag(cents: Int?) -> String? {
        guard let cents, cents > 0 else { return nil }
        return Pricing.format(cents)
    }

    /// The tag under a photo pin: a batch's price ("$6"), or a supper's seats left ("2 seats").
    static func tag(_ c: Candidate) -> String? {
        switch c.kind {
        case .drop: priceTag(cents: c.priceFromCents)
        case .supper: SupperCopy.seatsTag(left: c.spotsLeft ?? 0)
        case .gathering: nil
        }
    }

    // MARK: Friends

    /// "Maya Chen" → "MC", "Theo" → "T", "" → "?".
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).filter { $0.first?.isLetter ?? false }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// A friend on the map: where they are and what their bubble says.
    struct FriendPin: Identifiable, Hashable, Sendable {
        var id: UUID
        var name: String
        var initials: String
        var latitude: Double
        var longitude: Double
        /// "walk?": they're up for something. Nil when their porch light is off.
        var bubble: String?
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    /// The longest bubble before it's cut.
    static let bubbleLimit = 14

    /// What a friend's bubble says while their porch light is on: their note, short
    /// ("walk?", "tacos?"), or "up for it?" when they didn't write one.
    static func bubble(_ f: Friend, now: Date) -> String? {
        guard f.porchOn(at: now) else { return nil }
        // Up for one of the chips (`up_for` on the people DTO): its own short word.
        if UpFor.activity(f.upActivity) != nil { return UpFor.bubble(activity: f.upActivity, words: "") }
        let note = f.porchNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return "up for it?" }
        return shortName(note, limit: bubbleLimit)
    }

    /// Friends who can be put on the map: where they checked in tonight, or where their
    /// porch light is while it's on. Nobody else, and never a guess.
    static func friends(_ all: [Friend], now: Date) -> [FriendPin] {
        all.compactMap { f in
            let place: (Double, Double)?
            if let out = f.out, out.state == .there, let lat = out.latitude, let lon = out.longitude {
                place = (lat, lon)
            } else if f.porchOn(at: now), let lat = f.latitude, let lon = f.longitude {
                place = (lat, lon)
            } else {
                place = nil
            }
            guard let place else { return nil }
            return FriendPin(
                id: f.id, name: f.name, initials: initials(f.name),
                latitude: place.0, longitude: place.1, bubble: bubble(f, now: now)
            )
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: Room on screen

    /// How much of the screen a pin takes, in points, with a little air around it. A pill
    /// grows with its name; a kitchen is its photo and price tag.
    static func footprint(_ c: Candidate, now: Date) -> (width: Double, height: Double) {
        switch c.kind {
        case .drop, .supper:
            return (48, 56)
        case .gathering:
            let time = Double(Timetable.tag(c, now: now).count) * 7.4
            let name = Double(shortName(c.title).count) * 6.6
            return (min(170, 34 + time + name), 30)
        }
    }

    /// Whether two pins at these screen points would overlap.
    static func overlap(
        _ a: (x: Double, y: Double), _ fa: (width: Double, height: Double),
        _ b: (x: Double, y: Double), _ fb: (width: Double, height: Double)
    ) -> Bool {
        abs(a.x - b.x) < (fa.width + fb.width) / 2 && abs(a.y - b.y) < (fa.height + fb.height) / 2
    }
}

/// The chips under the search field: everything, or only one kind of pin.
enum MapLayer: String, CaseIterable, Identifiable, Sendable {
    case all, food, events, friends

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .food: "Food"
        case .events: "Events"
        case .friends: "Friends"
        }
    }

    /// Whether a thing is on the map with this chip on. Friends shows what friends are
    /// going to (`goingIDs`) as well as the friends themselves.
    func keeps(_ c: Candidate, goingIDs: Set<UUID> = []) -> Bool {
        switch self {
        case .all: true
        case .food: c.kind == .drop || c.kind == .supper
        case .events: c.kind == .gathering
        case .friends: goingIDs.contains(c.id)
        }
    }

    /// Whether friends' own pins are drawn.
    var showsFriends: Bool { self == .all || self == .friends }
}
