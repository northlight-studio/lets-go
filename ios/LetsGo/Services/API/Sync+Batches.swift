import Foundation
import SwiftData
import CoreLocation

/// Post a batch, sell to your neighbors: posting (with its photo), the listing page, reserving and
/// paying, following a kitchen, and the cook's side (orders with codes, payouts). Server first, then
/// the store through `Ledger`.
extension Sync {
    // MARK: Posting

    /// Posts the batch. With no kitchen yet, the server opens one in your name. The photo goes up
    /// after, with `upload`, so a failed photo never means posting the batch twice.
    @discardableResult
    static func post(
        _ draft: BatchDraft, at here: CLLocationCoordinate2D, mine: Kitchen?, context: ModelContext, now: Date = .now
    ) async throws(APIError) -> Drop {
        guard APIConfig.isConfigured else { throw .notConfigured }
        guard let w = draft.window(now: now), let price = draft.priceCents else {
            throw .rejected(status: 0, reason: draft.problem(now: now, needsAddress: false, needsPermit: false) ?? "Check the form.")
        }
        let address = draft.address.trimmingCharacters(in: .whitespaces)
        let note = draft.pickupNote.trimmingCharacters(in: .whitespaces)
        let dto: BatchDTO = try await api.send(.post("/v1/batches", NewBatchDTO(
            title: draft.title.trimmingCharacters(in: .whitespaces), priceCents: price, total: draft.count,
            unit: draft.unit.trimmingCharacters(in: .whitespaces), startsAt: w.start, endsAt: w.end,
            pickupSpot: draft.spot.rawValue, tags: BatchDraft.tagOptions.filter { draft.tags.contains($0) },
            permitConfirmed: draft.permitConfirmed, address: address.isEmpty ? nil : address,
            pickupNote: note.isEmpty ? nil : note, lat: here.latitude, lon: here.longitude
        )))

        let kitchen: Kitchen
        if let mine {
            kitchen = mine
            kitchen.remoteID = dto.kitchen.id
        } else {
            kitchen = Kitchen(
                name: dto.kitchen.name, cookName: "You", cuisine: dto.kitchen.cuisine, story: dto.kitchen.story,
                coordinate: .init(latitude: dto.kitchen.lat, longitude: dto.kitchen.lon), pickupNote: note, isMine: true
            )
            kitchen.remoteID = dto.kitchen.id
            Ledger.openKitchen(kitchen, context: context)
        }
        update(kitchen, from: dto.kitchen, context: context)
        if let a = dto.address { kitchen.address = a }
        if let n = dto.pickupNote { kitchen.pickupNote = n }
        let drop = upsert(dto.drop, in: kitchen, context: context)
        Ledger.postBatch(drop, at: kitchen, context: context)
        return drop
    }

    /// The batch's photo (a JPEG from `PhotoJPEG`). A new one replaces the old.
    static func upload(_ jpeg: Data, for drop: Drop, context: ModelContext) async throws(APIError) {
        guard let id = drop.remoteID else { throw .notConfigured }
        let p: PhotoDTO = try await api.send(.upload("/v1/drops/\(id.uuidString)/photo", jpeg: jpeg))
        drop.photoURL = p.photoUrl
        Ledger.save(context, "batch photo")
    }

    // MARK: The listing page

    /// A batch's page: how many are left, the full slots, the kitchen's regulars and followers, a
    /// review, and (once you've reserved) the address.
    static func refresh(batch drop: Drop, context: ModelContext) async throws(APIError) {
        guard let id = drop.remoteID, let k = drop.kitchen else { return }
        let dto: BatchDTO = try await api.send(.get("/v1/drops/\(id.uuidString)"))
        update(k, from: dto.kitchen, context: context)
        upsert(dto.drop, in: k, context: context)
        drop.fullSlots = dto.fullSlots
        if let a = dto.address { k.address = a }
        if let n = dto.pickupNote { k.pickupNote = n }
        if let r = dto.review {
            k.quote = r.text
            k.quoteAuthor = r.authorName
        }
        Ledger.save(context, "refresh batch")
    }

    // MARK: Reserving and paying

    /// Reserves `quantity` from a batch at a pickup slot. `orderID` is made once per attempt on the
    /// screen and reused on retry, so a timeout can't place a second order.
    static func reserve(
        _ quantity: Int, of drop: Drop, at slot: Date, orderID: UUID, context: ModelContext
    ) async throws(APIError) -> Order {
        guard let k = drop.kitchen, let dropID = drop.remoteID else {
            throw .rejected(status: 409, reason: "This batch isn't on the server yet. Try again in a moment.")
        }
        let dto: OrderDTO = try await api.send(.post("/v1/orders", NewOrderDTO(
            clientId: orderID, dropId: dropID, pickupAt: slot, lines: [], quantity: quantity, eatOnPorch: false
        )))
        let order = Order(
            pickupAt: dto.pickupAt,
            lines: dto.lines.map { OrderLine(name: $0.name, priceCents: $0.priceCents, quantity: $0.quantity) },
            eatOnPorch: false
        )
        order.id = orderID
        order.remoteID = dto.id
        apply(dto, to: order)
        Ledger.reserve(order, at: k, drop: drop, context: context)
        return order
    }

    /// What PaymentSheet needs for an order paid in the app. Asking again returns the same payment.
    static func checkout(_ order: Order) async throws(APIError) -> PaymentDTO {
        guard let id = order.remoteID else { throw .notConfigured }
        return try await api.send(.post("/v1/orders/\(id.uuidString)/pay"))
    }

    /// The order as the server has it now: paid (once Stripe says so), the code and the address.
    static func refresh(order: Order, context: ModelContext) async throws(APIError) {
        guard let id = order.remoteID else { return }
        let dto: OrderDTO = try await api.send(.get("/v1/orders/\(id.uuidString)"))
        apply(dto, to: order)
        Ledger.settle(order, context: context)
    }

    /// Copies what the server knows about an order onto the local one.
    static func apply(_ dto: OrderDTO, to order: Order) {
        if let p = dto.payment, let payment = PaymentState(rawValue: p) { order.payment = payment }
        if let c = dto.pickupCode, !c.isEmpty { order.pickupCode = c }
        if let t = dto.title { order.title = t }
        if let u = dto.unit { order.unit = u }
        if let s = dto.pickupSpot { order.pickupSpot = s }
        if dto.photoUrl != nil { order.photoURL = dto.photoUrl }
        if let a = dto.address { order.address = a }
        if let lat = dto.lat, let lon = dto.lon {
            order.exactLatitude = lat
            order.exactLongitude = lon
        }
        switch dto.status {
        case "picked_up": if order.status == .reserved { order.status = .pickedUp }
        case "reviewed": order.status = .reviewed
        case "canceled": if order.payment != .paid && order.payment != .refunded { order.payment = .expired }
        default: break
        }
        if let k = order.kitchen {
            if !dto.pickupNote.isEmpty { k.pickupNote = dto.pickupNote }
            if let a = dto.address { k.address = a }
        }
    }

    // MARK: Following

    static func follow(_ k: Kitchen, _ on: Bool, context: ModelContext) async throws(APIError) {
        guard let id = k.remoteID else { return }
        let path = "/v1/kitchens/\(id.uuidString)/follow"
        let endpoint: Endpoint<FollowDTO> = on ? .put(path) : .delete(path)
        let dto = try await api.send(endpoint)
        Ledger.follow(k, dto.following, followers: dto.followers, context: context)
    }

    /// New batches from kitchens you follow (the last two weeks). Push isn't set up yet; these show in Plans.
    static func notes() async throws(APIError) -> [NoteDTO] {
        guard APIConfig.isConfigured else { return [] }
        return try await api.send(.get("/v1/me/notes"))
    }

    static func markNotesRead() async throws(APIError) {
        let _: Empty = try await api.send(.post("/v1/me/notes/read"))
    }

    // MARK: The cook's side

    /// Hands an order over: marks it picked up (and checks the code, if one was typed).
    static func handOver(_ orderID: UUID, code: String?) async throws(APIError) -> OrderDTO {
        try await api.send(.post("/v1/kitchens/me/orders/\(orderID.uuidString)/picked-up", PickupCodeDTO(code: code)))
    }

    static func payouts() async throws(APIError) -> PayoutsDTO {
        try await api.send(.get("/v1/kitchens/me/payouts"))
    }

    /// Makes your Stripe account (once) and returns Stripe's page to finish setting up payouts.
    static func setUpPayouts() async throws(APIError) -> PayoutsDTO {
        try await api.send(.post("/v1/kitchens/me/payouts"))
    }
}
