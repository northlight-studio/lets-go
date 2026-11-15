import Foundation

/// Wren's three for right now: `Picks`' ranking (soon, close, filling up) with how well each
/// thing fits you folded in. The fit comes from the server, which reads your taste notes and what
/// you've gone to against each thing's title and place; without it this is exactly `Picks`.
///
/// A fit only ever lifts something `Picks` would already consider. What has ended, is full, is
/// more than three hours off or scores nothing on the clock and the walk is never picked, however
/// well it fits.
enum RightNow {
    /// How many things are sent to be scored: the best by the clock and the walk.
    static let asked = 40
    /// What a perfect fit is worth, beside `Picks`' own terms (a thing starting now is about 0.9,
    /// one next door about 1.1).
    static let fitWeight = 1.2

    /// What's worth scoring: everything `Picks` would consider, best first.
    static func eligible(_ candidates: [Candidate], now: Date, taste: Taste) -> [Candidate] {
        Picks.picks(candidates, now: now, taste: taste, limit: asked)
    }

    static func score(_ c: Candidate, now: Date, taste: Taste, fits: [UUID: Double]) -> Double {
        let base = Picks.score(c, now: now, taste: taste)
        guard base > 0 else { return 0 }
        return base + (fits[c.id] ?? 0) * fitWeight
    }

    static func picks(_ candidates: [Candidate], now: Date, taste: Taste, fits: [UUID: Double], limit: Int = 3) -> [Candidate] {
        candidates
            .map { ($0, score($0, now: now, taste: taste, fits: fits)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// What the server is sent. `notes` are the taste notes you can see; `wentTo` the titles of
    /// what you joined, newest first.
    static func body(for things: [Candidate], localTime: String, notes: [String], wentTo: [String]) -> RightNowBody {
        RightNowBody(
            localTime: localTime,
            taste: Array(notes.prefix(30)),
            wentTo: Array(wentTo.prefix(20)),
            things: things.prefix(asked).map(thing)
        )
    }

    static func thing(_ c: Candidate) -> RightNowThingDTO {
        let kind = switch c.kind {
        case .gathering: "gathering"
        case .drop: "drop"
        case .supper: "supper"
        }
        var price = c.priceText
        if price.isEmpty, let cents = c.priceFromCents {
            price = cents % 100 == 0 ? "$\(cents / 100)" : String(format: "$%.2f", Double(cents) / 100)
        }
        return RightNowThingDTO(
            key: c.id.uuidString,
            title: String(c.title.prefix(160)),
            kind: kind,
            genre: c.category.rawValue,
            place: String(c.place.prefix(120)),
            price: String(price.prefix(60))
        )
    }

    /// "Saturday 7:40 PM", in the phone's own zone.
    static func localTime(_ now: Date, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(locale: Locale(identifier: "en_US"), timeZone: timeZone)
        style = style.weekday(.wide).hour(.defaultDigits(amPM: .abbreviated)).minute()
        return now.formatted(style)
    }

    /// The fits by candidate id, from what the server sent back.
    static func fits(from dto: RightNowDTO) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for f in dto.fits {
            if let id = UUID(uuidString: f.key) { out[id] = min(1, max(0, f.fit)) }
        }
        return out
    }
}
