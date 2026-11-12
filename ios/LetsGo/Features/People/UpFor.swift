import Foundation
import CoreLocation

/// Up for something (it used to be the porch light): what you can say you're up for, how it
/// reads, who's up for what near you, and where a match meets. Plain functions, so they're tested.
/// Nobody's coordinates come in here from the server: a walk time is all anyone gets.
enum UpFor {
    struct Activity: Identifiable, Hashable, Sendable {
        /// The server's key (`backend/app/upfor.py`).
        var key: String
        var label: String
        var emoji: String
        var id: String { key }
    }

    static let activities: [Activity] = [
        Activity(key: "walk", label: "A walk", emoji: "\u{1F6B6}"),
        Activity(key: "coffee", label: "Coffee", emoji: "\u{2615}"),
        Activity(key: "drink", label: "A drink", emoji: "\u{1F37B}"),
        Activity(key: "pickup", label: "Pickup game", emoji: "\u{1F3C0}"),
        Activity(key: "cooking", label: "Cooking", emoji: "\u{1F373}"),
    ]

    /// Your own words get a sparkle.
    static let ownWordsEmoji = "\u{2728}"

    static func activity(_ key: String) -> Activity? { activities.first { $0.key == key } }

    static func emoji(_ key: String) -> String { activity(key)?.emoji ?? ownWordsEmoji }

    /// "A walk", or your own words.
    static func label(activity key: String, words: String) -> String {
        if let a = activity(key) { return a.label }
        let w = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty ? "Something" : w
    }

    /// The little speech bubble on a pin: "walk?".
    static func bubble(activity key: String, words: String) -> String {
        switch key {
        case "walk": return "walk?"
        case "coffee": return "coffee?"
        case "drink": return "drink?"
        case "pickup": return "game?"
        case "cooking": return "cook?"
        default:
            let first = words.split(separator: " ").first.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
            return first.isEmpty ? "hi?" : "\(first.prefix(10))?"
        }
    }

    /// "Wednesday evening", over the People title.
    static func dayLine(_ now: Date, calendar: Calendar = .current) -> String {
        let weekday = now.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide))
        let hour = calendar.component(.hour, from: now)
        let part = switch hour {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<22: "evening"
        default: "night"
        }
        return "\(weekday) \(part)"
    }

    static let hourChoices: [Double] = [1, 2, 3, 4]
    static let defaultHours: Double = 2

    /// "an hour", "2 hours".
    static func hoursText(_ hours: Double) -> String {
        let h = Int(hours.rounded())
        return h <= 1 ? "an hour" : "\(h) hours"
    }

    /// The one line under the chips.
    static func whoSees(hours: Double) -> String {
        let span = hours <= 1 ? "the next hour" : "the next \(Int(hours.rounded())) hours"
        return "Friends and people you've met see it for \(span)."
    }

    /// While it's on.
    static func whoSees(until: Date, clock: String) -> String {
        "Friends and people you've met see it until \(clock). Nobody sees where you are."
    }

    /// How much longer someone's up for it: "for an hour", "for 20 more minutes".
    static func left(until: Date, now: Date) -> String {
        let minutes = Int(until.timeIntervalSince(now) / 60)
        switch minutes {
        case ..<1: return ""
        case ..<45: return "for \(minutes) more min"
        case ..<90: return "for an hour"
        default: return "for \((minutes + 30) / 60) hours"
        }
    }

    // MARK: Up for something near you

    struct Row: Identifiable, Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// A friend who's up for something: I'm in.
            case friend
            /// Someone you've met three times: I'm in, or Wave.
            case met
            /// Friends heading to or at a gathering: Join.
            case gathering
        }

        var id: String
        var kind: Kind
        /// The person shown, or the first of the friends going.
        var who: Friend
        /// "Maya", or "Theo + 3".
        var name: String
        var emoji: String
        var detail: String
        var walkMinutes: Int?
        var gatheringID: UUID?
        var start: Date?
    }

    /// Friends up for something (closest first), then people you've met, then where friends are going.
    static func rows(friends: [Friend], met: [Friend], metTimes: [UUID: Int] = [:], now: Date) -> [Row] {
        func near(_ a: Row, _ b: Row) -> Bool {
            (a.walkMinutes ?? .max, a.name) < (b.walkMinutes ?? .max, b.name)
        }
        let up = friends.filter { $0.porchOn(at: now) }
        let people = up.map { f in
            Row(id: "f-\(f.id)", kind: .friend, who: f, name: f.firstName, emoji: emoji(f.upActivity),
                detail: detail(f, also: f.upWalkMinutes.map { "\($0) min away" }, now: now), walkMinutes: f.upWalkMinutes)
        }.sorted(by: near)

        let metRows = met.filter { $0.porchOn(at: now) }.map { f in
            let times = metTimes[f.id].map { "met \(HomeLine.number($0)) times" }
            return Row(id: "m-\(f.id)", kind: .met, who: f, name: f.firstName, emoji: emoji(f.upActivity),
                       detail: detail(f, also: times ?? f.upWalkMinutes.map { "\($0) min away" }, now: now),
                       walkMinutes: f.upWalkMinutes)
        }.sorted(by: near)

        // Friends who are out, one row per thing, not counting the ones already up for something.
        let upIDs = Set(up.map(\.id))
        var groups: [String: [Friend]] = [:]
        var order: [String] = []
        for f in Crowd.outNow(friends) where !upIDs.contains(f.id) {
            guard let out = f.out else { continue }
            let key = out.gatheringID?.uuidString ?? "\(out.title)|\(out.place)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(f)
        }
        let going = order.compactMap { key -> Row? in
            guard let fs = groups[key], let first = fs.first, let out = first.out else { return nil }
            let name = fs.count == 1 ? first.firstName : "\(first.firstName) + \(fs.count - 1)"
            let at = out.place.isEmpty ? "" : " at \(out.place)"
            let what = out.state == .there ? "At \(out.title.lowercasedFirst)\(at) now" : "\(out.title)\(at)"
            return Row(id: "g-\(key)", kind: .gathering, who: first, name: name, emoji: "",
                       detail: what, gatheringID: out.gatheringID, start: out.start)
        }
        return people + metRows + going
    }

    private static func detail(_ f: Friend, also: String?, now: Date) -> String {
        [label(activity: f.upActivity, words: f.porchNote), also, left(until: f.porchUntil ?? now, now: now)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
    }
}

/// The words on a match: "You and Maya are going for a walk", where, when, and how far off they are.
enum MatchCopy {
    /// Short replies, for when there's no messaging.
    static let replies = ["Running 5 late", "I'm here", "Can't make it after all"]

    static func lead(spot: String, meetAt: Date, now: Date) -> String {
        guard !spot.isEmpty else { return "Finding somewhere about halfway\u{2026}" }
        let minutes = Int((meetAt.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "Meet at \(spot) now." }
        if minutes < 60 { return "Meet at \(spot) in \(minutes) minute\(minutes == 1 ? "" : "s")." }
        return "Meet at \(spot) at \(HomeLine.clock(meetAt))."
    }

    /// "Maya's 6 minutes away.", "Maya's on the way, 4 minutes out.", "Maya says: I'm here."
    static func them(_ name: String, walk: Int?, onTheirWay: Bool, says: String) -> String {
        if !says.isEmpty { return "\(name) says: \(says)." }
        switch (onTheirWay, walk) {
        case (true, let w?): return "\(name)'s on the way, \(w) minute\(w == 1 ? "" : "s") out."
        case (true, nil): return "\(name)'s on the way."
        case (false, let w?): return "\(name)'s \(w) minute\(w == 1 ? "" : "s") away."
        case (false, nil): return ""
        }
    }

    static let privacy = "Nobody else sees where you are, and you two see only walk times. It ends when either of you taps Done."
}

/// Somewhere real and public to meet, about halfway: a park first (easy to find), then a café.
enum MeetSpot {
    struct Place: Hashable, Sendable {
        var name: String
        var latitude: Double
        var longitude: Double
        var isPark: Bool

        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    /// How far from halfway a spot can be. The server allows more; this keeps it fair.
    static let within: CLLocationDistance = 700
    /// A café has to be this much closer than a park to win.
    static let parkBonus: CLLocationDistance = 150

    static func pick(_ places: [Place], near area: CLLocationCoordinate2D) -> Place? {
        func score(_ p: Place) -> Double { area.distance(to: p.coordinate) - (p.isPark ? parkBonus : 0) }
        return places
            .filter { !$0.name.isEmpty && area.distance(to: $0.coordinate) <= within }
            .min { score($0) < score($1) }
    }
}
