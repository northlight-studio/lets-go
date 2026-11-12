import Foundation
import CoreLocation

/// One thing worth showing: a gathering, or a kitchen's drop.
/// A plain value so the scoring can be tested without a database.
struct Candidate: Identifiable, Hashable, Sendable {
    /// A gathering, a kitchen's drop, or a supper at a neighbor's (`SupperDTO`).
    enum Kind: Hashable, Sendable { case gathering, drop, supper }

    var id: UUID
    var kind: Kind
    var title: String
    var category: Genre
    var start: Date
    var end: Date
    var meters: Double
    var capacity: Int = 0
    var going: Int = 0
    var dropLeft: Int?
    var dropTotal: Int?
    var priceFromCents: Int?
    var isJoined: Bool = false
    /// Where it is, in words: "Lafayette Park", or a kitchen's cuisine.
    var place: String = ""
    /// Everything search looks through, lowercased.
    var searchText: String = ""

    var spotsLeft: Int? { capacity > 0 ? max(0, capacity - going) : nil }
    var walkMinutes: Int { Walk.minutes(meters) }
    var priceText: String = ""
    var lat: Double = 0
    var lon: Double = 0
    /// Friends the server says are going (`Person.id`s).
    var friendIDs: [UUID] = []
    /// A kitchen's drop photo, when the cook has posted one.
    var photoURL: URL?
    /// A kitchen's dish, for its pin until there's a photo: "🍕".
    var glyph: String = ""
    var isFree: Bool { kind == .gathering && (priceText.isEmpty || priceText.lowercased().hasPrefix("free")) }
}

extension Candidate {
    init(_ g: Gathering, from here: CLLocationCoordinate2D) {
        self.init(
            id: g.id, kind: .gathering, title: g.title, category: g.category,
            start: g.start, end: g.end, meters: here.distance(to: g.coordinate),
            capacity: g.capacity, going: g.going, isJoined: g.isJoined,
            place: g.placeName,
            searchText: [g.title, g.details, g.placeName, g.address, g.hostName, g.bring, g.priceText, g.category.label, g.category.noun]
                .joined(separator: " ").lowercased(),
            priceText: g.priceText, lat: g.latitude, lon: g.longitude, friendIDs: g.friendIDs
        )
    }

    init?(_ k: Kitchen, from here: CLLocationCoordinate2D, now: Date) {
        guard let drop = k.nextDrop(after: now) else { return nil }
        // A batch ("Sell something") is one thing: its title, its price, and the kitchen as the place.
        self.init(
            id: k.id, kind: .drop, title: drop.isBatch ? drop.title : k.name, category: .food,
            start: drop.start, end: drop.end, meters: here.distance(to: k.coordinate),
            dropLeft: drop.left, dropTotal: drop.total,
            priceFromCents: drop.isBatch ? drop.priceCents : k.menu.map(\.priceCents).min(),
            place: drop.isBatch ? k.name : k.cuisine,
            searchText: ([drop.title, k.name, k.cookName, k.cuisine, k.story, "food home cooking kitchen"] + drop.tags + k.menu.map { "\($0.name) \($0.note)" })
                .joined(separator: " ").lowercased(),
            lat: k.latitude, lon: k.longitude,
            // The server sends it relative to itself ("/v1/photos/…").
            photoURL: APIConfig.resolve(drop.photoURL),
            glyph: KitchenLook.glyph(for: drop.isBatch ? drop.title : k.cuisine)
        )
    }
}

/// How much you seem to like each kind of thing, 0...1, learned from what you
/// joined, showed up to and ordered, minus anything you deleted from your interests.
struct Taste: Sendable {
    var weights: [Genre: Double] = [:]

    func weight(_ c: Genre) -> Double { weights[c] ?? 0 }

    static func from(notes: [TasteNote], joined: [Genre], ordered: Int) -> Taste {
        var raw: [Genre: Double] = [:]
        for c in joined { raw[c, default: 0] += 1 }
        raw[.food, default: 0] += Double(ordered)
        for n in notes where !n.isHidden {
            if let c = n.category { raw[c, default: 0] += 0.5 }
        }
        // A category you've hidden every note for drops to zero.
        let hidden = Set(notes.filter(\.isHidden).compactMap(\.category))
        let visible = Set(notes.filter { !$0.isHidden }.compactMap(\.category))
        for c in hidden.subtracting(visible) { raw[c] = 0 }
        let top = raw.values.max() ?? 0
        guard top > 0 else { return Taste() }
        return Taste(weights: raw.mapValues { $0 / top })
    }
}

/// Ranks what's nearby: soon, close, filling up, and the kinds of things you show up for.
enum Picks {
    /// How far ahead the map counts as "now".
    static let horizon: TimeInterval = 3 * 3600

    /// Higher is better. Zero means don't suggest it.
    static func score(_ c: Candidate, now: Date, taste: Taste) -> Double {
        if c.end <= now { return 0 }
        if c.spotsLeft == 0 || c.dropLeft == 0 { return 0 }
        let until = c.start.timeIntervalSince(now)
        if until > horizon { return 0 }

        // Soon beats later; something already on is as good as starting now.
        let timeScore = until <= 0 ? 0.9 : 1 - until / horizon
        // Twenty minutes' walk is the edge of interesting.
        let walkScore = max(0, 1 - Double(c.walkMinutes) / 20)
        var urgency = 0.0
        if let spots = c.spotsLeft, spots <= 2 { urgency += 0.35 }
        if let left = c.dropLeft, let total = c.dropTotal, total > 0, Double(left) / Double(total) < 0.5 { urgency += 0.25 }
        if c.isJoined { urgency += 0.4 }
        let tasteScore = taste.weight(c.category) * 0.5
        return timeScore * 0.9 + walkScore * 1.1 + urgency + tasteScore
    }

    static func picks(_ candidates: [Candidate], now: Date, taste: Taste, limit: Int = 3) -> [Candidate] {
        candidates
            .map { ($0, score($0, now: now, taste: taste)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// The short reason under a pick: "2 spots left · 6 min walk".
    static func reason(_ c: Candidate, now: Date) -> String {
        var parts: [String] = []
        if let spots = c.spotsLeft {
            parts.append(spots == 1 ? "needs 1 more" : spots <= 3 ? "needs \(spots)" : "\(c.going) going")
        } else if let left = c.dropLeft {
            parts.append("\(left) left")
        } else if c.going > 0 {
            parts.append("\(c.going) going")
        }
        if let price = c.priceFromCents { parts.append("from \(Pricing.format(price))") }
        else if !c.priceText.isEmpty { parts.append(c.priceText) }
        parts.append(Walk.label(c.meters))
        return parts.joined(separator: " · ")
    }
}

extension String {
    /// "Pickup soccer" → "pickup soccer", but leaves names like "Dana's" alone.
    var lowercasedFirst: String {
        guard let first = first, first.isUppercase else { return self }
        let firstWord = prefix { $0 != " " }
        if firstWord.contains("'") { return self }
        return first.lowercased() + dropFirst()
    }
}
