import Foundation
import CoreLocation

/// Turns what's in the database into what the map and search reason about.
enum Nearby {
    static func candidates(
        gatherings: [Gathering], kitchens: [Kitchen],
        from here: CLLocationCoordinate2D, now: Date
    ) -> [Candidate] {
        let g = gatherings.filter { $0.isShown(at: now) }.map { Candidate($0, from: here) }
        let k = kitchens.compactMap { Candidate($0, from: here, now: now) }
        return g + k
    }

    static func taste(notes: [TasteNote], gatherings: [Gathering], kitchens: [Kitchen]) -> Taste {
        let joined = gatherings.filter { $0.isJoined || $0.checkedInAt != nil }.map(\.category)
        let ordered = kitchens.reduce(0) { $0 + $1.orders.count }
        return Taste.from(notes: notes, joined: joined, ordered: ordered)
    }
}
