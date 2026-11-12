import Foundation
import SwiftData
import CoreLocation

/// A home kitchen: someone's house turned into a tiny restaurant for a night.
@Model
final class Kitchen {
    var id: UUID
    var name: String
    var cookName: String
    var cuisine: String
    var story: String
    var latitude: Double
    var longitude: Double
    /// Shown only after you've reserved: "Side gate, ring the bell".
    var pickupNote: String
    var porchTables: Int
    /// Ratings carried over from before this device knew the kitchen (the server's).
    var baseRatingTotal: Double
    var baseReviewCount: Int
    var regulars: Int
    var permitConfirmed: Bool
    var handlerCardConfirmed: Bool
    var isMine: Bool
    /// Only `SamplePurge` reads this (see `Person.isSample`).
    var isSample: Bool
    /// The server's reviews, as shown text. Already counted in the base rating. (The name is from
    /// when sample kitchens had them; it's kept so the store opens without a migration.)
    var sampleReviews: [SampleReview] = []
    /// The backend's id.
    var remoteID: UUID?
    /// The shared porch table at the next drop, from the server: seats, porch orders, friends at it.
    var tableSeats: Int = 0
    var tableTaken: Int = 0
    var tableFriends: [TableSeat] = []

    @Relationship(deleteRule: .cascade, inverse: \MenuItem.kitchen) var menu: [MenuItem] = []
    @Relationship(deleteRule: .cascade, inverse: \Drop.kitchen) var drops: [Drop] = []
    @Relationship(deleteRule: .cascade, inverse: \Review.kitchen) var reviews: [Review] = []
    @Relationship(deleteRule: .cascade, inverse: \Order.kitchen) var orders: [Order] = []

    init(
        name: String, cookName: String, cuisine: String, story: String,
        coordinate: CLLocationCoordinate2D, pickupNote: String, porchTables: Int = 0,
        rating: Double = 0, reviewCount: Int = 0, regulars: Int = 0,
        isMine: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.cookName = cookName
        self.cuisine = cuisine
        self.story = story
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.pickupNote = pickupNote
        self.porchTables = porchTables
        self.baseRatingTotal = rating * Double(reviewCount)
        self.baseReviewCount = reviewCount
        self.regulars = regulars
        self.permitConfirmed = false
        self.handlerCardConfirmed = false
        self.isMine = isMine
        self.isSample = false
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    var reviewCount: Int { baseReviewCount + reviews.count }

    var rating: Double? {
        let count = reviewCount
        guard count > 0 else { return nil }
        let total = baseRatingTotal + reviews.reduce(0) { $0 + Double($1.stars) }
        return total / Double(count)
    }

    var sortedMenu: [MenuItem] { menu.sorted { $0.sortIndex < $1.sortIndex } }

    /// The drop that's on now, or the next one coming.
    func nextDrop(after now: Date) -> Drop? {
        drops.filter { $0.end > now }.min { $0.start < $1.start }
    }

    var isReady: Bool { permitConfirmed && handlerCardConfirmed && !menu.isEmpty }
}

@Model
final class MenuItem {
    var id: UUID
    var name: String
    var note: String
    var priceCents: Int
    var sortIndex: Int
    var kitchen: Kitchen?
    var remoteID: UUID?

    init(name: String, note: String = "", priceCents: Int, sortIndex: Int) {
        self.id = UUID()
        self.name = name
        self.note = note
        self.priceCents = priceCents
        self.sortIndex = sortIndex
    }
}

/// A fixed batch at a set time. The reason to come now instead of whenever.
@Model
final class Drop {
    var id: UUID
    var start: Date
    var end: Date
    var total: Int
    var sold: Int
    /// How many orders the cook can hand out per 15-minute pickup slot.
    var perSlot: Int
    var kitchen: Kitchen?
    var remoteID: UUID?
    /// The cook's photo of this drop, from the server (`photo_url`), when there is one.
    var photoURL: String?

    init(start: Date, end: Date, total: Int, sold: Int = 0, perSlot: Int = 4) {
        self.id = UUID()
        self.start = start
        self.end = end
        self.total = total
        self.sold = sold
        self.perSlot = perSlot
    }

    var left: Int { max(0, total - sold) }
    var isSoldOut: Bool { left == 0 }
    func isLive(at now: Date) -> Bool { start <= now && now < end }

    /// Pickup times in 15-minute steps across the drop window.
    var slots: [Date] {
        var out: [Date] = []
        var t = start
        while t < end {
            out.append(t)
            t = t.addingTimeInterval(15 * 60)
        }
        return out
    }
}

struct SampleReview: Codable, Hashable, Sendable {
    var stars: Int
    var text: String
    var author: String
    var daysAgo: Int
}

struct OrderLine: Codable, Hashable, Sendable {
    var name: String
    var priceCents: Int
    var quantity: Int
}

@Model
final class Order {
    enum Status: String, Codable { case reserved, pickedUp, reviewed }

    var id: UUID
    var createdAt: Date
    var pickupAt: Date
    var lines: [OrderLine]
    var eatOnPorch: Bool
    var statusRaw: String
    var kitchen: Kitchen?
    var remoteID: UUID?

    init(pickupAt: Date, lines: [OrderLine], eatOnPorch: Bool) {
        self.id = UUID()
        self.createdAt = .now
        self.pickupAt = pickupAt
        self.lines = lines
        self.eatOnPorch = eatOnPorch
        self.statusRaw = Status.reserved.rawValue
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .reserved }
        set { statusRaw = newValue.rawValue }
    }

    var itemCount: Int { lines.reduce(0) { $0 + $1.quantity } }
    var subtotalCents: Int { lines.reduce(0) { $0 + $1.priceCents * $1.quantity } }
    var serviceCents: Int { Pricing.serviceFee(for: subtotalCents) }
    var totalCents: Int { subtotalCents + serviceCents }
}

@Model
final class Review {
    var id: UUID
    var stars: Int
    var tags: [String]
    var text: String
    var author: String
    var createdAt: Date
    var isMine: Bool
    var kitchen: Kitchen?

    init(stars: Int, tags: [String] = [], text: String, author: String, createdAt: Date = .now, isMine: Bool = false) {
        self.id = UUID()
        self.stars = stars
        self.tags = tags
        self.text = text
        self.author = author
        self.createdAt = createdAt
        self.isMine = isMine
    }
}

nonisolated enum Pricing {
    /// 5%, at least 50¢. What the app keeps; the cook gets the subtotal.
    static func serviceFee(for subtotalCents: Int) -> Int {
        guard subtotalCents > 0 else { return 0 }
        return max(50, Int((Double(subtotalCents) * 0.05).rounded()))
    }

    static func format(_ cents: Int) -> String {
        let dollars = Double(cents) / 100
        return cents % 100 == 0
            ? "$\(cents / 100)"
            : dollars.formatted(.currency(code: "USD"))
    }
}
