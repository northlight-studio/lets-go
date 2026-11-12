import Foundation
import SwiftData
import CoreLocation
import OSLog

/// Real things happening around San Francisco: weekly regulars (run clubs, markets, trivia)
/// and dated one-offs. They come from the server's /v1/listings, kept on the phone for when
/// it's offline, and before the first fetch from `sf_happenings.json` in the app bundle.
/// Weekly ones are expanded into actual dates for the next two weeks, so the map is always current,
/// and nothing that has ended is laid out (`Upcoming`). Only San Francisco so far (`covers`).
enum CityListings {
    /// Roughly the city, from Ocean Beach to the Embarcadero, Daly City line to the Marina.
    static func covers(_ c: CLLocationCoordinate2D) -> Bool {
        (37.70...37.84).contains(c.latitude) && (-122.53 ... -122.35).contains(c.longitude)
    }

    /// SF's middle, for when you're not in the city.
    static let cityCenter = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

    static let horizonDays = 14
    private static let log = Logger(subsystem: "com.yasser100ali.letsgo", category: "listings")

    // MARK: File format

    struct Listing: Decodable, Sendable {
        var title: String
        var genre: String
        var venue: String
        var address: String
        var lat: Double
        var lon: Double
        var schedule: [Slot]
        var price: String
        var organizer: String
        var url: String
        var description: String

        enum CodingKeys: String, CodingKey {
            case title, genre, venue, address, lat, lon, schedule, price, organizer, url, description
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            genre = try c.decode(String.self, forKey: .genre)
            venue = try c.decode(String.self, forKey: .venue)
            address = (try? c.decode(String.self, forKey: .address)) ?? ""
            lat = try c.decode(Double.self, forKey: .lat)
            lon = try c.decode(Double.self, forKey: .lon)
            // One slot or a list of them.
            if let many = try? c.decode([Slot].self, forKey: .schedule) {
                schedule = many
            } else {
                schedule = [try c.decode(Slot.self, forKey: .schedule)]
            }
            price = (try? c.decode(String.self, forKey: .price)) ?? ""
            organizer = (try? c.decode(String.self, forKey: .organizer)) ?? ""
            url = (try? c.decode(String.self, forKey: .url)) ?? ""
            description = (try? c.decode(String.self, forKey: .description)) ?? ""
        }
    }

    /// Either {"weekday": "Saturday", "start": "08:00", "end": "13:00"}
    /// or {"date": "2026-10-24", "start": "18:00", "end": "22:00"}.
    /// A missing end (a run's start time, a trivia night) gets a typical length for its kind.
    struct Slot: Decodable, Sendable {
        var weekday: String?
        var date: String?
        var start: String
        var end: String?
    }

    /// How long something usually lasts when the listing only gives a start, in minutes.
    static func typicalLength(_ genre: Genre) -> Int {
        switch genre {
        case .move: 75
        case .play: 120
        case .music: 150
        case .party: 120
        case .food: 180
        }
    }

    struct Occurrence: Sendable, Equatable {
        var key: String
        var start: Date
        var end: Date
        var recurring: String
    }

    // MARK: Loading

    /// The server's latest copy, kept for when the phone is offline.
    static var cacheURL: URL { URL.cachesDirectory.appending(path: "sf_listings.json") }

    /// What's current: the server's last copy if there is one, plus anything in the file the app
    /// shipped with that the server doesn't have yet. Before the first fetch, just the file.
    static func current() -> [Listing] {
        let shipped = bundled()
        if let data = try? Data(contentsOf: cacheURL), let cached = try? decode(data), !cached.isEmpty {
            return merge(server: cached, bundled: shipped)
        }
        return shipped
    }

    /// The server's listings first; a bundled one is added only when the server has nothing
    /// with the same title at the same venue. New listings ship in the app before the
    /// server's import runs, and this keeps them from being hidden by an older server copy.
    static func merge(server: [Listing], bundled: [Listing]) -> [Listing] {
        let known = Set(server.map(identity))
        return server + bundled.filter { !known.contains(identity($0)) }
    }

    static func identity(_ l: Listing) -> String {
        "\(l.title.trimmingCharacters(in: .whitespaces).lowercased())|\(l.venue.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    /// Fetches the city's listings and keeps them for offline. A failure, or an empty answer from a
    /// server nobody has loaded yet, leaves what's there. True when a new copy came in.
    @discardableResult
    static func update() async -> Bool {
        guard APIConfig.isConfigured else { return false }
        do {
            let response = try await APIClient.shared.send(
                Endpoint<ListingsDTO>.get("/v1/listings", query: [URLQueryItem(name: "city", value: "sf")])
            )
            guard !response.listings.isEmpty else { return false }
            try JSONEncoder().encode(response.listings).write(to: cacheURL, options: .atomic)
            log.info("Listings from the server: \(response.listings.count)")
            return true
        } catch {
            log.error("Fetching listings failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func bundled() -> [Listing] {
        guard let url = Bundle.main.url(forResource: "sf_happenings", withExtension: "json") else {
            log.error("sf_happenings.json missing from the bundle")
            return []
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            log.error("sf_happenings.json didn't decode: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    static func decode(_ data: Data) throws -> [Listing] {
        // Skip any single bad entry instead of losing the whole file.
        struct Lenient: Decodable {
            var listing: Listing?
            init(from decoder: Decoder) throws { listing = try? Listing(from: decoder) }
        }
        return try JSONDecoder().decode([Lenient].self, from: data).compactMap(\.listing)
    }

    /// Every time a listing happens between now and the horizon, still ongoing or ahead.
    static func occurrences(of l: Listing, from now: Date, days: Int = horizonDays, calendar: Calendar = .current) -> [Occurrence] {
        var out: [Occurrence] = []
        let today = calendar.startOfDay(for: now)
        let genre = Genre(rawValue: l.genre) ?? .party
        for slot in l.schedule {
            guard let start = minutes(slot.start) else { continue }
            let end = slot.end.flatMap(minutes) ?? (start + typicalLength(genre)) % (24 * 60)
            var candidates: [Date] = []
            if let iso = slot.date, let d = dayFormatter.date(from: iso) {
                candidates = [d]
            } else if let name = slot.weekday?.lowercased(), let weekday = weekdays[name] {
                // From yesterday (something that started last night may still be on) to the horizon.
                candidates = (-1..<days).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
                    .filter { calendar.component(.weekday, from: $0) == weekday }
            }
            for day in candidates {
                guard let s = calendar.date(byAdding: .minute, value: start, to: calendar.startOfDay(for: day)) else { continue }
                // An end before the start means it runs past midnight.
                let length = end > start ? end - start : end + 24 * 60 - start
                let e = s.addingTimeInterval(TimeInterval(length * 60))
                guard Upcoming.isShown(end: e, now: now) else { continue }
                // One-offs further out than two months aren't worth a pin yet.
                if slot.date != nil && s > now.addingTimeInterval(60 * 86_400) { continue }
                out.append(Occurrence(
                    key: "\(l.title)|\(Int(s.timeIntervalSince1970))",
                    start: s, end: e,
                    recurring: slot.weekday.map { "Every \($0.capitalized)" } ?? ""
                ))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Replaces listed happenings with the current set. What has ended leaves (`Upcoming`); anything you
    /// joined or showed up to stays in the store for your history, off the map.
    static func refresh(context: ModelContext, now: Date = .now) {
        let listings = current()
        var existing: [String: Gathering] = [:]
        do {
            for g in try context.fetch(FetchDescriptor<Gathering>(predicate: #Predicate { $0.listingKey != nil })) {
                if let key = g.listingKey { existing[key] = g }
            }
        } catch {
            log.error("Fetching listings failed: \(error.localizedDescription, privacy: .public)")
        }
        var keep = Set<String>()
        for l in listings {
            let genre = Genre(rawValue: l.genre) ?? .party
            for o in occurrences(of: l, from: now) {
                keep.insert(o.key)
                let g = existing[o.key] ?? {
                    let new = Gathering(
                        title: l.title, category: genre, placeName: l.venue,
                        coordinate: .init(latitude: l.lat, longitude: l.lon),
                        start: o.start, end: o.end, hostName: l.organizer
                    )
                    new.listingKey = o.key
                    context.insert(new)
                    return new
                }()
                // Two listings can share a title at the same time; keep one pin for both.
                existing[o.key] = g
                g.categoryRaw = genre.rawValue
                g.details = l.description
                g.placeName = l.venue
                g.address = l.address
                g.latitude = l.lat
                g.longitude = l.lon
                g.hostName = l.organizer
                g.recurring = o.recurring
                g.priceText = l.price
                g.sourceURL = l.url.isEmpty ? nil : l.url
            }
        }
        for (key, g) in existing where !keep.contains(key) && g.checkedInAt == nil && !g.isJoined {
            context.delete(g)
        }
        Ledger.save(context, "refresh listings")
        log.info("Listings: \(listings.count) in the file, \(keep.count) upcoming")
    }

    // MARK: Parsing

    private static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "18:30" → 1110.
    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
