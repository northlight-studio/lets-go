import Foundation

/// The words at the top of a gathering's page: when, where and the walk, the friend on
/// the way, and what Share sends. Plain functions, so they're tested.
enum GatheringLine {
    /// Over the title: "Thursday · 6:45 PM", "Tonight · 6:45 PM", "On now · till 9:00 PM".
    static func eyebrow(start: Date, end: Date, now: Date, calendar: Calendar = .current,
                        clock: (Date) -> String = HomeLine.clock) -> String {
        if start <= now, now < end { return "On now · till \(clock(end))" }
        let day: String
        if calendar.isDate(start, inSameDayAs: now) {
            day = calendar.component(.hour, from: start) >= 17 ? "Tonight" : "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else {
            day = start.formatted(.dateTime.weekday(.wide))
        }
        return "\(day) · \(clock(start))"
    }

    /// Under the title: "By the tennis courts · 6-minute walk".
    static func whereLine(place: String, meters: Double) -> String {
        let walk = "\(Walk.minutes(meters))-minute walk"
        return place.isEmpty ? walk : "\(place) · \(walk)"
    }

    /// The card when a friend is on their way: "Maya's on the way" and
    /// "Two minutes from you. Leave at 6:32 PM and walk in together?"
    static func onTheWay(_ meet: MeetUp, clock: (Date) -> String = HomeLine.clock) -> (title: String, detail: String) {
        let minutes = max(1, Int((meet.meetAt.timeIntervalSince(meet.leave) / 60).rounded()))
        let away = minutes == 1 ? "A minute from you" : "\(HomeLine.number(minutes).capitalizedFirst) minutes from you"
        return ("\(meet.friendName)'s on the way", "\(away). Leave at \(clock(meet.leave)) and walk in together?")
    }

    /// What Share sends: "Pickup soccer, Thursday · 6:45 PM at Dolores Park", and the
    /// poster's link when there is one.
    static func share(title: String, eyebrow: String, place: String, link: String?) -> String {
        var text = "\(title), \(eyebrow)"
        if !place.isEmpty { text += " at \(place)" }
        if let link { text += "\n\(link)" }
        return text
    }
}

extension String {
    /// "two" → "Two".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
