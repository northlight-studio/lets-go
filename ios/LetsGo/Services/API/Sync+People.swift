import Foundation
import SwiftData
import CoreLocation

/// What you're up for (it used to be the porch light), as this phone knows it. The server has the shared copy.
enum MyPorchLight {
    static let untilKey = "porch.until"
    static let noteKey = "porch.note"
    static let activityKey = "porch.activity"
    /// Two hours unless you pick otherwise.
    static let hours: Double = UpFor.defaultHours

    static var until: Date? {
        let t = UserDefaults.standard.double(forKey: untilKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static var activity: String { UserDefaults.standard.string(forKey: activityKey) ?? "" }
    static var words: String { UserDefaults.standard.string(forKey: noteKey) ?? "" }

    static func set(until: Date?, note: String = "", activity: String = "") {
        UserDefaults.standard.set(until?.timeIntervalSince1970 ?? 0, forKey: untilKey)
        UserDefaults.standard.set(note, forKey: noteKey)
        UserDefaults.standard.set(activity, forKey: activityKey)
    }
}

/// Friends, crews, porch lights and invites. Friends live on the server; this phone keeps a copy.
extension Sync {
    // MARK: Pull

    static func refreshPeople(around c: CLLocationCoordinate2D, context: ModelContext) async throws(APIError) {
        let dto: PeopleDTO = try await api.send(.get("/v1/people", query: [
            URLQueryItem(name: "lat", value: String(c.latitude)),
            URLQueryItem(name: "lon", value: String(c.longitude)),
        ]))
        apply(dto, context: context)
    }

    static func apply(_ dto: PeopleDTO, context: ModelContext) {
        let local = fetch(context, FetchDescriptor<Person>())
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Invites carry a gathering; make sure it's on the phone so the invite can open it.
        let remoteGatherings = fetch(context, FetchDescriptor<Gathering>(predicate: #Predicate { $0.remoteID != nil }))
        var gatherings = Dictionary(remoteGatherings.compactMap { g in g.remoteID.map { ($0, g) } }, uniquingKeysWith: { a, _ in a })
        for g in gatherings.values { g.invitedBy = "" }
        for invite in dto.invites {
            let d = invite.gathering
            let g: Gathering
            if let found = gatherings[d.id] {
                g = found
            } else {
                g = Gathering(
                    title: d.title, category: Genre(rawValue: d.genre) ?? .party, placeName: d.placeName,
                    coordinate: .init(latitude: d.lat, longitude: d.lon), start: d.startsAt, end: d.endsAt, hostName: d.hostName
                )
                g.remoteID = d.id
                context.insert(g)
                gatherings[d.id] = g
            }
            update(g, from: d)
            g.invitedBy = invite.sender.displayName
        }

        for f in dto.friends {
            let p = byID.removeValue(forKey: f.id) ?? {
                let new = Person(id: f.id, name: f.displayName)
                context.insert(new)
                return new
            }()
            p.name = f.displayName
            if let up = f.upFor {
                p.porchUntil = up.until
                p.porchNote = up.label
                p.upActivity = up.activity
                p.upWalkMinutes = up.walkMin
            } else {
                p.porchUntil = f.porchLight?.onUntil
                p.porchNote = f.porchLight?.note ?? ""
                p.upActivity = ""
                p.upWalkMinutes = f.porchLight?.distanceM.map { Walk.minutes($0) }
            }
            // Nobody's position comes from what they're up for; only a gathering they checked in to places them.
            p.latitude = nil
            p.longitude = nil
            p.wavedAt = f.wavedAt
            if let out = f.out {
                p.outStateRaw = out.state
                p.outTitle = out.title
                p.outPlace = out.placeName
                p.outStart = out.startsAt
                p.outGatheringID = gatherings[out.gatheringId]?.id
                p.outLatitude = out.lat
                p.outLongitude = out.lon
                if out.state == Friend.OutState.there.rawValue {
                    p.latitude = out.lat
                    p.longitude = out.lon
                }
            } else {
                p.outStateRaw = ""
                p.outGatheringID = nil
            }
        }
        // No longer friends.
        for p in byID.values { context.delete(p) }

        // Crews: the server's list replaces the phone's.
        for c in fetch(context, FetchDescriptor<Crew>()) { context.delete(c) }
        let friendIDs = Set(dto.friends.map(\.id))
        for c in dto.crews {
            let crew = Crew(id: c.id, name: c.name, memberIDs: c.members.map(\.id).filter { friendIDs.contains($0) }, isMine: c.isMine)
            if let next = c.next {
                crew.nextTitle = next.title
                crew.nextStart = next.startsAt
                crew.nextGatheringID = gatherings[next.gatheringId]?.id
            }
            context.insert(crew)
        }

        // Third time's a friend: the server's list replaces the phone's.
        if let intros = dto.intros {
            var youWaved: [UUID: Date] = [:]
            for i in fetch(context, FetchDescriptor<Intro>()) {
                if let at = i.youWavedAt { youWaved[i.id] = at }
                context.delete(i)
            }
            for i in intros {
                let intro = Intro(
                    id: i.person.id, name: i.person.displayName,
                    together: i.together.map { SharedNight(title: $0.title, startsAt: $0.startsAt) }, saidHi: i.saidHi
                )
                intro.upUntil = i.upFor?.until
                intro.upActivity = i.upFor?.activity ?? ""
                intro.upLabel = i.upFor?.label ?? ""
                intro.upWalkMinutes = i.upFor?.walkMin
                intro.wavedAt = i.wavedAt
                intro.youWavedAt = youWaved[i.person.id]
                context.insert(intro)
            }
        }

        if let up = dto.upFor {
            MyPorchLight.set(until: up.until, note: up.words, activity: up.activity)
        } else {
            MyPorchLight.set(until: dto.porchLight?.onUntil, note: dto.porchLight?.note ?? "")
        }
        apply(match: dto.meetup, context: context)
        Ledger.save(context, "apply people")
    }

    /// The server's meet-up replaces the phone's; none means it's over.
    static func apply(match dto: MeetupDTO?, context: ModelContext) {
        let local = fetch(context, FetchDescriptor<UpMatch>())
        for m in local where m.id != dto?.id { context.delete(m) }
        guard let dto else { return }
        let m = local.first(where: { $0.id == dto.id }) ?? {
            let new = UpMatch(
                id: dto.id, otherID: dto.other.id, otherName: dto.other.displayName, isMine: dto.isMine,
                activity: dto.activity, label: dto.label, headline: dto.headline, meetAt: dto.meetAt, endsAt: dto.endsAt
            )
            context.insert(new)
            return new
        }()
        m.otherName = dto.other.displayName
        m.headline = dto.headline
        m.label = dto.label
        m.spotName = dto.spot?.name ?? ""
        m.spotLatitude = dto.spot?.lat
        m.spotLongitude = dto.spot?.lon
        m.areaLatitude = dto.area?.lat
        m.areaLongitude = dto.area?.lon
        m.meetAt = dto.meetAt
        m.endsAt = dto.endsAt
        m.myWalkMinutes = dto.myWalkMin
        m.theirWalkMinutes = dto.theirWalkMin
        m.iAmOnMyWay = dto.iAmOnMyWay
        m.theyAreOnTheirWay = dto.theyAreOnTheirWay
        m.theySay = dto.theySay
    }

    // MARK: Friends

    static func friendCode() async throws(APIError) -> FriendCodeDTO {
        try await api.send(.post("/v1/friends/code"))
    }

    /// Accept a code someone gave you. Returns who you're now friends with.
    static func accept(code: String, around c: CLLocationCoordinate2D, context: ModelContext) async throws(APIError) -> String {
        let friend: PersonDTO = try await api.send(.post("/v1/friends/accept", AcceptCodeDTO(code: code)))
        try await refreshPeople(around: c, context: context)
        return friend.displayName
    }

    static func unfriend(_ p: Person, context: ModelContext) async throws(APIError) {
        let _: Empty = try await api.send(.delete("/v1/friends/\(p.id.uuidString)"))
        context.delete(p)
        Ledger.save(context, "unfriend")
    }

    static func wave(_ p: Person, context: ModelContext) async throws(APIError) {
        let _: Empty = try await api.send(.post("/v1/friends/\(p.id.uuidString)/wave"))
        p.youWavedAt = .now
        Ledger.save(context, "wave")
    }

    /// Someone you've met three times, to say hi.
    static func wave(_ intro: Intro, context: ModelContext) async throws(APIError) {
        let _: Empty = try await api.send(.post("/v1/friends/\(intro.id.uuidString)/wave"))
        intro.youWavedAt = .now
        Ledger.save(context, "wave at someone met")
    }

    // MARK: Third time's a friend

    /// Say hi. Returns true when they already had, and you're friends now.
    @discardableResult
    static func sayHi(_ intro: Intro, around c: CLLocationCoordinate2D, context: ModelContext) async throws(APIError) -> Bool {
        let result: IntroResultDTO = try await api.send(.post("/v1/intros/\(intro.id.uuidString)/hi"))
        intro.saidHi = true
        Ledger.save(context, "say hi")
        if result.connected { try await refreshPeople(around: c, context: context) }
        return result.connected
    }

    static func notNow(_ intro: Intro, context: ModelContext) async throws(APIError) {
        let _: Empty = try await api.send(.post("/v1/intros/\(intro.id.uuidString)/not-now"))
        intro.dismissed = true
        intro.saidHi = false
        Ledger.save(context, "not now")
    }

    // MARK: Up for something

    /// Say what you're up for, for a few hours. Where you are goes to the server only, so friends see
    /// how far a walk it is. Returns when it goes off.
    @discardableResult
    static func upFor(activity: String, words: String, hours: Double, at c: CLLocationCoordinate2D?) async throws(APIError) -> Date {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard APIConfig.isConfigured else { throw .notConfigured }
        do {
            let dto: UpForDTO = try await api.send(.put("/v1/me/up-for", UpForInDTO(
                activity: activity, words: trimmed, hours: hours, lat: c?.latitude, lon: c?.longitude
            )))
            MyPorchLight.set(until: dto.until, note: dto.words, activity: dto.activity)
            return dto.until
        } catch .rejected(status: 404, _) {
            // A server from before the rename: the porch light carries the same thing, in words.
            let note = trimmed.isEmpty ? UpFor.label(activity: activity, words: "") : trimmed
            let dto: PorchLightDTO = try await api.send(.put("/v1/me/porch-light", PorchLightInDTO(
                hours: hours, note: note, lat: c?.latitude, lon: c?.longitude
            )))
            MyPorchLight.set(until: dto.onUntil, note: trimmed, activity: activity)
            return dto.onUntil
        }
    }

    static func upForOff() async throws(APIError) {
        if APIConfig.isConfigured {
            let _: Empty = try await api.send(.delete("/v1/me/porch-light"))
        }
        MyPorchLight.set(until: nil)
    }

    /// The old switch, kept for anything still asking for it.
    @discardableResult
    static func porchLight(on: Bool, note: String = "", at c: CLLocationCoordinate2D?) async throws(APIError) -> Date? {
        if on { return try await upFor(activity: "", words: note.isEmpty ? "Up for something" : note, hours: MyPorchLight.hours, at: c) }
        try await upForOff()
        return nil
    }

    // MARK: I'm in

    /// I'm in on what they're up for: a meet-up about halfway. Their own phone never learns where you
    /// are; the server works out the walk times.
    static func imIn(_ personID: UUID, at c: CLLocationCoordinate2D?, context: ModelContext) async throws(APIError) {
        let dto: MeetupDTO = try await api.send(.post("/v1/up-for/\(personID.uuidString)/in", ImInDTO(lat: c?.latitude, lon: c?.longitude)))
        apply(match: dto, context: context)
        Ledger.save(context, "i'm in")
    }

    /// Where you are now (so the walk times stay right), On my way, or a short reply.
    static func update(_ m: UpMatch, at c: CLLocationCoordinate2D? = nil, onMyWay: Bool? = nil, says: String? = nil,
                       context: ModelContext) async throws(APIError) {
        do {
            let dto: MeetupDTO = try await api.send(.patch("/v1/meetups/\(m.id.uuidString)", MeetupUpdateDTO(
                lat: c?.latitude, lon: c?.longitude, onMyWay: onMyWay, says: says
            )))
            apply(match: dto, context: context)
            if let says { m.iSaid = says }
        } catch .rejected(status: 404, _) {
            // The other one tapped Done, or it ran out.
            context.delete(m)
        }
        Ledger.save(context, "update meet-up")
    }

    static func setSpot(_ m: UpMatch, _ place: MeetSpot.Place, context: ModelContext) async throws(APIError) {
        let dto: MeetupDTO = try await api.send(.put("/v1/meetups/\(m.id.uuidString)/spot", SpotDTO(
            name: place.name, lat: place.latitude, lon: place.longitude
        )))
        apply(match: dto, context: context)
        Ledger.save(context, "meet-up spot")
    }

    /// Either of you ends it, and where you both were is wiped on the server.
    static func done(_ m: UpMatch, context: ModelContext) async throws(APIError) {
        do {
            let _: Empty = try await api.send(.post("/v1/meetups/\(m.id.uuidString)/done"))
        } catch .rejected(status: 404, _) {
            // Already over.
        }
        context.delete(m)
        Ledger.save(context, "meet-up done")
    }

    // MARK: Invites and crews

    /// Ask friends along, through the server; the gathering has to live there. Returns how many were asked.
    @discardableResult
    static func invite(_ people: [Person], to g: Gathering, context: ModelContext) async throws(APIError) -> Int {
        var asked = 0
        if let id = g.remoteID, !people.isEmpty {
            let dto: InvitedDTO = try await api.send(.post(
                "/v1/gatherings/\(id.uuidString)/invites", InviteFriendsDTO(userIds: people.map(\.id))
            ))
            asked += dto.invited
        } else if !people.isEmpty {
            // Only on this phone: nobody else can see it yet.
            throw .rejected(status: 409, reason: "This one isn't on the server, so friends can't be invited to it yet.")
        }
        Ledger.save(context, "invite")
        return asked
    }

    static func makeCrew(_ name: String, members: [Person], context: ModelContext) async throws(APIError) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if APIConfig.isConfigured, !members.isEmpty {
            let dto: CrewDTO = try await api.send(.post("/v1/crews", NewCrewDTO(name: trimmed, memberIds: members.map(\.id))))
            context.insert(Crew(id: dto.id, name: dto.name, memberIDs: members.map(\.id), isMine: true))
        } else {
            // No server to keep it: it stays on this phone.
            context.insert(Crew(name: trimmed, memberIDs: members.map(\.id), isMine: true))
        }
        Ledger.save(context, "make crew")
    }

    static func leave(_ crew: Crew, context: ModelContext) async throws(APIError) {
        if APIConfig.isConfigured {
            let _: Empty = try await api.send(.delete("/v1/crews/\(crew.id.uuidString)"))
        }
        context.delete(crew)
        Ledger.save(context, "leave crew")
    }
}
