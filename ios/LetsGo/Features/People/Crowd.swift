import Foundation
import CoreLocation

/// Where your people are tonight, and how to end up with them. Plain functions, so they're tested.
/// Friends are wherever the server says they joined; nobody is placed anywhere they didn't say.
enum Crowd {
    /// Friends going to this: on its list from the server, or out heading there.
    static func going(to c: Candidate, among friends: [Friend]) -> [Friend] {
        friends.filter { c.friendIDs.contains($0.id) || $0.out?.gatheringID == c.id }
    }

    /// Out now: there first, then heading, soonest first.
    static func outNow(_ friends: [Friend]) -> [Friend] {
        friends.filter { $0.out != nil }.sorted { a, b in
            let ra = a.out?.state == .there ? 0 : 1, rb = b.out?.state == .there ? 0 : 1
            if ra != rb { return ra < rb }
            return (a.out?.start ?? .distantFuture) < (b.out?.start ?? .distantFuture)
        }
    }

    static func porchLights(_ friends: [Friend], now: Date) -> [Friend] {
        friends.filter { $0.porchOn(at: now) && $0.out == nil }.sorted { ($0.porchUntil ?? now) > ($1.porchUntil ?? now) }
    }

    /// "Maya", "Maya and Theo", "Maya, Theo and Jun", "Maya, Theo and 2 others".
    static func names(_ friends: [Friend]) -> String {
        let first = friends.map(\.firstName)
        switch first.count {
        case 0: return ""
        case 1: return first[0]
        case 2: return "\(first[0]) and \(first[1])"
        case 3: return "\(first[0]), \(first[1]) and \(first[2])"
        default: return "\(first[0]), \(first[1]) and \(first.count - 2) others"
        }
    }

    /// Where a friend's porch light or night puts them on the map, if anywhere.
    static func mapped(_ friends: [Friend], now: Date) -> [Friend] {
        friends.filter { $0.coordinate != nil && ($0.out != nil || $0.porchOn(at: now)) }
    }
}

/// Wren routing your walk past a friend who's heading to the same thing.
struct MeetUp: Equatable, Sendable {
    var friendID: UUID
    var friendName: String
    /// When you leave.
    var leave: Date
    /// When you meet them, on their way.
    var meetAt: Date
    var latitude: Double
    var longitude: Double
    /// How much longer than walking straight there.
    var extraMinutes: Int

    /// Worth suggesting when going via them costs at most a third more walking (or a couple of
    /// blocks) and there's still time. They're walking from where they are now.
    static func plan(here: CLLocationCoordinate2D, friend: Friend, to destination: CLLocationCoordinate2D,
                     start: Date, now: Date) -> MeetUp? {
        guard friend.out?.state == .heading, let p = friend.coordinate else { return nil }
        let direct = here.distance(to: destination)
        let toFriend = here.distance(to: p)
        let onward = p.distance(to: destination)
        guard toFriend + onward <= direct * 1.35 + 160 else { return nil }
        let meetAt = start.addingTimeInterval(-Double(Walk.minutes(onward)) * 60)
        let leaveRaw = meetAt.addingTimeInterval(-Double(Walk.minutes(toFriend)) * 60)
        let whole = (leaveRaw.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        let leave = Date(timeIntervalSinceReferenceDate: whole)
        guard leave > now else { return nil }
        let extra = max(0, Walk.minutes(toFriend + onward) - Walk.minutes(direct))
        return MeetUp(friendID: friend.id, friendName: friend.firstName, leave: leave, meetAt: meetAt,
                      latitude: p.latitude, longitude: p.longitude, extraMinutes: extra)
    }

    /// The first heading friend it's worth walking past.
    static func best(here: CLLocationCoordinate2D, friends: [Friend], to c: Candidate, now: Date) -> MeetUp? {
        let there = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
        return friends.lazy.compactMap { plan(here: here, friend: $0, to: there, start: c.start, now: now) }.first
    }
}
