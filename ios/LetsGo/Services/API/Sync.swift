import Foundation
import SwiftData
import CoreLocation
import OSLog

/// Moves things between the backend and this phone's store.
///
/// The store stays the source the screens read from. `refresh` pulls what's
/// nearby into it; the actions below send a change to the server first when the
/// thing lives there, then apply it locally through `Ledger` (stamps, taste).
/// On-phone-only things never touch the network.
enum Sync {
    private static let log = Logger(subsystem: "com.yasser100ali.letsgo", category: "sync")
    static var api: APIClient { .shared }

    // MARK: Pull

    static func refresh(around c: CLLocationCoordinate2D, context: ModelContext) async throws(APIError) {
        let nearby: NearbyDTO = try await api.send(.get("/v1/nearby", query: [
            URLQueryItem(name: "lat", value: String(c.latitude)),
            URLQueryItem(name: "lon", value: String(c.longitude)),
        ]))
        apply(nearby, context: context)
    }

    static func apply(_ nearby: NearbyDTO, context: ModelContext) {
        let localGatherings = fetch(context, FetchDescriptor<Gathering>(predicate: #Predicate { $0.remoteID != nil }))
        var byID = Dictionary(localGatherings.compactMap { g in g.remoteID.map { ($0, g) } }, uniquingKeysWith: { a, _ in a })
        for dto in nearby.gatherings {
            if let g = byID.removeValue(forKey: dto.id) {
                update(g, from: dto)
            } else {
                let g = Gathering(
                    title: dto.title, category: Genre(rawValue: dto.genre) ?? .party, placeName: dto.placeName,
                    coordinate: .init(latitude: dto.lat, longitude: dto.lon), start: dto.startsAt, end: dto.endsAt,
                    hostName: dto.hostName
                )
                g.remoteID = dto.id
                update(g, from: dto)
                context.insert(g)
            }
        }
        // Gone from the server's answer: cancelled, ended or out of range. Nearby only looks a day
        // and a half ahead and a walk around you, so keep what you host or joined (pruning takes
        // those off once they end) and the ones you showed up to, so their stamps keep a home.
        for g in byID.values where g.checkedInAt == nil && !g.isMine && !g.isJoined { context.delete(g) }

        let localKitchens = fetch(context, FetchDescriptor<Kitchen>(predicate: #Predicate { $0.remoteID != nil }))
        let kitchensByID = Dictionary(localKitchens.compactMap { k in k.remoteID.map { ($0, k) } }, uniquingKeysWith: { a, _ in a })
        for dto in nearby.kitchens {
            let k = kitchensByID[dto.id] ?? insertKitchen(dto, context: context)
            update(k, from: dto, context: context)
        }
        Ledger.save(context, "apply nearby")
    }

    /// The kitchen page: menu, reviews and (once you've ordered) the pickup note.
    static func refresh(_ kitchen: Kitchen, context: ModelContext) async throws(APIError) {
        guard let id = kitchen.remoteID else { return }
        let dto: KitchenDTO = try await api.send(.get("/v1/kitchens/\(id.uuidString)"))
        update(kitchen, from: dto, context: context)
        if dto.table == nil {
            // No porch table for the next drop: last drop's seats and friends don't carry over.
            kitchen.tableTaken = 0
            kitchen.tableFriends = []
        }
        Ledger.save(context, "refresh kitchen")
    }

    /// Like `refresh`, for a screen opening: a failure is logged and the phone's copy stays.
    static func refreshQuietly(_ kitchen: Kitchen, context: ModelContext) async {
        do {
            try await refresh(kitchen, context: context)
        } catch {
            log.error("Refreshing \(kitchen.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Every order at your kitchen, from the server: what sold, and who's picking up when.
    static func kitchenOrders(_ k: Kitchen) async throws(APIError) -> [OrderDTO]? {
        guard k.isMine, k.remoteID != nil else { return nil }
        return try await api.send(.get("/v1/kitchens/me/orders"))
    }

    static func saveName(_ name: String) async throws(APIError) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard APIConfig.isConfigured, !trimmed.isEmpty else { return }
        let _: ProfileDTO = try await api.send(.patch("/v1/me", ProfileDTO(displayName: trimmed)))
    }

    // MARK: Gatherings

    static func host(_ g: Gathering, context: ModelContext) async throws(APIError) {
        if APIConfig.isConfigured {
            let dto: GatheringDTO = try await api.send(.post("/v1/gatherings", NewGatheringDTO(
                title: g.title, genre: g.categoryRaw, details: g.details, placeName: g.placeName,
                lat: g.latitude, lon: g.longitude, startsAt: g.start, endsAt: g.end,
                capacity: g.capacity, bring: g.bring, recurring: g.recurring
            )))
            g.remoteID = dto.id
            update(g, from: dto)
        }
        Ledger.host(g, context: context)
    }

    static func cancel(_ g: Gathering, context: ModelContext) async throws(APIError) {
        if let id = g.remoteID {
            do {
                let _: Empty = try await api.send(.delete("/v1/gatherings/\(id.uuidString)"))
            } catch .rejected(404, _) {
                // Already gone on the server.
            }
        }
        Ledger.cancel(g, context: context)
    }

    static func join(_ g: Gathering, context: ModelContext) async throws(APIError) {
        if let id = g.remoteID {
            do {
                update(g, from: try await api.send(.post("/v1/gatherings/\(id.uuidString)/join")))
            } catch .rejected(404, _) {
                // The next pull takes it off the map; deleting it here would pull it out from under its page.
                throw .rejected(status: 404, reason: "It's been called off.")
            }
        }
        Ledger.join(g, context: context)
    }

    static func leave(_ g: Gathering, context: ModelContext) async throws(APIError) {
        if let id = g.remoteID {
            do {
                update(g, from: try await api.send(.delete("/v1/gatherings/\(id.uuidString)/join")))
            } catch .rejected(404, _) {
                // Called off on the server: nothing left to leave there.
            }
        }
        Ledger.leave(g, context: context)
    }

    /// The server checks the distance too; the phone's check is only so the button can show.
    static func checkIn(_ g: Gathering, at c: CLLocationCoordinate2D, context: ModelContext) async throws(APIError) -> Stamp? {
        if let id = g.remoteID {
            update(g, from: try await api.send(.post("/v1/gatherings/\(id.uuidString)/check-in", CheckInDTO(lat: c.latitude, lon: c.longitude))))
        }
        return Ledger.checkIn(g, context: context)
    }

    // MARK: Posters

    /// The gathering's poster link: made the first time, the same one after. Only for a real
    /// gathering you host that lives on the server; `PosterCopy.unavailable` says why not.
    @discardableResult
    static func makePoster(for g: Gathering, context: ModelContext, now: Date = .now) async throws(APIError) -> PosterDTO {
        if let reason = PosterCopy.unavailable(g, now: now) { throw .rejected(status: 0, reason: reason) }
        guard let id = g.remoteID else { throw .notConfigured }
        let dto: PosterDTO = try await api.send(.post(
            "/v1/gatherings/\(id.uuidString)/poster", NewPosterDTO(tz: TimeZone.current.identifier)
        ))
        Ledger.poster(g, code: dto.code, url: dto.url, shortText: dto.shortText, context: context)
        return dto
    }

    /// Takes the poster down: its page says so and takes no more joins.
    static func retirePoster(for g: Gathering, context: ModelContext) async throws(APIError) {
        if let code = g.posterCode {
            let _: Empty = try await api.send(.delete("/v1/posters/\(code)"))
        }
        Ledger.retirePoster(g, context: context)
    }

    // MARK: Kitchens

    static func open(_ k: Kitchen, context: ModelContext) async throws(APIError) {
        if APIConfig.isConfigured {
            let dto: KitchenDTO
            do {
                dto = try await api.send(.post("/v1/kitchens", NewKitchenDTO(
                    name: k.name, cuisine: k.cuisine, story: k.story, lat: k.latitude, lon: k.longitude,
                    pickupNote: k.pickupNote, porchTables: k.porchTables,
                    permitConfirmed: k.permitConfirmed, handlerCardConfirmed: k.handlerCardConfirmed
                )))
            } catch .rejected(409, _) {
                // You opened one before (another phone, or before a reinstall): take that one back.
                let existing: KitchenDTO = try await api.send(.get("/v1/kitchens/me"))
                if let local = fetch(context, FetchDescriptor<Kitchen>()).first(where: { $0.remoteID == existing.id }) {
                    update(local, from: existing, context: context)
                    Ledger.save(context, "adopt kitchen")
                    return
                }
                let adopted = insertKitchen(existing, context: context)
                update(adopted, from: existing, context: context)
                adopted.permitConfirmed = existing.permitted || k.permitConfirmed
                adopted.handlerCardConfirmed = existing.permitted || k.handlerCardConfirmed
                Ledger.openKitchen(adopted, context: context)
                return
            }
            k.remoteID = dto.id
        }
        Ledger.openKitchen(k, context: context)
    }

    static func savePermits(_ k: Kitchen, permit: Bool, card: Bool, context: ModelContext) async throws(APIError) {
        if k.remoteID != nil {
            let _: KitchenDTO = try await api.send(.patch("/v1/kitchens/me", KitchenPermitsDTO(
                permitConfirmed: permit, handlerCardConfirmed: card
            )))
        }
        k.permitConfirmed = permit
        k.handlerCardConfirmed = card
        Ledger.save(context, "permits")
    }

    static func add(_ item: MenuItem, to k: Kitchen, context: ModelContext) async throws(APIError) {
        if k.remoteID != nil {
            let dto: MenuItemDTO = try await api.send(.post("/v1/kitchens/me/menu", NewMenuItemDTO(
                name: item.name, note: item.note, priceCents: item.priceCents
            )))
            item.remoteID = dto.id
        }
        context.insert(item)
        item.kitchen = k
        Ledger.save(context, "add menu item")
    }

    static func remove(_ item: MenuItem, context: ModelContext) async throws(APIError) {
        if let id = item.remoteID {
            let _: Empty = try await api.send(.delete("/v1/kitchens/me/menu/\(id.uuidString)"))
        }
        context.delete(item)
        Ledger.save(context, "remove menu item")
    }

    static func post(_ drop: Drop, to k: Kitchen, context: ModelContext) async throws(APIError) {
        if k.remoteID != nil {
            let dto: DropDTO = try await api.send(.post("/v1/kitchens/me/drops", NewDropDTO(
                startsAt: drop.start, endsAt: drop.end, total: drop.total, perSlot: drop.perSlot
            )))
            drop.remoteID = dto.id
        }
        context.insert(drop)
        drop.kitchen = k
        Ledger.save(context, "post drop")
    }

    // MARK: Orders

    static func reserve(
        _ order: Order, picked: [(item: MenuItem, quantity: Int)], at k: Kitchen, drop: Drop, context: ModelContext
    ) async throws(APIError) {
        if k.remoteID != nil {
            guard let dropID = drop.remoteID else {
                throw .rejected(status: 409, reason: "This drop isn't on the server yet. Try again in a moment.")
            }
            var lines: [NewOrderDTO.Line] = []
            for p in picked {
                guard let id = p.item.remoteID else {
                    throw .rejected(status: 409, reason: "\(p.item.name) isn't on the server's menu.")
                }
                lines.append(.init(menuItemId: id, quantity: p.quantity))
            }
            // The order's own id doubles as the idempotency key: a retry returns the same order.
            let dto: OrderDTO = try await api.send(.post("/v1/orders", NewOrderDTO(
                clientId: order.id, dropId: dropID, pickupAt: order.pickupAt, lines: lines, eatOnPorch: order.eatOnPorch
            )))
            order.remoteID = dto.id
            // A retry returns the order as first placed: keep the server's slot and lines.
            order.pickupAt = dto.pickupAt
            order.eatOnPorch = dto.eatOnPorch
            order.lines = dto.lines.map { OrderLine(name: $0.name, priceCents: $0.priceCents, quantity: $0.quantity) }
            k.pickupNote = dto.pickupNote
        }
        Ledger.reserve(order, at: k, drop: drop, context: context)
    }

    static func pickedUp(_ order: Order, context: ModelContext) async throws(APIError) {
        if let id = order.remoteID {
            let _: OrderDTO = try await api.send(.post("/v1/orders/\(id.uuidString)/picked-up"))
        }
        order.status = .pickedUp
        Ledger.save(context, "picked up")
    }

    static func review(_ review: Review, for order: Order, context: ModelContext) async throws(APIError) -> Stamp? {
        if let id = order.remoteID {
            let _: OrderDTO = try await api.send(.post("/v1/orders/\(id.uuidString)/review", NewReviewDTO(
                stars: review.stars, tags: review.tags, text: review.text
            )))
        }
        return Ledger.review(review, for: order, context: context)
    }

    // MARK: Mapping

    static func update(_ g: Gathering, from dto: GatheringDTO) {
        g.title = dto.title
        g.categoryRaw = dto.genre
        g.details = dto.details
        g.placeName = dto.placeName
        g.latitude = dto.lat
        g.longitude = dto.lon
        g.start = dto.startsAt
        g.end = dto.endsAt
        g.capacity = dto.capacity
        g.bring = dto.bring
        g.recurring = dto.recurring
        g.hostName = dto.isMine ? "You" : dto.hostName
        g.isMine = dto.isMine
        g.isJoined = dto.isJoined
        g.othersGoing = max(0, dto.going - (dto.isJoined ? 1 : 0))
        if let at = dto.checkedInAt { g.checkedInAt = at }
        g.friendIDs = dto.friendsGoing?.map(\.id) ?? []
        g.webNames = dto.webNames ?? []
    }

    private static func insertKitchen(_ dto: KitchenDTO, context: ModelContext) -> Kitchen {
        let k = Kitchen(
            name: dto.name, cookName: dto.cookName, cuisine: dto.cuisine, story: dto.story,
            coordinate: .init(latitude: dto.lat, longitude: dto.lon), pickupNote: "",
            porchTables: dto.porchTables, isMine: dto.isMine
        )
        k.remoteID = dto.id
        context.insert(k)
        return k
    }

    private static func update(_ k: Kitchen, from dto: KitchenDTO, context: ModelContext) {
        k.name = dto.name
        k.cookName = dto.isMine ? "You" : dto.cookName
        k.cuisine = dto.cuisine
        k.story = dto.story
        k.latitude = dto.lat
        k.longitude = dto.lon
        k.porchTables = dto.porchTables
        k.isMine = dto.isMine
        // The server only says whether both are confirmed. Your own boxes stay as you ticked them.
        if !dto.isMine || dto.permitted {
            k.permitConfirmed = dto.permitted
            k.handlerCardConfirmed = dto.permitted
        }
        // The server's rating already includes any review you posted from here,
        // so take your local ones back out of the base.
        let localStars = k.reviews.reduce(0) { $0 + $1.stars }
        k.baseReviewCount = max(0, dto.reviewCount - k.reviews.count)
        k.baseRatingTotal = max(0, (dto.rating ?? 0) * Double(dto.reviewCount) - Double(localStars))
        if let note = dto.pickupNote { k.pickupNote = note }
        if let table = dto.table {
            k.tableSeats = table.seats
            k.tableTaken = table.taken
            k.tableFriends = table.friends.map { TableSeat(personID: $0.id, name: $0.displayName, at: $0.pickupAt) }
        }
        if let reviews = dto.reviews {
            k.sampleReviews = reviews.map {
                SampleReview(stars: $0.stars, text: $0.text, author: $0.authorName,
                             daysAgo: max(0, Calendar.current.dateComponents([.day], from: $0.createdAt, to: .now).day ?? 0))
            }
        }
        if let menu = dto.menu {
            let existing = Dictionary(k.menu.compactMap { m in m.remoteID.map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
            let keep = Set(menu.map(\.id))
            for (i, m) in menu.enumerated() {
                let item = existing[m.id] ?? {
                    let new = MenuItem(name: m.name, priceCents: m.priceCents, sortIndex: i)
                    new.remoteID = m.id
                    context.insert(new)
                    new.kitchen = k
                    return new
                }()
                item.name = m.name
                item.note = m.note
                item.priceCents = m.priceCents
                item.sortIndex = i
            }
            for item in k.menu where item.remoteID.map({ !keep.contains($0) }) ?? false { context.delete(item) }
        }
        if let d = dto.nextDrop {
            let drop = k.drops.first { $0.remoteID == d.id } ?? {
                let new = Drop(start: d.startsAt, end: d.endsAt, total: d.total)
                new.remoteID = d.id
                context.insert(new)
                new.kitchen = k
                return new
            }()
            drop.start = d.startsAt
            drop.end = d.endsAt
            drop.total = d.total
            drop.sold = d.sold
            drop.perSlot = d.perSlot
        }
    }

    static func fetch<T: PersistentModel>(_ context: ModelContext, _ d: FetchDescriptor<T>) -> [T] {
        do {
            return try context.fetch(d)
        } catch {
            log.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
