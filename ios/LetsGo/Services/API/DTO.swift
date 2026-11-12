import Foundation

// Shapes of the backend's JSON (backend/app/schemas.py), snake_case converted.

nonisolated struct GatheringDTO: Codable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var genre: String
    var details: String
    var placeName: String
    var lat: Double
    var lon: Double
    var startsAt: Date
    var endsAt: Date
    var capacity: Int
    var bring: String
    var recurring: String
    var hostName: String
    var going: Int
    var isMine: Bool
    var isJoined: Bool
    var checkedInAt: Date?
    var distanceM: Double?
    /// Your friends who are in. Older servers don't send it.
    var friendsGoing: [PersonDTO]?
    /// How many of `going` said they're in from a poster's web page, and (to the host only) their first names.
    var webGoing: Int?
    var webNames: [String]?
}

/// A poster's short link (backend `PosterOut`).
nonisolated struct PosterDTO: Codable, Sendable {
    var code: String
    var url: String
    var shortText: String
    var gatheringId: UUID
    var views: Int
    var webGoing: Int
}

nonisolated struct NewPosterDTO: Encodable, Sendable {
    /// The host's IANA time zone, so the web page shows local time and a weekly one keeps its hour.
    var tz: String
}

nonisolated struct NewGatheringDTO: Encodable, Sendable {
    var title: String
    var genre: String
    var details: String
    var placeName: String
    var lat: Double
    var lon: Double
    var startsAt: Date
    var endsAt: Date
    var capacity: Int
    var bring: String
    var recurring: String = ""
}

nonisolated struct CheckInDTO: Encodable, Sendable {
    var lat: Double
    var lon: Double
}

nonisolated struct DropDTO: Codable, Sendable {
    var id: UUID
    var startsAt: Date
    var endsAt: Date
    var total: Int
    var sold: Int
    var perSlot: Int
    var left: Int
    // A batch's own fields. Older servers don't send them.
    var title: String?
    var unit: String?
    var priceCents: Int?
    var tags: [String]?
    var pickupSpot: String?
    /// Relative to the server ("/v1/photos/…"); see `APIConfig.resolve`.
    var photoUrl: String?
}

/// POST /v1/batches: post a batch (opens a kitchen in your name the first time).
nonisolated struct NewBatchDTO: Encodable, Sendable {
    var title: String
    var priceCents: Int
    var total: Int
    var unit: String
    var startsAt: Date
    var endsAt: Date
    var pickupSpot: String
    var tags: [String]
    var permitConfirmed: Bool
    var address: String?
    var pickupNote: String?
    var lat: Double?
    var lon: Double?
}

/// A batch's listing page (GET /v1/drops/{id}): the drop's fields, its kitchen, a review, the full slots,
/// and the address for the owner and people who've reserved.
nonisolated struct BatchDTO: Codable, Sendable {
    var id: UUID
    var startsAt: Date
    var endsAt: Date
    var total: Int
    var sold: Int
    var perSlot: Int
    var left: Int
    var title: String
    var unit: String
    var priceCents: Int?
    var tags: [String]
    var pickupSpot: String
    var photoUrl: String?
    var kitchen: KitchenDTO
    var review: ReviewDTO?
    var fullSlots: [Date]
    var address: String?
    var pickupNote: String?

    var drop: DropDTO {
        DropDTO(id: id, startsAt: startsAt, endsAt: endsAt, total: total, sold: sold, perSlot: perSlot, left: left,
                title: title, unit: unit, priceCents: priceCents, tags: tags, pickupSpot: pickupSpot, photoUrl: photoUrl)
    }
}

nonisolated struct PhotoDTO: Codable, Sendable {
    var photoUrl: String
}

nonisolated struct FollowDTO: Codable, Sendable {
    var following: Bool
    var followers: Int
}

/// Something for you: a kitchen you follow posted a batch.
nonisolated struct NoteDTO: Codable, Sendable, Identifiable {
    var id: UUID
    var kind: String
    var kitchenId: UUID
    var kitchenName: String
    var dropId: UUID?
    var title: String
    var photoUrl: String?
    var startsAt: Date?
    var createdAt: Date
    var read: Bool
}

/// What PaymentSheet needs for one order. `clientSecret` is nil once it's paid.
nonisolated struct PaymentDTO: Codable, Sendable {
    var orderId: UUID
    var payment: String
    var amountCents: Int
    var clientSecret: String?
    var publishableKey: String
    var merchantId: String?
    var merchantName: String
    var country: String
}

nonisolated struct PayoutsDTO: Codable, Sendable {
    var enabled: Bool
    var ready: Bool
    var onboardingUrl: String?
}

nonisolated struct PickupCodeDTO: Encodable, Sendable {
    var code: String?
}

nonisolated struct MenuItemDTO: Codable, Sendable {
    var id: UUID
    var name: String
    var note: String
    var priceCents: Int
}

nonisolated struct ReviewDTO: Codable, Sendable {
    var stars: Int
    var tags: [String]
    var text: String
    var authorName: String
    var createdAt: Date
}

nonisolated struct KitchenDTO: Codable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var cookName: String
    var cuisine: String
    var story: String
    var lat: Double
    var lon: Double
    var porchTables: Int
    var permitted: Bool
    var rating: Double?
    var reviewCount: Int
    var nextDrop: DropDTO?
    var isMine: Bool
    var distanceM: Double?
    /// The next drop's photo, for the map's food pin.
    var photoUrl: String?
    /// "in_app" or "at_pickup". Older servers don't send it.
    var pay: String?
    // Only on the detail endpoint (and a batch's page).
    var regulars: Int?
    var followers: Int?
    var isFollowing: Bool?
    var menu: [MenuItemDTO]?
    var reviews: [ReviewDTO]?
    var pickupNote: String?
    var address: String?
    var table: TableDTO?
}

nonisolated struct TableDTO: Codable, Sendable {
    var seats: Int
    var taken: Int
    var friends: [TableFriendDTO]
}

nonisolated struct TableFriendDTO: Codable, Sendable {
    var id: UUID
    var displayName: String
    var pickupAt: Date
}

nonisolated struct NearbyDTO: Codable, Sendable {
    var gatherings: [GatheringDTO]
    var kitchens: [KitchenDTO]
}

nonisolated struct NewKitchenDTO: Encodable, Sendable {
    var name: String
    var cuisine: String
    var story: String
    var lat: Double
    var lon: Double
    var pickupNote: String
    var porchTables: Int
    var permitConfirmed: Bool
    var handlerCardConfirmed: Bool
}

nonisolated struct KitchenPermitsDTO: Encodable, Sendable {
    var permitConfirmed: Bool
    var handlerCardConfirmed: Bool
}

nonisolated struct NewMenuItemDTO: Encodable, Sendable {
    var name: String
    var note: String
    var priceCents: Int
}

nonisolated struct NewDropDTO: Encodable, Sendable {
    var startsAt: Date
    var endsAt: Date
    var total: Int
    var perSlot: Int
}

nonisolated struct OrderLineDTO: Codable, Sendable {
    var name: String
    var priceCents: Int
    var quantity: Int
}

nonisolated struct OrderDTO: Codable, Sendable {
    var id: UUID
    var clientId: UUID
    var kitchenId: UUID
    var kitchenName: String
    var dropId: UUID
    var pickupAt: Date
    var eatOnPorch: Bool
    var status: String
    var lines: [OrderLineDTO]
    var subtotalCents: Int
    var serviceCents: Int
    var totalCents: Int
    var pickupNote: String
    // Older servers don't send these.
    var payment: String?
    var pickupCode: String?
    var pickedUpAt: Date?
    var title: String?
    var unit: String?
    var photoUrl: String?
    var pickupSpot: String?
    var address: String?
    var lat: Double?
    var lon: Double?
    /// On the cook's list only.
    var buyerName: String?
}

nonisolated struct NewOrderDTO: Encodable, Sendable {
    struct Line: Encodable, Sendable {
        var menuItemId: UUID
        var quantity: Int
    }

    var clientId: UUID
    var dropId: UUID
    var pickupAt: Date
    var lines: [Line]
    /// A batch takes a quantity instead of lines.
    var quantity: Int? = nil
    var eatOnPorch: Bool
}

nonisolated struct NewReviewDTO: Encodable, Sendable {
    var stars: Int
    var tags: [String]
    var text: String
}

nonisolated struct ProfileDTO: Codable, Sendable {
    var displayName: String
}

/// GET /v1/listings: the same shape as sf_happenings.json, so the phone keeps the server's copy as-is.
nonisolated struct ListingsDTO: Codable, Sendable {
    var listings: [ListingDTO]
}

nonisolated struct ListingDTO: Codable, Sendable {
    var title: String
    var genre: String
    var venue: String
    var address: String
    var lat: Double
    var lon: Double
    var schedule: [SlotDTO]
    var price: String
    var organizer: String
    var url: String
    var description: String
    var confidence: String
}

nonisolated struct SlotDTO: Codable, Sendable {
    var weekday: String?
    var date: String?
    var start: String
    var end: String?
}

// People (backend/app/routes/people.py)

nonisolated struct PersonDTO: Codable, Sendable, Hashable {
    var id: UUID
    var displayName: String
}

nonisolated struct FriendCodeDTO: Codable, Sendable {
    var code: String
    var expiresAt: Date
}

nonisolated struct AcceptCodeDTO: Encodable, Sendable {
    var code: String
}

nonisolated struct PorchLightInDTO: Encodable, Sendable {
    var hours: Double
    var note: String
    var lat: Double?
    var lon: Double?
}

nonisolated struct PorchLightDTO: Codable, Sendable {
    var onUntil: Date
    var note: String
    var lat: Double?
    var lon: Double?
    var distanceM: Double?
}

/// Up for something (`/v1/me/up-for`). Never anyone's coordinates.
nonisolated struct UpForDTO: Codable, Sendable {
    var activity: String
    var label: String
    var words: String
    var until: Date
    var bubble: String
    var walkMin: Int?
}

nonisolated struct UpForInDTO: Encodable, Sendable {
    var activity: String
    var words: String
    var hours: Double
    var lat: Double?
    var lon: Double?
}

nonisolated struct PointDTO: Codable, Sendable {
    var lat: Double
    var lon: Double
}

nonisolated struct SpotDTO: Codable, Sendable {
    var name: String
    var lat: Double
    var lon: Double
}

nonisolated struct ImInDTO: Encodable, Sendable {
    var lat: Double?
    var lon: Double?
}

nonisolated struct MeetupUpdateDTO: Encodable, Sendable {
    var lat: Double?
    var lon: Double?
    var onMyWay: Bool?
    var says: String?
}

/// You and one other person meeting (`/v1/up-for/{id}/in`, `/v1/meetups/…`).
nonisolated struct MeetupDTO: Codable, Sendable {
    var id: UUID
    var other: PersonDTO
    var isMine: Bool
    var activity: String
    var label: String
    var headline: String
    var spot: SpotDTO?
    var area: PointDTO?
    var meetAt: Date
    var endsAt: Date
    var myWalkMin: Int?
    var theirWalkMin: Int?
    var iAmOnMyWay: Bool
    var theyAreOnTheirWay: Bool
    var theySay: String
}

nonisolated struct OutNowDTO: Codable, Sendable {
    var gatheringId: UUID
    var title: String
    var placeName: String
    var startsAt: Date
    var endsAt: Date
    var state: String
    var lat: Double
    var lon: Double
}

nonisolated struct FriendDTO: Codable, Sendable {
    var id: UUID
    var displayName: String
    var porchLight: PorchLightDTO?
    /// Older servers don't send it; `porchLight` stands in.
    var upFor: UpForDTO?
    var out: OutNowDTO?
    var wavedAt: Date?
}

nonisolated struct CrewDTO: Codable, Sendable {
    var id: UUID
    var name: String
    var isMine: Bool
    var members: [PersonDTO]
    var next: CrewNextDTO?
}

nonisolated struct CrewNextDTO: Codable, Sendable {
    var gatheringId: UUID
    var title: String
    var startsAt: Date
    var going: Int
}

nonisolated struct NewCrewDTO: Encodable, Sendable {
    var name: String
    var memberIds: [UUID]
}

nonisolated struct InviteFriendsDTO: Encodable, Sendable {
    var userIds: [UUID]
}

nonisolated struct InvitedDTO: Codable, Sendable {
    var invited: Int
}

nonisolated struct GatheringInviteDTO: Codable, Sendable {
    var gathering: GatheringDTO
    var sender: PersonDTO
    var createdAt: Date
}

nonisolated struct PeopleDTO: Codable, Sendable {
    var porchLight: PorchLightDTO?
    var upFor: UpForDTO?
    var meetup: MeetupDTO?
    var friends: [FriendDTO]
    var crews: [CrewDTO]
    var invites: [GatheringInviteDTO]
    /// Third time's a friend. Older servers don't send it.
    var intros: [IntroDTO]?
}

nonisolated struct SharedNightDTO: Codable, Sendable {
    var title: String
    var startsAt: Date
}

nonisolated struct IntroDTO: Codable, Sendable {
    var person: PersonDTO
    var together: [SharedNightDTO]
    var saidHi: Bool
    var upFor: UpForDTO?
    var wavedAt: Date?
}

nonisolated struct IntroResultDTO: Codable, Sendable {
    var connected: Bool
}
