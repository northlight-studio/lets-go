import Foundation

/// Wren's one line on the map, and the small numbers around the pins: how full a
/// thing is, how fast its pin pulses, when to leave. Plain functions, so they're tested.
enum HomeLine {
    /// Wren's sentence, in three parts so the view can color the middle.
    struct Line: Equatable, Sendable {
        var lead: String
        var emphasis: String = ""
        var tail: String = ""

        var text: String { lead + emphasis + tail }
    }

    // MARK: Filling up

    /// How full it is, 0...1. Nil when there's no cap and no batch to fill.
    static func fill(_ c: Candidate) -> Double? {
        if c.capacity > 0 { return min(1, Double(c.going) / Double(c.capacity)) }
        if let total = c.dropTotal, let left = c.dropLeft, total > 0 { return min(1, Double(total - left) / Double(total)) }
        return nil
    }

    /// Seconds per pulse: 3.4 when empty, down to 1.7 when it's nearly gone.
    /// Open-ended things pulse slowly. A full one doesn't pulse at all (nil).
    static func pulsePeriod(_ c: Candidate) -> Double? {
        if c.spotsLeft == 0 || c.dropLeft == 0 { return nil }
        guard let f = fill(c) else { return 3.4 }
        return 3.4 - 1.7 * f
    }

    /// Two rings instead of one when it's three-quarters full.
    static func isFillingFast(_ c: Candidate) -> Bool { (fill(c) ?? 0) >= 0.75 && pulsePeriod(c) != nil }

    /// The little count on a pin: "4/6", "16 left", "14".
    static func badge(_ c: Candidate) -> String? {
        if c.capacity > 0 { return "\(c.going)/\(c.capacity)" }
        if let left = c.dropLeft { return "\(left) left" }
        if c.going > 0 { return "\(c.going)" }
        return nil
    }

    /// "Trivia", "Kenji's curry": short enough to sit under a pin.
    static func caption(_ c: Candidate) -> String {
        let base: String
        if c.kind == .drop {
            base = c.title
        } else {
            base = c.title.split(separator: ",").first.map(String.init) ?? c.title
        }
        return base.count > 20 ? String(base.prefix(18)).trimmingCharacters(in: .whitespaces) + "…" : base
    }

    // MARK: Leaving

    /// When to leave to walk in at the start, to the minute. Something already on: now.
    static func leaveBy(_ c: Candidate, now: Date, walkMinutes: Int? = nil) -> Date {
        let minutes = walkMinutes ?? c.walkMinutes
        let leave = c.start.addingTimeInterval(-Double(minutes) * 60)
        guard leave > now else { return now }
        let whole = (leave.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        return Date(timeIntervalSinceReferenceDate: whole)
    }

    // MARK: Wren's pick

    /// The line under the pick's title: "4 of 6 in · 6-minute walk · leave by 6:40 PM".
    /// Already on: "On now" instead of when to leave. `walkMinutes` is a real route's.
    static func meta(
        for c: Candidate, now: Date, walkMinutes: Int? = nil,
        clock: (Date) -> String = HomeLine.clock
    ) -> String {
        var parts: [String] = []
        switch c.kind {
        case .gathering:
            if c.capacity > 0 { parts.append("\(c.going) of \(c.capacity) in") }
            else if c.going > 0 { parts.append("\(c.going) going") }
        case .drop:
            if let left = c.dropLeft, let total = c.dropTotal, total > 0 { parts.append("\(left) of \(total) left") }
        }
        let walk = walkMinutes ?? c.walkMinutes
        parts.append("\(walk)-minute walk")
        if c.start <= now {
            parts.append(c.kind == .drop ? "open till \(clock(c.end))" : "on now")
        } else {
            parts.append("leave by \(clock(leaveBy(c, now: now, walkMinutes: walk)))")
        }
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// Faces after the friends shown: "+2" for the others who are in. Nil when there are none.
    static func others(_ c: Candidate, friendsShown: Int) -> String? {
        let rest = c.going - friendsShown - (c.isJoined ? 1 : 0)
        return rest > 0 ? "+\(rest)" : nil
    }

    /// The search capsule over the map: "Tonight, nearby".
    static func searchPrompt(_ window: TimeWindow, inCity: Bool) -> String {
        let when = switch window {
        case .now: "Right now"
        case .tonight: "Tonight"
        case .weekend: "This weekend"
        }
        return "\(when), \(inCity ? "in the city" : "nearby")"
    }

    // MARK: Wren's line

    /// What Wren says about the top pick. With friends going, it leads with them, and with a
    /// meet-up it says who you'll walk in with. `clock` formats times ("7:42 PM").
    static func sentence(
        for c: Candidate, now: Date, friends: [Friend] = [], meet: MeetUp? = nil,
        clock: (Date) -> String = HomeLine.clock
    ) -> Line {
        let live = c.start <= now
        let walk = c.walkMinutes
        if c.kind == .gathering, !friends.isEmpty {
            let who = Crowd.names(friends)
            let verb = friends.count == 1 ? "is" : "are"
            let at = c.place.isEmpty ? "" : " at \(c.place)"
            let what = c.title.lowercasedFirst
            let lead = live ? "\(who) \(verb) at \(what)\(at)" : "\(who) \(verb) going to \(what)\(at)"
            let tail: String
            if let meet, !live {
                tail = " Leave at \(clock(meet.leave)) and you'll walk in with \(meet.friendName)."
            } else if live {
                tail = " It's a \(walk)-minute walk."
            } else {
                tail = " Leave at \(clock(leaveBy(c, now: now))) to get there for the start."
            }
            if let spots = c.spotsLeft, spots > 0, spots <= 3 {
                return Line(lead: lead + ", and ", emphasis: spots == 1 ? "they need one more." : "they need \(number(spots)).", tail: tail)
            }
            return Line(lead: lead + ".", tail: tail)
        }
        switch c.kind {
        case .drop:
            let lead = live
                ? "\(c.title) is open till \(clock(c.end)), \(walk) minutes from you. "
                : "\(c.title) opens at \(clock(c.start)), \(walk) minutes from you. "
            if let left = c.dropLeft, let total = c.dropTotal, total > 0, left <= 10 || Double(left) / Double(total) < 0.5 {
                return Line(lead: lead, emphasis: "\(left) of \(total) left.", tail: live ? "" : " Leave at \(clock(leaveBy(c, now: now))).")
            }
            return Line(lead: lead, tail: live ? "Walk over while it's warm." : "Leave at \(clock(leaveBy(c, now: now))).")
        case .gathering:
            let at = c.place.isEmpty ? "" : " at \(c.place)"
            let lead = live ? "\(c.title)\(at) is on now" : "\(c.title)\(at) starts at \(clock(c.start))"
            let tail = live
                ? " It's a \(walk)-minute walk."
                : " Leave at \(clock(leaveBy(c, now: now))) and you'll walk in on time."
            if let spots = c.spotsLeft, spots > 0, spots <= 3 {
                return Line(lead: lead + ", and ", emphasis: spots == 1 ? "they need one more." : "they need \(number(spots)).", tail: tail)
            }
            if c.going >= 8 {
                return Line(lead: lead + ". ", emphasis: "\(c.going) people are going.", tail: tail)
            }
            return Line(lead: lead + ".", tail: tail)
        }
    }

    /// When nothing is close enough to suggest.
    static let quiet = Line(lead: "Quiet out there right now. ", emphasis: "Try Tonight or the weekend,", tail: " or start something and people nearby will see it.")

    nonisolated static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    static func number(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return n >= 0 && n < words.count ? words[n] : "\(n)"
    }
}

/// The quick-decide mode: the three things worth leaving for, when to leave for each,
/// and a ruler of the next few hours.
enum Signal {
    /// How far the ruler looks ahead, in hours.
    static let span: Double = 5

    static func top(_ shown: [Candidate], limit: Int = 3) -> [Candidate] {
        Array(shown.filter { $0.spotsLeft != 0 && $0.dropLeft != 0 }.prefix(limit))
    }

    /// Where a time sits on the ruler, 0 (now) to 1 (`span` hours on). Nil past the end.
    static func position(of date: Date, now: Date) -> Double? {
        let hours = date.timeIntervalSince(now) / 3600
        if hours > span { return nil }
        return max(0, hours / span)
    }

    /// The whole hours after now that get a tick on the ruler.
    static func hourTicks(now: Date, calendar: Calendar = .current) -> [Date] {
        guard let next = calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) else { return [] }
        return (0..<Int(span)).compactMap { calendar.date(byAdding: .hour, value: $0, to: next) }
            .filter { $0.timeIntervalSince(now) <= span * 3600 }
    }

    /// "Starts 7:30 · free · 16 min walk", or "On till 9 · 4/6 · 5 min walk".
    static func detail(_ c: Candidate, now: Date, clock: (Date) -> String = HomeLine.clock) -> String {
        var parts = [c.start <= now ? "On till \(clock(c.end))" : "Starts \(clock(c.start))"]
        if let badge = HomeLine.badge(c), c.kind == .gathering, c.capacity > 0 { parts.append(badge) }
        else if c.isFree { parts.append("free") }
        else if let price = c.priceFromCents { parts.append("from \(Pricing.format(price))") }
        parts.append(Walk.label(c.meters))
        return parts.joined(separator: " · ")
    }
}
