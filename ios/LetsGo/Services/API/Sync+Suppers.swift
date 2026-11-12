import Foundation
import SwiftData
import CoreLocation
import Observation

// MARK: The server's shapes

nonisolated struct CourseDTO: Codable, Sendable, Hashable {
    var name: String
    var note: String
}

nonisolated struct SeatDTO: Codable, Sendable, Hashable {
    var id: UUID
    var status: String
    var payment: String
    var note: String
    var priceCents: Int
    var serviceCents: Int
    var totalCents: Int
    var payBy: Date?
}

/// Someone at the table (the host or an accepted guest), for the others at it.
nonisolated struct TableMateDTO: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var displayName: String
    var isHost: Bool
    var isFriend: Bool
    var saidHi: Bool
    var reviewed: Bool
}

/// A supper as one person sees it. The address and the real spot only for the host and confirmed guests.
nonisolated struct SupperDTO: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var title: String
    var startsAt: Date
    var endsAt: Date
    var seats: Int
    var taken: Int
    var seatsLeft: Int
    var priceCents: Int
    var serviceCents: Int
    var seatTotalCents: Int
    var pay: String
    var menu: [CourseDTO]
    var tags: [String]
    var houseNotes: String
    var photoUrl: String?
    var host: PersonDTO
    var kitchenId: UUID
    var suppersHosted: Int
    var hostRating: Double?
    var hostReviewCount: Int
    var lat: Double
    var lon: Double
    var exact: Bool
    var address: String?
    var distanceM: Double?
    var friendsGoing: [PersonDTO]
    var isMine: Bool
    var canceled: Bool
    var mySeat: SeatDTO?
    var refundUntil: Date
    var waiting: Int
    var table: [TableMateDTO]

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var inApp: Bool { pay == "in_app" }
}

/// Someone asking for a seat, as the host sees them.
nonisolated struct GuestDTO: Codable, Sendable, Hashable, Identifiable {
    var seatId: UUID
    var guest: PersonDTO
    var note: String
    var status: String
    var payment: String
    var askedAt: Date
    var suppersAttended: Int
    var rating: Double?
    var reviewCount: Int
    var reviews: [String]
    var isFriend: Bool

    var id: UUID { seatId }
}

nonisolated struct MySuppersDTO: Codable, Sendable {
    var hosting: [SupperDTO]
    var going: [SupperDTO]
}

nonisolated struct NewSupperDTO: Encodable, Sendable {
    var title: String
    var startsAt: Date
    var endsAt: Date
    var seats: Int
    var priceCents: Int
    var menu: [CourseDTO]
    var tags: [String]
    var houseNotes: String
    var permitConfirmed: Bool
    var address: String?
    var lat: Double
    var lon: Double
}

nonisolated struct SeatAskDTO: Encodable, Sendable {
    var note: String
}

nonisolated struct SupperReviewDTO: Encodable, Sendable {
    var subjectId: UUID
    var stars: Int
    var text: String
}

// MARK: What the screens read

/// The suppers the phone knows about: around you (for the map), the ones you host and the ones you
/// asked for. Suppers live on the server (they need the host's yes), so this keeps the last answer
/// rather than storing them; what you do with one goes through `Ledger` (stamps and taste).
@Observable
final class SupperBook {
    static let shared = SupperBook()

    private(set) var nearby: [SupperDTO] = []
    private(set) var hosting: [SupperDTO] = []
    private(set) var going: [SupperDTO] = []

    /// Every supper known, newest copy wins, once each.
    var all: [SupperDTO] {
        var seen = Set<UUID>()
        return (hosting + going + nearby).filter { seen.insert($0.id).inserted }
    }

    func supper(_ id: UUID) -> SupperDTO? { all.first { $0.id == id } }

    /// What goes on the map and in the list: not called off, not over.
    func candidates(from here: CLLocationCoordinate2D, now: Date) -> [Candidate] {
        all.filter { !$0.canceled && $0.endsAt > now }.map { Candidate($0, from: here) }
    }

    func refresh(around c: CLLocationCoordinate2D) async throws(APIError) {
        nearby = try await Sync.suppers(around: c)
        let mine = try await Sync.mySuppers()
        hosting = mine.hosting
        going = mine.going
    }

    /// A fresh copy of one supper from the server, put wherever it's listed.
    func put(_ s: SupperDTO) {
        func replace(in list: inout [SupperDTO]) {
            if let i = list.firstIndex(where: { $0.id == s.id }) { list[i] = s }
        }
        replace(in: &nearby)
        replace(in: &hosting)
        replace(in: &going)
        if s.isMine, !hosting.contains(where: { $0.id == s.id }) { hosting.append(s) }
        if s.mySeat != nil, !s.isMine, !going.contains(where: { $0.id == s.id }) { going.append(s) }
        if !nearby.contains(where: { $0.id == s.id }), !s.isMine, s.mySeat == nil { nearby.append(s) }
    }
}

// MARK: Calls

/// Supper club: hosting, asking for a seat, the host's yes or no, paying for a seat (the same Stripe
/// path as batches), backing out, reviews both ways and adding the table as friends.
extension Sync {
    static func suppers(around c: CLLocationCoordinate2D) async throws(APIError) -> [SupperDTO] {
        try await api.send(.get("/v1/suppers", query: [
            URLQueryItem(name: "lat", value: String(c.latitude)),
            URLQueryItem(name: "lon", value: String(c.longitude)),
        ]))
    }

    static func mySuppers() async throws(APIError) -> MySuppersDTO {
        try await api.send(.get("/v1/me/suppers"))
    }

    static func supper(_ id: UUID, from here: CLLocationCoordinate2D) async throws(APIError) -> SupperDTO {
        let s: SupperDTO = try await api.send(.get("/v1/suppers/\(id.uuidString)", query: [
            URLQueryItem(name: "lat", value: String(here.latitude)),
            URLQueryItem(name: "lon", value: String(here.longitude)),
        ]))
        SupperBook.shared.put(s)
        return s
    }

    /// Sets up a supper. With no kitchen yet, the server opens one in your name. The photo goes up
    /// after, with `upload`, so a failed photo never means hosting it twice.
    static func host(_ draft: SupperDraft, at here: CLLocationCoordinate2D, context: ModelContext, now: Date = .now) async throws(APIError) -> SupperDTO {
        guard APIConfig.isConfigured else { throw .notConfigured }
        guard let price = draft.priceCents else { throw .rejected(status: 0, reason: "Set a price a seat.") }
        let w = draft.window()
        let address = draft.address.trimmingCharacters(in: .whitespaces)
        let s: SupperDTO = try await api.send(.post("/v1/suppers", NewSupperDTO(
            title: draft.title.trimmingCharacters(in: .whitespaces), startsAt: w.start, endsAt: w.end,
            seats: draft.seats, priceCents: price, menu: draft.menu,
            tags: SupperDraft.tagOptions.filter { draft.tags.contains($0) },
            houseNotes: draft.houseNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            permitConfirmed: draft.permitConfirmed, address: address.isEmpty ? nil : address,
            lat: here.latitude, lon: here.longitude
        )))
        SupperBook.shared.put(s)
        Ledger.hostSupper(context: context)
        return s
    }

    /// The supper's photo (a JPEG from `PhotoJPEG`). A new one replaces the old.
    static func upload(_ jpeg: Data, forSupper id: UUID, from here: CLLocationCoordinate2D) async throws(APIError) {
        let _: PhotoDTO = try await api.send(.upload("/v1/suppers/\(id.uuidString)/photo", jpeg: jpeg))
        _ = try await supper(id, from: here)
    }

    static func cancel(_ s: SupperDTO) async throws(APIError) -> SupperDTO {
        let fresh: SupperDTO = try await api.send(.delete("/v1/suppers/\(s.id.uuidString)"))
        SupperBook.shared.put(fresh)
        return fresh
    }

    // The host choosing

    static func requests(for s: SupperDTO) async throws(APIError) -> [GuestDTO] {
        try await api.send(.get("/v1/suppers/\(s.id.uuidString)/requests"))
    }

    static func answer(_ guest: GuestDTO, yes: Bool) async throws(APIError) -> [GuestDTO] {
        try await api.send(.post("/v1/supper-seats/\(guest.seatId.uuidString)/\(yes ? "accept" : "decline")"))
    }

    // Guests

    static func askForSeat(at s: SupperDTO, note: String, context: ModelContext) async throws(APIError) -> SupperDTO {
        let fresh: SupperDTO = try await api.send(.post(
            "/v1/suppers/\(s.id.uuidString)/seats",
            SeatAskDTO(note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        ))
        SupperBook.shared.put(fresh)
        Ledger.askForSeat(context: context)
        return fresh
    }

    static func giveBackSeat(at s: SupperDTO) async throws(APIError) -> SupperDTO {
        let fresh: SupperDTO = try await api.send(.delete("/v1/suppers/\(s.id.uuidString)/seat"))
        SupperBook.shared.put(fresh)
        return fresh
    }

    /// What PaymentSheet needs for a seat the host said yes to. Asking again returns the same payment.
    static func checkout(seat id: UUID) async throws(APIError) -> PaymentDTO {
        try await api.send(.post("/v1/supper-seats/\(id.uuidString)/pay"))
    }

    // Afterwards

    static func review(_ mate: TableMateDTO, stars: Int, text: String, at s: SupperDTO) async throws(APIError) -> SupperDTO {
        let fresh: SupperDTO = try await api.send(.post(
            "/v1/suppers/\(s.id.uuidString)/reviews",
            SupperReviewDTO(subjectId: mate.id, stars: stars, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        ))
        SupperBook.shared.put(fresh)
        return fresh
    }

    /// Add someone from the table. True when they already had, and you're friends now.
    static func addFromTable(_ mate: TableMateDTO, at s: SupperDTO, around c: CLLocationCoordinate2D, context: ModelContext) async throws(APIError) -> Bool {
        let result: IntroResultDTO = try await api.send(.post("/v1/suppers/\(s.id.uuidString)/table/\(mate.id.uuidString)/hi"))
        if result.connected { try await refreshPeople(around: c, context: context) }
        _ = try await supper(s.id, from: c)
        return result.connected
    }
}

extension Candidate {
    /// A supper on the map: a photo pin like a batch, with the seats left on its tag.
    init(_ s: SupperDTO, from here: CLLocationCoordinate2D) {
        self.init(
            id: s.id, kind: .supper, title: s.title, category: .food,
            start: s.startsAt, end: s.endsAt, meters: here.distance(to: s.coordinate),
            capacity: s.seats, going: s.taken,
            priceFromCents: s.priceCents,
            isJoined: s.mySeat.map { $0.status == SeatStatus.accepted.rawValue } ?? false,
            place: SupperCopy.at(s.host.displayName),
            searchText: ([s.title, s.host.displayName, "supper dinner food home cooking"] + s.tags + s.menu.map { "\($0.name) \($0.note)" })
                .joined(separator: " ").lowercased(),
            lat: s.lat, lon: s.lon, friendIDs: s.friendsGoing.map(\.id),
            photoURL: APIConfig.resolve(s.photoUrl),
            glyph: "🍲"
        )
    }
}
