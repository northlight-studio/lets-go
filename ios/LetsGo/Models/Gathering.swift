import Foundation
import SwiftData
import CoreLocation

/// Anything people show up for: a pickup game, a run, a backyard set.
@Model
final class Gathering {
    var id: UUID
    var title: String
    var categoryRaw: String
    var details: String
    var placeName: String
    var latitude: Double
    var longitude: Double
    var start: Date
    var end: Date
    /// 0 means open, no cap.
    var capacity: Int
    /// People going, not counting you.
    var othersGoing: Int
    var hostName: String
    var bring: String
    var recurring: String
    var isJoined: Bool
    var checkedInAt: Date?
    var isMine: Bool
    var isSample: Bool
    /// The backend's id, for things that came from (or were posted to) the server.
    var remoteID: UUID?
    /// Set for real-world happenings listed by the app (a farmers market, a run club),
    /// as "title|start", so a refresh keeps your join and check-in.
    var listingKey: String?
    var sourceURL: String?
    var priceText: String = ""
    var address: String = ""
    /// Friends who are going, from the server (`Person.id`s, which for real friends are their server ids).
    var friendIDs: [UUID] = []
    /// The friend who asked you along, if one did.
    var invitedBy: String = ""
    /// First names of people who said they're in from your poster's web page. The server only sends
    /// them to the host; they're counted in `othersGoing` like anyone else.
    var webNames: [String] = []
    /// Your poster's short link, once you've made one (see `PosterCopy`).
    var posterCode: String?
    var posterURL: String?
    /// The link without "https://", for the tear-off tabs.
    var posterShortText: String?

    var isListing: Bool { listingKey != nil }

    init(
        title: String, category: Genre, details: String = "", placeName: String,
        coordinate: CLLocationCoordinate2D, start: Date, end: Date, capacity: Int = 0,
        othersGoing: Int = 0, hostName: String, bring: String = "", recurring: String = "",
        isMine: Bool = false, isSample: Bool = false
    ) {
        self.id = UUID()
        self.title = title
        self.categoryRaw = category.rawValue
        self.details = details
        self.placeName = placeName
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.start = start
        self.end = end
        self.capacity = capacity
        self.othersGoing = othersGoing
        self.hostName = hostName
        self.bring = bring
        self.recurring = recurring
        self.isJoined = isMine
        self.checkedInAt = nil
        self.isMine = isMine
        self.isSample = isSample
    }

    var category: Genre { Genre(rawValue: categoryRaw) ?? .party }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var going: Int { othersGoing + (isJoined ? 1 : 0) }
    var spotsLeft: Int? { capacity > 0 ? max(0, capacity - going) : nil }
    var isFull: Bool { spotsLeft == 0 }

    func isLive(at now: Date) -> Bool { start <= now && now < end }
    func hasEnded(at now: Date) -> Bool { end <= now }
    /// Check-in opens 30 minutes before the start and closes at the end.
    func checkInOpen(at now: Date) -> Bool { start.addingTimeInterval(-30 * 60) <= now && now < end }
}
