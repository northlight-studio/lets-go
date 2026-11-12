import Foundation
import CoreLocation

/// "something with Maya and Theo saturday", read: who, which day, from and until when,
/// what kind of thing, how much.
struct PlanRequest: Equatable, Sendable {
    var text: String
    var friendIDs: [UUID]
    /// Start of the day the plan is for.
    var day: Date
    /// "at 4", "after 2", "afternoon". Nil means work it out from when people are free.
    var fromHour: Int?
    /// "done by 9", "till 10".
    var untilHour: Int?
    var categories: Set<Genre> = []
    var maxPriceCents: Int?
    var wantsFree = false

    /// Nil when it isn't a plan for people: no friends or crew named, and no "plan".
    static func parse(_ raw: String, friends: [Friend], crews: [(name: String, memberIDs: [UUID])] = [],
                      now: Date, calendar: Calendar = .current) -> PlanRequest? {
        let text = raw.lowercased()
        let folded = text.folding(options: .diacriticInsensitive, locale: nil)
        let words = Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init))

        var ids: [UUID] = []
        for f in friends where words.contains(f.firstName.lowercased().folding(options: .diacriticInsensitive, locale: nil)) {
            ids.append(f.id)
        }
        for crew in crews {
            let name = crew.name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            let key = name.split(separator: " ").filter { $0.count > 3 && $0 != "crew" }
            if folded.contains(name) || (!key.isEmpty && key.allSatisfy { folded.contains($0) }) {
                for id in crew.memberIDs where !ids.contains(id) { ids.append(id) }
            }
        }
        guard !ids.isEmpty || words.contains("plan") else { return nil }

        let q = SearchQuery.parse(raw, now: now, calendar: calendar)
        var r = PlanRequest(
            text: raw, friendIDs: ids, day: day(in: words, query: q, now: now, calendar: calendar),
            fromHour: nil, untilHour: nil, categories: q.categories, maxPriceCents: q.maxPriceCents, wantsFree: q.wantsFree
        )
        if words.contains("cheap") && r.maxPriceCents == nil { r.maxPriceCents = 1500 }
        r.fromHour = hour(after: ["after", "from", "at"], in: folded, eveningUpTo: 7) ?? partOfDay(words)
        // "done by 10" is ten at night; "after 10" could be the morning.
        r.untilHour = hour(after: ["by", "till", "until", "before"], in: folded, eveningUpTo: 11)
        return r
    }

    private static let weekdays = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3, "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thurs": 5, "friday": 6, "fri": 6, "saturday": 7, "sat": 7,
    ]

    private static func day(in words: Set<String>, query: SearchQuery, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        if !words.isDisjoint(with: ["tonight", "today"]) { return today }
        if words.contains("tomorrow") { return calendar.date(byAdding: .day, value: 1, to: today) ?? today }
        var weekday = words.compactMap { weekdays[$0] }.first
        if weekday == nil, words.contains("weekend") { weekday = 7 }
        if let weekday {
            let current = calendar.component(.weekday, from: today)
            var ahead = (weekday - current + 7) % 7
            // "saturday" said late on a Saturday means next week.
            if ahead == 0 && calendar.component(.hour, from: now) >= 20 { ahead = 7 }
            return calendar.date(byAdding: .day, value: ahead, to: today) ?? today
        }
        if let d = query.date { return calendar.startOfDay(for: d) }
        // No day said: today, unless it's already late.
        return calendar.component(.hour, from: now) >= 20 ? (calendar.date(byAdding: .day, value: 1, to: today) ?? today) : today
    }

    private static func partOfDay(_ words: Set<String>) -> Int? {
        if words.contains("morning") { return 9 }
        if words.contains("lunch") { return 12 }
        if words.contains("afternoon") { return 13 }
        if !words.isDisjoint(with: ["evening", "tonight", "dinner"]) { return 18 }
        if words.contains("night") { return 19 }
        return nil
    }

    /// "after 4", "by 9pm", "at 10am": the hour, 24-hour. Without am or pm, hours up to
    /// `eveningUpTo` are taken as the evening.
    private static func hour(after markers: [String], in text: String, eveningUpTo: Int) -> Int? {
        let pattern = "\\b(" + markers.joined(separator: "|") + ")\\s+(\\d{1,2})(?::\\d{2})?\\s*(am|pm)?\\b"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 2), in: text), let h = Int(text[r]), (1...23).contains(h) else { return nil }
        let suffix = Range(m.range(at: 3), in: text).map { String(text[$0]) } ?? ""
        switch suffix {
        case "am": return h == 12 ? 0 : h
        case "pm": return h == 12 ? 12 : h + 12
        default: return h <= eveningUpTo ? h + 12 : h
        }
    }
}

/// A plan Wren put together: stops in order, the walks between them, and what it checked.
struct Plan: Equatable, Sendable {
    struct Stop: Codable, Equatable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable { case food, outside, event }
        var id = UUID()
        var kind: Kind
        var title: String
        var note: String
        var start: Date
        var genre: Genre
        var latitude: Double
        var longitude: Double
        /// The gathering for an event stop, the kitchen for a food stop.
        var gatheringID: UUID?
        var kitchenID: UUID?
        /// From the old sample neighborhood; always false now. Kept because saved plans store stops.
        var isSample = false
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    struct Leg: Codable, Equatable, Sendable {
        var minutes: Int
        var meters: Double
        var note: String
    }

    struct Check: Equatable, Sendable {
        var title: String
        var detail: String
    }

    var day: Date
    /// "Saturday, sorted." or "Halloween, sorted."
    var title: String
    /// "Sat, Oct 31 · Halloween"
    var dayLine: String
    var friendIDs: [UUID]
    var stops: [Stop]
    /// Between stop i and i + 1.
    var legs: [Leg]
    var checks: [Check]
    var reply: String
    var note: String

    var start: Date? { stops.first?.start }
    var meters: Double { legs.reduce(0) { $0 + $1.meters } }
}

/// A kitchen's batch on a given day, as the planner sees it.
struct DropSlot: Equatable, Sendable {
    var kitchenID: UUID
    var name: String
    var cuisine: String
    var start: Date
    var end: Date
    var left: Int
    var priceFromCents: Int?
    var latitude: Double
    var longitude: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// Somewhere outside to be for sunset.
struct OutsideSpot: Equatable, Sendable {
    var title: String
    var area: String
    var latitude: Double
    var longitude: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// Wren's logistics: a time that works for everyone, the thing worth going to, food
/// first if a kitchen has a slot, somewhere outside for sunset if it falls in between,
/// and the walks. Plain function, so it's tested.
enum Planner {
    static func plan(
        _ r: PlanRequest, friends: [Friend], events: [Candidate], drops: [DropSlot], outside: [OutsideSpot],
        here: CLLocationCoordinate2D, sunset: Date?, taste: Taste, excluding: Set<UUID> = [], now: Date,
        calendar: Calendar = .current, clock: (Date) -> String = HomeLine.clock
    ) -> Plan? {
        let group = friends.filter { r.friendIDs.contains($0.id) }
        let size = group.count + 1
        let weekend = calendar.isDateInWeekend(r.day)
        // When everyone's free: the latest known, or what was asked, or a sensible default.
        let known = group.compactMap(\.freeAfterHour)
        let fromHour = r.fromHour ?? max(weekend ? 14 : 18, known.min() ?? 0)
        var from = at(fromHour, on: r.day, calendar: calendar)
        if calendar.isDate(r.day, inSameDayAs: now) { from = max(from, roundUp(now.addingTimeInterval(20 * 60), minutes: 30)) }
        let until = at(r.untilHour ?? 24, on: r.day, calendar: calendar)
        guard from < until else { return nil }

        // The thing worth going to.
        let sameDay = events.filter { c in
            c.kind == .gathering && calendar.isDate(c.start, inSameDayAs: r.day) && (c.spotsLeft ?? size) >= size
                && !excluding.contains(c.id) && c.end > now
        }
        let affordable = sameDay.filter { c in
            if r.wantsFree && !c.isFree { return false }
            // "Under $15" means under $15.
            if let cap = r.maxPriceCents, let price = c.priceFromCents, price > cap { return false }
            return true
        }
        let inWindow = affordable.filter { $0.start >= from && $0.start.addingTimeInterval(3600) <= until }
        guard let event = (inWindow.isEmpty ? affordable.filter { $0.end > from } : inWindow)
            .max(by: { score($0, r, taste: taste, sunset: sunset) < score($1, r, taste: taste, sunset: sunset) })
        else { return nil }

        var stops: [Plan.Stop] = []
        // Food first, if a kitchen has a batch before the event and enough left for everyone.
        let eventAt = CLLocationCoordinate2D(latitude: event.lat, longitude: event.lon)
        let middle = CLLocationCoordinate2D(latitude: (here.latitude + event.lat) / 2, longitude: (here.longitude + event.lon) / 2)
        let food = drops
            .filter { d in
                calendar.isDate(d.start, inSameDayAs: r.day) && d.left >= size && d.end > from
                    && max(d.start, from).addingTimeInterval(45 * 60) <= event.start
                    && (r.maxPriceCents.map { cap in (d.priceFromCents ?? 0) <= cap } ?? true)
            }
            .min { $0.coordinate.distance(to: middle) < $1.coordinate.distance(to: middle) }
        // On the kitchen's own 15-minute pickup grid, so the slot can be reserved as is.
        let slotTime = food.map { d in d.start.addingTimeInterval((max(0, from.timeIntervalSince(d.start)) / 900).rounded(.up) * 900) }
        if let food, let slot = slotTime, slot < food.end {
            stops.append(Plan.Stop(
                kind: .food, title: food.name, note: "\(food.cuisine) for \(size). Pay at pickup.",
                start: slot, genre: .food, latitude: food.latitude, longitude: food.longitude,
                kitchenID: food.kitchenID
            ))
        }

        // Outside for sunset, when sunset falls between the first thing and the event.
        let before = stops.last.map { $0.start.addingTimeInterval(30 * 60) } ?? from
        if let sunset, sunset > before, sunset < event.start.addingTimeInterval(20 * 60) {
            let anchor = stops.last?.coordinate ?? here
            let near = outside
                .filter { $0.coordinate.distance(to: eventAt) < 1800 }
                .min { $0.coordinate.distance(to: anchor) + $0.coordinate.distance(to: eventAt) < $1.coordinate.distance(to: anchor) + $1.coordinate.distance(to: eventAt) }
            if let near {
                let walk = Walk.minutes(anchor.distance(to: near.coordinate))
                let start = stops.isEmpty ? from : roundUp(stops[stops.count - 1].start.addingTimeInterval(Double(15 + walk) * 60), minutes: 15)
                if start < event.start {
                    stops.append(Plan.Stop(
                        kind: .outside, title: near.title, note: "Sunset \(clock(sunset)). \(near.area).",
                        start: start, genre: .play, latitude: near.latitude, longitude: near.longitude
                    ))
                }
            }
        }

        stops.append(Plan.Stop(
            kind: .event, title: event.title,
            note: [event.place, event.priceText.isEmpty ? nil : event.priceText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} "),
            start: event.start, genre: event.category, latitude: event.lat, longitude: event.lon,
            gatheringID: event.id
        ))

        var legs: [Plan.Leg] = []
        for i in 0..<(stops.count - 1) {
            let m = stops[i].coordinate.distance(to: stops[i + 1].coordinate)
            let minutes = Walk.minutes(m)
            let leave = stops[i + 1].start.addingTimeInterval(-Double(minutes) * 60)
            legs.append(Plan.Leg(minutes: minutes, meters: m, note: "Leave \(clock(leave)) \u{00B7} \(minutes) min walk to \(stops[i + 1].title)"))
        }

        let names = Crowd.names(group)
        let holiday = holiday(on: r.day, calendar: calendar)
        let dayName = r.day.formatted(.dateTime.weekday(.wide))
        var checks: [Plan.Check] = []
        // 1. When everyone's free.
        let withHours = group.filter { $0.freeAfterHour != nil }
        if !withHours.isEmpty {
            let parts = withHours.enumerated().map { i, f in
                i == 0 ? "\(f.firstName)'s free after \(hourText(f.freeAfterHour ?? 0))" : "\(f.firstName) after \(hourText(f.freeAfterHour ?? 0))"
            }
            checks.append(.init(title: parts.joined(separator: ", "), detail: "From what they've shared with Wren"))
        } else if !group.isEmpty {
            checks.append(.init(title: "Planning from \(clock(from))", detail: "I'll check that works for \(names) when I ask"))
        }
        // 2. The day.
        let dayTitle = holiday.map { "\(dayName)'s \($0)" } ?? "\(dayName), \(r.day.formatted(.dateTime.month(.abbreviated).day()))"
        let outsideStop = stops.contains { $0.kind == .outside }
        checks.append(.init(title: dayTitle, detail: sunset.map { "Sunset \(clock($0))" + (outsideStop ? ", so start outside" : "") } ?? "A whole evening to fill"))
        // 3. What it is.
        if !r.categories.isEmpty {
            checks.append(.init(title: "Looking for \(r.categories.map(\.noun).sorted().joined(separator: " or "))", detail: "\(event.title) fits, at \(clock(event.start))"))
        } else {
            let top = Genre.allCases.max { taste.weight($0) < taste.weight($1) }
            let detail = "\(event.title) at \(clock(event.start))"
            if let top, taste.weight(top) > 0 {
                checks.append(.init(title: "You show up most for \(top.noun)", detail: detail))
            } else {
                checks.append(.init(title: "Picked what's worth the walk", detail: detail))
            }
        }
        // 4. Food and walking.
        let longest = legs.map(\.minutes).max() ?? 0
        if let food, let slot = stops.first(where: { $0.kind == .food }) {
            checks.append(.init(title: "Found a \(food.cuisine.lowercased()) slot at \(clock(slot.start))", detail: "Every stop within \(max(longest, 1)) minutes' walk of the next"))
        } else {
            checks.append(.init(title: "Checked the walks", detail: legs.isEmpty ? "One stop, \(event.walkMinutes) min from you" : "Every stop within \(longest) minutes' walk of the next"))
        }

        let reply = replyLine(stops: stops, dayName: holiday ?? dayName, names: names, clock: clock)
        var note: [String] = []
        if let late = withHours.max(by: { ($0.freeAfterHour ?? 0) < ($1.freeAfterHour ?? 0) }),
           let h = late.freeAfterHour, at(h, on: r.day, calendar: calendar) > (stops.first?.start ?? from),
           let meetStop = stops.first(where: { $0.start >= at(h, on: r.day, calendar: calendar) }) {
            note.append("\(late.firstName)'s free after \(hourText(h)), so they'll meet you at \(meetStop.title).")
        }

        let title = "\(holiday ?? dayName), sorted."
        var dayLine = r.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if let holiday { dayLine += " \u{00B7} \(holiday)" }
        return Plan(day: r.day, title: title, dayLine: dayLine, friendIDs: group.map(\.id), stops: stops, legs: legs,
                    checks: checks, reply: reply, note: note.joined(separator: " "))
    }

    /// Group things beat solo ones, music and hangs beat a run, after sunset beats before,
    /// and what you keep showing up for counts.
    static func score(_ c: Candidate, _ r: PlanRequest, taste: Taste, sunset: Date?) -> Double {
        var s = taste.weight(c.category)
        if r.categories.contains(c.category) { s += 2 }
        if c.category == .music || c.category == .party { s += 0.4 }
        if let sunset, c.start >= sunset { s += 0.5 }
        if let max = r.maxPriceCents, let price = c.priceFromCents, price > max { s -= 2 }
        s -= Double(c.walkMinutes) / 30
        return s
    }

    static func replyLine(stops: [Plan.Stop], dayName: String, names: String, clock: (Date) -> String) -> String {
        let food = stops.first { $0.kind == .food }
        let outside = stops.first { $0.kind == .outside }
        guard let event = stops.last else { return "" }
        var first = ""
        if let food, let outside { first = "\(food.title) at \(outside.title) for sunset, then " }
        else if let food { first = "\(food.title) at \(clock(food.start)), then " }
        else if let outside { first = "\(outside.title) for sunset, then " }
        let ask = names.isEmpty ? "Want me to hold it?" : "Want me to ask \(names)?"
        return "Here's a \(dayName). \(first)\(event.title) at \(clock(event.start)). \(ask)"
    }

    static func holiday(on day: Date, calendar: Calendar = .current) -> String? {
        let c = calendar.dateComponents([.month, .day], from: day)
        switch (c.month ?? 0, c.day ?? 0) {
        case (10, 31): return "Halloween"
        case (12, 31): return "New Year's Eve"
        case (12, 24): return "Christmas Eve"
        case (7, 4): return "the Fourth"
        case (2, 14): return "Valentine's Day"
        default: return nil
        }
    }

    static func at(_ hour: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: calendar.startOfDay(for: day)) ?? day
    }

    static func roundUp(_ d: Date, minutes: Int) -> Date {
        let step = Double(minutes) * 60
        return Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }

    /// 14 → "2", 21 → "9", 12 → "noon".
    static func hourText(_ h: Int) -> String {
        if h == 12 { return "noon" }
        return "\(h % 12 == 0 ? 12 : h % 12)"
    }
}
