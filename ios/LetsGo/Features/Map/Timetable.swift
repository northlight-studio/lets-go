import Foundation
import CoreLocation

/// The map as a timetable. Each thing is its start time on the map ("7:30", or "Now"),
/// and the time rail at the bottom picks a day and how late to look. This works out what
/// the rail shows (its span, ticks and labels), what falls in the window you dragged it to,
/// the count over it ("14 things", "until 8"), which tags would overlap at a zoom and merge
/// into a count, and the next thing starting close by. Plain functions, so they're tested.
enum Timetable {
    /// The rail runs until 2 AM: "late".
    static let lateHour = 2
    /// Another day's rail starts at 5 AM; before that it's still the night before.
    static let earlyHour = 5
    /// The thumb moves a half hour at a time.
    static let step: TimeInterval = 30 * 60
    /// Today's rail opens on the next three hours, unless that's almost empty.
    static let soon: TimeInterval = 3 * 3600

    // MARK: Days

    /// The days the rail can show: today, tomorrow, and the coming weekend's days, each as
    /// the start of that day. Monday: today, Tuesday, Saturday, Sunday. Saturday: today, Sunday.
    static func days(now: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        var out = [today]
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) { out.append(tomorrow) }
        if let weekend = TimeWindow.weekendRange(from: now, calendar: calendar) {
            var day = weekend.lowerBound
            while day < weekend.upperBound {
                if day > today, !out.contains(day) { out.append(day) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return out
    }

    /// "Today", "Tomorrow", "Saturday".
    static func label(_ day: Date, now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(day, inSameDayAs: today) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), calendar.isDate(day, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return day.formatted(style)
    }

    // MARK: The rail

    /// From now (today) or 5 AM (another day) until 2 AM. Today's late is the first 2 AM
    /// at least an hour away, so a rail opened after midnight still has room.
    static func span(for day: Date, now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let start = calendar.startOfDay(for: day)
        if calendar.isDate(start, inSameDayAs: now) {
            // Just after midnight, tonight's 2 AM is this morning's; otherwise it's tomorrow's.
            let candidates = [
                calendar.date(bySettingHour: lateHour, minute: 0, second: 0, of: start),
                lateNight(after: start, calendar: calendar),
            ].compactMap { $0 }
            let late = candidates.first { $0.timeIntervalSince(now) >= 3600 } ?? now.addingTimeInterval(soon)
            return now...max(late, now.addingTimeInterval(step))
        }
        let open = calendar.date(bySettingHour: earlyHour, minute: 0, second: 0, of: start) ?? start
        let late = lateNight(after: start, calendar: calendar) ?? open.addingTimeInterval(21 * 3600)
        return open...late
    }

    /// 2 AM the morning after `day`.
    private static func lateNight(after day: Date, calendar: Calendar) -> Date? {
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { return nil }
        return calendar.date(bySettingHour: lateHour, minute: 0, second: 0, of: next)
    }

    /// One hour mark on the rail, at `fraction` of the way along. Only some carry a label.
    struct Tick: Hashable, Sendable {
        var date: Date
        var fraction: Double
        var label: String?
    }

    /// The hour marks along the rail, labelled every hour when they fit and every 2, 3, 4
    /// or 6 hours when they don't. Today's starts with "Now".
    static func ticks(
        _ span: ClosedRange<Date>, isToday: Bool, maxLabels: Int = 7,
        calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent
    ) -> [Tick] {
        var hours: [Date] = []
        if var hour = calendar.dateInterval(of: .hour, for: span.lowerBound)?.start {
            if hour < span.lowerBound, let next = calendar.date(byAdding: .hour, value: 1, to: hour) { hour = next }
            while hour <= span.upperBound {
                hours.append(hour)
                guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
                hour = next
            }
        }
        let room = max(1, maxLabels - (isToday ? 1 : 0))
        let every = [1, 2, 3, 4, 6].first { (hours.count + $0 - 1) / $0 <= room } ?? 6
        var out: [Tick] = []
        if isToday { out.append(Tick(date: span.lowerBound, fraction: 0, label: "Now")) }
        for h in hours {
            let f = fraction(of: h, in: span)
            // Leave "Now" its room at the left end.
            let crowdsNow = isToday && f < 0.08
            let labelled = calendar.component(.hour, from: h) % every == 0 && !crowdsNow
            out.append(Tick(date: h, fraction: f, label: labelled ? hourLabel(h, calendar: calendar, locale: locale) : nil))
        }
        return out
    }

    /// Where a time sits along the rail, 0...1.
    static func fraction(of date: Date, in span: ClosedRange<Date>) -> Double {
        let length = span.upperBound.timeIntervalSince(span.lowerBound)
        guard length > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(span.lowerBound) / length))
    }

    /// The time under a point along the rail: snapped to the half hour, at least a half hour
    /// past the start, and the very end ("late") near the right edge.
    static func until(at fraction: Double, in span: ClosedRange<Date>, calendar: Calendar = .current) -> Date {
        if fraction >= 0.97 { return span.upperBound }
        let length = span.upperBound.timeIntervalSince(span.lowerBound)
        let raw = span.lowerBound.addingTimeInterval(length * min(1, max(0, fraction)))
        let snapped = halfHour(raw, calendar: calendar)
        let earliest = span.lowerBound.addingTimeInterval(step)
        return min(span.upperBound, max(earliest, snapped))
    }

    /// The nearest half hour.
    static func halfHour(_ date: Date, calendar: Calendar = .current) -> Date {
        guard let hour = calendar.dateInterval(of: .hour, for: date)?.start else { return date }
        let halves = (date.timeIntervalSince(hour) / step).rounded()
        return hour.addingTimeInterval(halves * step)
    }

    /// Where the thumb starts. Another day: late, so you see the whole day. Today: the next
    /// three hours (to the hour), unless fewer than three things start by then and more
    /// start later; then late.
    static func defaultUntil(_ all: [Candidate], day: Date, now: Date, calendar: Calendar = .current) -> Date {
        let rail = span(for: day, now: now, calendar: calendar)
        guard calendar.isDate(day, inSameDayAs: now) else { return rail.upperBound }
        var soon = now.addingTimeInterval(Self.soon)
        if let hour = calendar.dateInterval(of: .hour, for: soon)?.start, hour < soon,
           let next = calendar.date(byAdding: .hour, value: 1, to: hour) {
            soon = next
        }
        soon = min(rail.upperBound, soon)
        let bySoon = all.filter { shows($0, in: rail, until: soon, now: now) }.count
        let byLate = all.filter { shows($0, in: rail, until: rail.upperBound, now: now) }.count
        return bySoon >= 3 || byLate == bySoon ? soon : rail.upperBound
    }

    // MARK: What's in the window

    static func isOn(_ c: Candidate, now: Date) -> Bool { c.start <= now && c.end > now }

    /// On the rail's day and starting by `until`. What's on now shows on today's rail only;
    /// anything that has ended never shows.
    static func shows(_ c: Candidate, in span: ClosedRange<Date>, until: Date, now: Date) -> Bool {
        guard c.end > now else { return false }
        if c.start <= now { return span.lowerBound <= now }
        return c.start >= span.lowerBound && c.start <= min(until, span.upperBound)
    }

    /// What the map shows: in the window, of the kind asked for, free if asked. What's on now
    /// first, then by start, then nearest.
    static func window(
        _ all: [Candidate], span: ClosedRange<Date>, until: Date, now: Date,
        genre: Genre? = nil, freeOnly: Bool = false
    ) -> [Candidate] {
        all.filter { c in
            shows(c, in: span, until: until, now: now)
                && (genre.map { c.category == $0 } ?? true)
                && (!freeOnly || c.isFree)
        }
        .sorted { a, b in
            let aOn = isOn(a, now: now), bOn = isOn(b, now: now)
            if aOn != bOn { return aOn }
            if a.start != b.start { return a.start < b.start }
            return a.meters < b.meters
        }
    }

    /// Over the rail: "14 things", "1 thing", "Nothing yet".
    static func countLine(_ n: Int) -> String {
        switch n {
        case 0: "Nothing yet"
        case 1: "1 thing"
        default: "\(n) things"
        }
    }

    /// "until 8", "until 8:30", "until late".
    static func untilLine(_ until: Date, span: ClosedRange<Date>, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        if until >= span.upperBound { return "until late" }
        return "until \(clock(until, calendar: calendar, locale: locale, dropZeroMinutes: true))"
    }

    // MARK: Tags

    /// A tag on the map: "Now" for what's on, otherwise its start, "7:30".
    static func tag(_ c: Candidate, now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        isOn(c, now: now) ? "Now" : clock(c.start, calendar: calendar, locale: locale)
    }

    /// "7:30", "8:00" (or "8" with `dropZeroMinutes`): the map has no room for AM and PM.
    static func clock(_ d: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent, dropZeroMinutes: Bool = false) -> String {
        var style = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted))
        if !(dropZeroMinutes && calendar.component(.minute, from: d) == 0) { style = style.minute() }
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return d.formatted(style)
    }

    static func hourLabel(_ d: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        clock(d, calendar: calendar, locale: locale, dropZeroMinutes: true)
    }

    // MARK: Merging

    /// Tags close enough to overlap on screen, as one group. A group of one is a time tag;
    /// more is a count. `id` is stable while its members are, so the map only redraws
    /// what changed.
    struct Group: Identifiable, Equatable, Sendable {
        var id: String
        var members: [Candidate]
        var latitude: Double
        var longitude: Double

        var isSingle: Bool { members.count == 1 }
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    /// A tag's footprint on screen, in points, with a little air around it.
    static let tagWidth = 50.0
    static let tagHeight = 26.0

    /// Where a place sits on the whole world drawn at `zoom`, in points (MapLibre's
    /// 512-point tiles, Web Mercator). Two places' distance on screen is the difference.
    static func worldPoint(latitude: Double, longitude: Double, zoom: Double) -> (x: Double, y: Double) {
        let size = 512 * pow(2, zoom)
        let s = min(0.9999, max(-0.9999, sin(latitude * .pi / 180)))
        let x = (longitude + 180) / 360 * size
        let y = (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * size
        return (x, y)
    }

    /// Merges tags that would overlap at `zoom`. What's on now and what starts first keep
    /// their own tags first; the one you tapped never merges. Zooming in pulls groups apart.
    static func merge(_ items: [Candidate], zoom: Double, now: Date, selected: UUID? = nil) -> [Group] {
        let ordered = items.sorted { a, b in
            if (a.id == selected) != (b.id == selected) { return a.id == selected }
            let aOn = isOn(a, now: now), bOn = isOn(b, now: now)
            if aOn != bOn { return aOn }
            if a.start != b.start { return a.start < b.start }
            return a.id.uuidString < b.id.uuidString
        }
        var anchors: [(x: Double, y: Double)] = []
        var members: [[Candidate]] = []
        for c in ordered {
            let p = worldPoint(latitude: c.lat, longitude: c.lon, zoom: zoom)
            let joins = c.id == selected ? nil : anchors.indices.first { i in
                members[i].first?.id != selected
                    && abs(anchors[i].x - p.x) < tagWidth && abs(anchors[i].y - p.y) < tagHeight
            }
            if let i = joins {
                members[i].append(c)
            } else {
                anchors.append(p)
                members.append([c])
            }
        }
        return members.map { group in
            let first = group[0]
            let id = group.count == 1 ? first.id.uuidString : "g:" + group.map(\.id.uuidString).sorted().joined(separator: ",")
            return Group(id: id, members: group, latitude: first.lat, longitude: first.lon)
        }
    }

    /// The zoom tags are merged at: steps of a quarter, so they regroup a few times during a
    /// pinch rather than every frame.
    static func mergeZoom(_ zoom: Double) -> Double { (zoom * 4).rounded(.down) / 4 }

    // MARK: The card

    /// Metres between two things.
    static func meters(_ a: Candidate, _ b: Candidate) -> Double {
        CLLocation(latitude: a.lat, longitude: a.lon).distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
    }

    /// "Then nearby": the next thing starting after this one, within a short walk of it and
    /// the next four hours. The soonest wins, then the closest.
    static func thenNearby(after c: Candidate, in all: [Candidate], within: Double = 500, hours: Double = 4) -> Candidate? {
        let latest = c.start.addingTimeInterval(hours * 3600)
        return all
            .filter { $0.id != c.id && $0.start > c.start && $0.start <= latest && meters(c, $0) <= within }
            .min { a, b in a.start != b.start ? a.start < b.start : meters(c, a) < meters(c, b) }
    }

    /// The card's line: "Valencia St · 9-minute walk · $10". Already on: "On till 9:30 · …".
    static func cardLine(_ c: Candidate, now: Date, walkMinutes: Int? = nil, clock: (Date) -> String = { Timetable.clock($0) }) -> String {
        var parts: [String] = []
        if isOn(c, now: now) { parts.append("On till \(clock(c.end))") }
        if !c.place.isEmpty { parts.append(c.place) }
        parts.append("\(walkMinutes ?? c.walkMinutes)-minute walk")
        switch c.kind {
        case .gathering:
            parts.append(c.priceText.isEmpty ? "Free" : c.priceText)
        case .drop:
            if let price = c.priceFromCents { parts.append("from \(Pricing.format(price))") }
        }
        return parts.joined(separator: " · ")
    }

    /// "Late set · 2-minute walk": what "Then nearby" says after the time.
    static func nearbyLine(_ next: Candidate, from c: Candidate) -> String {
        let walk = Walk.minutes(meters(c, next))
        return "\(next.title) · \(walk)-minute walk"
    }
}
