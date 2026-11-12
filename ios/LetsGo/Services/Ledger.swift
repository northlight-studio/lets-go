import Foundation
import SwiftData
import OSLog

/// The things you do that change what the app knows about you:
/// joining, checking in, ordering, reviewing, hosting. Each one saves,
/// awards any stamp it earned, and learns a little about what you like.
enum Ledger {
    private static let log = Logger(subsystem: "com.yasser100ali.letsgo", category: "ledger")

    /// True when it saved.
    @discardableResult
    static func save(_ context: ModelContext, _ what: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            log.error("Save failed (\(what, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Gatherings

    static func join(_ g: Gathering, context: ModelContext) {
        g.isJoined = true
        learn("into:\(g.category.rawValue)", "Into \(g.category.noun)", g.category, context: context)
        save(context, "join")
    }

    static func leave(_ g: Gathering, context: ModelContext) {
        g.isJoined = false
        save(context, "leave")
    }

    /// Returns the stamp earned, if this check-in earned a new one.
    @discardableResult
    static func checkIn(_ g: Gathering, context: ModelContext, now: Date = .now) -> Stamp? {
        g.isJoined = true
        g.checkedInAt = now
        let earned = award(
            key: "place:\(g.placeName.lowercased())",
            title: g.placeName,
            symbol: g.category.symbol,
            category: g.category,
            context: context
        )
        let checkIns = count(context, FetchDescriptor<Gathering>(predicate: #Predicate { $0.checkedInAt != nil }))
        if checkIns == 1 {
            award(key: "first-checkin", title: "First show-up", symbol: "figure.wave", category: g.category, context: context)
        }
        if checkIns >= 5 {
            award(key: "checkins-5", title: "Five show-ups", symbol: "star.circle", category: g.category, context: context)
        }
        learn("into:\(g.category.rawValue)", "Into \(g.category.noun)", g.category, context: context)
        save(context, "check-in")
        return earned
    }

    /// Being at a place on the city list. Returns the stamp, the first time.
    @discardableResult
    static func visit(_ spot: Spot, context: ModelContext) -> Stamp? {
        let earned = award(key: spot.stampKey, title: spot.title, symbol: spot.kind.symbol, category: spot.kind.genre, context: context)
        learn("spot:\(spot.kind.rawValue)", "Into \(spot.kind.noun)", spot.kind.genre, context: context)
        save(context, "visit")
        return earned
    }

    static func host(_ g: Gathering, context: ModelContext) {
        context.insert(g)
        award(key: "first-host", title: "Hosted one", symbol: "flag.fill", category: g.category, context: context)
        save(context, "host")
    }

    // MARK: Posters

    /// A gathering that's gone: cancelled here, or by its host on the server.
    /// Kept if you showed up, so its stamp keeps a home.
    static func cancel(_ g: Gathering, context: ModelContext) {
        if g.checkedInAt == nil { context.delete(g) } else { g.isJoined = false }
        save(context, "cancel gathering")
    }

    static func poster(_ g: Gathering, code: String, url: String, shortText: String, context: ModelContext) {
        g.posterCode = code
        g.posterURL = url
        g.posterShortText = shortText
        award(key: "first-poster", title: "Put one up", symbol: "doc.richtext", category: g.category, context: context)
        save(context, "poster")
    }

    static func retirePoster(_ g: Gathering, context: ModelContext) {
        g.posterCode = nil
        g.posterURL = nil
        g.posterShortText = nil
        save(context, "retire poster")
    }

    // MARK: Kitchens

    static func reserve(_ order: Order, at kitchen: Kitchen, drop: Drop?, context: ModelContext) {
        context.insert(order)
        order.kitchen = kitchen
        if let drop { drop.sold += order.itemCount }
        learn("eats:\(kitchen.cuisine.lowercased())", "Likes \(kitchen.cuisine.lowercased())", .food, context: context)
        save(context, "reserve")
    }

    @discardableResult
    static func review(_ review: Review, for order: Order, context: ModelContext) -> Stamp? {
        guard let kitchen = order.kitchen else { return nil }
        context.insert(review)
        review.kitchen = kitchen
        order.status = .reviewed
        award(key: "first-review", title: "First review", symbol: "text.bubble.fill", category: .food, context: context)
        var earned: Stamp?
        let visits = kitchen.orders.filter { $0.status != .reserved }.count
        if visits >= 3 {
            earned = award(key: "regular:\(kitchen.id.uuidString)", title: "Regular at \(kitchen.cookName)'s", symbol: "fork.knife", category: .food, context: context)
        }
        save(context, "review")
        return earned
    }

    /// A batch you posted ("Sell something"). The first one is a stamp.
    static func postBatch(_ drop: Drop, at kitchen: Kitchen, context: ModelContext) {
        if drop.kitchen == nil {
            context.insert(drop)
            drop.kitchen = kitchen
        }
        award(key: "first-batch", title: "Sold to the block", symbol: "basket.fill", category: .food, context: context)
        save(context, "post batch")
    }

    /// An order's payment, code or address changed on the server (paid, picked up).
    static func settle(_ order: Order, context: ModelContext) {
        save(context, "settle order")
    }

    static func follow(_ kitchen: Kitchen, _ on: Bool, followers: Int, context: ModelContext) {
        kitchen.isFollowing = on
        kitchen.followers = followers
        if on { learn("eats:\(kitchen.cuisine.lowercased())", "Likes \(kitchen.cuisine.lowercased())", .food, context: context) }
        save(context, on ? "follow" : "unfollow")
    }

    static func openKitchen(_ kitchen: Kitchen, context: ModelContext) {
        context.insert(kitchen)
        award(key: "opened-kitchen", title: "Opened a kitchen", symbol: "house.fill", category: .food, context: context)
        save(context, "open kitchen")
    }

    // MARK: Nights out

    /// Tonight's night, made when you first show up somewhere.
    static func night(at now: Date = .now, create: Bool, context: ModelContext) -> Night? {
        let evening = NightMath.evening(of: now)
        do {
            if let n = try context.fetch(FetchDescriptor<Night>(predicate: #Predicate { $0.evening == evening })).first { return n }
        } catch {
            log.error("Night fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        guard create else { return nil }
        let n = Night(evening: evening, startedAt: now)
        context.insert(n)
        return n
    }

    /// You showed up: the place goes on tonight's night, with whoever's there with you.
    @discardableResult
    static func arrive(_ title: String, genre: Genre, with friends: [Friend], context: ModelContext, now: Date = .now) -> Night? {
        guard let n = night(at: now, create: true, context: context) else { return nil }
        if !n.stops.contains(where: { $0.title == title }) {
            n.stops.append(NightStop(title: title, genreRaw: genre.rawValue, arrivedAt: now,
                                     withIDs: friends.map(\.id), withNames: friends.map(\.firstName)))
        }
        n.lastActiveAt = now
        save(context, "arrive")
        return n
    }

    /// Steps and phone time only count once a night has started.
    static func walked(_ meters: Double, context: ModelContext, now: Date = .now) {
        guard meters > 0, let n = night(at: now, create: false, context: context) else { return }
        n.walkedMeters += meters
        n.lastActiveAt = now
        save(context, "walked")
    }

    /// Let's Go was open and lit from `since` until now. Only the part after the night began counts.
    static func phoneTime(since: Date, context: ModelContext, now: Date = .now) {
        guard let n = night(at: now, create: false, context: context) else { return }
        let from = max(since, n.startedAt)
        let seconds = now.timeIntervalSince(from)
        guard seconds > 0 else { return }
        n.phoneSeconds += seconds
        if n.glances.last.map({ from.timeIntervalSince($0) > 120 }) ?? true { n.glances.append(from) }
        save(context, "phone time")
    }

    static func goDark(until: Date?, context: ModelContext, now: Date = .now) {
        guard let n = night(at: now, create: false, context: context) else { return }
        n.darkUntil = until
        save(context, "go dark")
    }

    static func sawRecap(_ n: Night, context: ModelContext) {
        n.recapSeenAt = .now
        save(context, "recap seen")
    }

    // MARK: Clean-up

    /// Deletes what has ended and isn't yours (`Upcoming.fate`); what you joined, checked in to or
    /// host stays for your history. Returns when to prune next.
    @discardableResult
    static func pruneEnded(context: ModelContext, now: Date = .now) -> Date {
        var ends: [Date] = []
        var deleted = 0
        do {
            for g in try context.fetch(FetchDescriptor<Gathering>()) {
                switch Upcoming.fate(of: g.upcoming, now: now) {
                case .show: ends.append(g.end)
                case .history: break
                case .delete:
                    context.delete(g)
                    deleted += 1
                }
            }
        } catch {
            log.error("Pruning failed: \(error.localizedDescription, privacy: .public)")
        }
        if deleted > 0 { save(context, "prune ended") }
        return Upcoming.nextPrune(ends: ends, now: now)
    }

    /// Deletes everything the old sample neighborhood stored (`SamplePurge`): its gatherings,
    /// kitchens (with their menus, drops and any orders), people, crews and intros, and the stops
    /// on your nights that were at sample things. A night left with no stops goes too.
    /// True when it all went and saved.
    @discardableResult
    static func clearSamples(context: ModelContext) -> Bool {
        do {
            try context.delete(model: Gathering.self, where: #Predicate { $0.isSample })
            try context.delete(model: Person.self, where: #Predicate { $0.isSample })
            try context.delete(model: Crew.self, where: #Predicate { $0.isSample })
            try context.delete(model: Intro.self, where: #Predicate { $0.isSample })
            // Cascade rules only run for object deletes, so sample kitchens go one by one.
            try context.fetch(FetchDescriptor<Kitchen>(predicate: #Predicate { $0.isSample })).forEach { context.delete($0) }
            for n in try context.fetch(FetchDescriptor<Night>()) where n.stops.contains(where: \.isSample) {
                n.stops.removeAll(where: \.isSample)
                if n.stops.isEmpty { context.delete(n) }
            }
        } catch {
            log.error("Clearing samples failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return save(context, "clear samples")
    }

    // MARK: Stamps and taste

    @discardableResult
    static func award(key: String, title: String, symbol: String, category: Genre, context: ModelContext) -> Stamp? {
        let existing = count(context, FetchDescriptor<Stamp>(predicate: #Predicate { $0.key == key }))
        guard existing == 0 else { return nil }
        let stamp = Stamp(key: key, title: title, symbol: symbol, category: category)
        context.insert(stamp)
        return stamp
    }

    /// Adds something you're into, unless you deleted it before.
    static func learn(_ key: String, _ text: String, _ category: Genre?, context: ModelContext) {
        let existing = count(context, FetchDescriptor<TasteNote>(predicate: #Predicate { $0.key == key }))
        guard existing == 0 else { return }
        context.insert(TasteNote(key: key, text: text, category: category))
    }

    private static func count<T: PersistentModel>(_ context: ModelContext, _ descriptor: FetchDescriptor<T>) -> Int {
        do {
            return try context.fetchCount(descriptor)
        } catch {
            log.error("Count failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}
