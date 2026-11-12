import Foundation

/// Your block: the short list of what's going on within a few blocks. The server picks and ranks
/// (backend `app/block.py`); this writes the words, remembers what you've seen so nothing repeats
/// on another day, says when today's is done, and decides what the evening digest says and when.
/// Plain values, so it's all tested.
enum Block {
    // MARK: The title

    /// "24th Street and around", or the neighborhood, or just "Around you".
    static func area(street: String?, neighborhood: String?) -> String {
        if let s = street?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return "\(s) and around" }
        if let n = neighborhood?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return "\(n) and around" }
        return "Around you"
    }

    // MARK: Rows

    enum Thumb: Equatable {
        /// A batch's photo (a path on the server, or nil for the drawn stand-in) and its title.
        case photo(String?, title: String)
        case initials(String)
        case symbol(String)
    }

    struct Row: Identifiable, Equatable {
        var id: String
        var kind: String
        var line: String
        var detail: String
        var thumb: Thumb
        /// What it's about: the drop, gathering or person on the server.
        var subject: UUID
        var kitchenID: UUID?
    }

    static func row(_ i: BlockItemDTO, now: Date, calendar: Calendar = .current) -> Row {
        let line: String
        var detail: [String] = []
        var thumb = Thumb.symbol("sparkles")
        switch i.kind {
        case "batch":
            let who = cook(i.name)
            line = who.map { "\($0) made \(lowerFirst(i.title))" } ?? "\(i.title) from \(i.name ?? "a neighbor")"
            if let left = i.left { detail.append(leftLine(left, unit: i.unit)) }
            if let s = i.startsAt, let e = i.endsAt { detail.append("pickup \(window(s, e, now: now, calendar: calendar))") }
            if let w = i.walkMin { detail.append("\(w) min") }
            thumb = .photo(i.photoUrl, title: i.title)
        case "back":
            let who = cook(i.name) ?? i.name ?? "A kitchen you follow"
            let day = i.startsAt.map { day($0, now: now, calendar: calendar) } ?? "soon"
            line = "\(who)\u{2019}s \(lowerFirst(i.title)), back \(day)"
            detail.append("You follow \(i.name ?? "them")")
            if let s = i.startsAt, let e = i.endsAt { detail.append("pickup \(clock(s)) to \(clock(e))") }
            detail.append("reserve now")
            thumb = .photo(i.photoUrl, title: i.title)
        case "supper":
            let seats = i.seatsLeft ?? 0
            let host = cook(i.name) ?? i.name ?? "A neighbor"
            line = "\(host)\u{2019}s supper has \(seats) seat\(seats == 1 ? "" : "s")"
            if !i.title.isEmpty { detail.append(i.title) }
            if let p = i.priceCents, p > 0 { detail.append(Pricing.format(p)) }
            if let s = i.startsAt { detail.append(When.short(s, now: now, calendar: calendar)) }
            thumb = .photo(i.photoUrl, title: i.title)
        case "going":
            line = goingLine(friends: i.friends, count: i.count, title: i.title)
            if let s = i.startsAt { detail.append(startLine(s, end: i.endsAt, now: now, calendar: calendar)) }
            if !i.placeName.isEmpty { detail.append(i.placeName) }
            if let w = i.walkMin { detail.append("\(w) min") }
            thumb = .symbol(i.friends.isEmpty ? "person.3.fill" : "person.2.fill")
        case "neighbor":
            let first = firstName(i.name)
            line = "Say hi to \(first)"
            detail.append("You\u{2019}ve been to \(i.together) things together")
            thumb = .initials(Pins.initials(i.name ?? ""))
        case "up_for":
            let first = firstName(i.name)
            line = "\(first) is up for \(lowerFirst(i.title))"
            detail.append(i.walkMin.map { "\($0) min away" } ?? "right now")
            if let e = i.endsAt { detail.append("until \(clock(e))") }
            thumb = .initials(Pins.initials(i.name ?? ""))
        default:
            line = i.title
        }
        return Row(id: i.key, kind: i.kind, line: line, detail: detail.joined(separator: " \u{00B7} "),
                   thumb: thumb, subject: i.id, kitchenID: i.kitchenId)
    }

    /// "Maya is going to Jazz in the park", "Maya and Sam are…", "3 neighbors are…". Only friends
    /// are ever named; everyone else is a number.
    static func goingLine(friends: [String], count: Int, title: String) -> String {
        switch friends.count {
        case 0: return "\(count) neighbor\(count == 1 ? " is" : "s are") going to \(title)"
        case 1: return "\(friends[0]) is going to \(title)"
        case 2: return "\(friends[0]) and \(friends[1]) are going to \(title)"
        default: return "\(friends[0]) and \(friends.count - 1) friends are going to \(title)"
        }
    }

    /// "Dana Whitfield's kitchen" → "Dana". A kitchen with its own name has no cook to name.
    static func cook(_ kitchen: String?) -> String? {
        guard let k = kitchen, k.hasSuffix("\u{2019}s kitchen") || k.hasSuffix("'s kitchen") else { return nil }
        let owner = k.dropLast("'s kitchen".count)
        return owner.split(separator: " ").first.map(String.init)
    }

    static func firstName(_ name: String?) -> String {
        name?.split(separator: " ").first.map(String.init) ?? "Someone"
    }

    /// "Mango ice cream" → "mango ice cream", "A walk" → "a walk", but "IPA flight" stays as it is.
    static func lowerFirst(_ s: String) -> String {
        guard let first = s.first, first.isUppercase else { return s }
        let word = s.prefix { !$0.isWhitespace }
        let letters = word.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return s }
        return first.lowercased() + s.dropFirst()
    }

    /// "8 pints left", "1 box of 6 left", "3 left".
    static func leftLine(_ left: Int, unit: String) -> String {
        let u = unit.trimmingCharacters(in: .whitespaces)
        if left == 0 { return "sold out" }
        guard !u.isEmpty else { return "\(left) left" }
        return "\(left) \(left == 1 ? u : plural(u)) left"
    }

    /// The first word of a unit made plural: "pint" → "pints", "box of 6" → "boxes of 6".
    static func plural(_ unit: String) -> String {
        var words = unit.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let first = words.first, !first.isEmpty else { return unit }
        let es = ["s", "x", "z", "ch", "sh"].contains { first.lowercased().hasSuffix($0) }
        words[0] = first + (es ? "es" : "s")
        return words.joined(separator: " ")
    }

    /// "7 PM", or "7:30 PM" when it isn't on the hour.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(timeZone: calendar.timeZone)
        return calendar.component(.minute, from: date) == 0
            ? date.formatted(style.hour())
            : date.formatted(style.hour().minute())
    }

    /// "tonight", "today", "tomorrow", or the weekday ("Friday").
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return calendar.component(.hour, from: date) >= 17 ? "tonight" : "today"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow"
        }
        return date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide))
    }

    /// "tonight 7 PM to 9 PM", "now to 9 PM" once it's open.
    static func window(_ start: Date, _ end: Date, now: Date, calendar: Calendar = .current) -> String {
        if start <= now { return "now to \(clock(end, calendar: calendar))" }
        return "\(day(start, now: now, calendar: calendar)) \(clock(start, calendar: calendar)) to \(clock(end, calendar: calendar))"
    }

    /// "on now", "in 20 min", "tonight 7:30 PM".
    static func startLine(_ start: Date, end: Date?, now: Date, calendar: Calendar = .current) -> String {
        if let end, start <= now, now < end { return "on now" }
        let minutes = Int(start.timeIntervalSince(now) / 60)
        if minutes >= 0, minutes < 60 { return "in \(max(1, minutes)) min" }
        return "\(day(start, now: now, calendar: calendar)) \(clock(start, calendar: calendar))"
    }

    // MARK: What you've seen

    /// When you first saw each row (by its key), and what an evening digest already told you about.
    /// A row first seen on an earlier day doesn't come back: the list is today's, then it ends.
    struct Memory: Codable, Equatable {
        var seen: [String: Date] = [:]
        var told: [String: Date] = [:]
    }

    /// Today's rows: new ones, and ones you first saw today.
    static func today(_ items: [BlockItemDTO], memory: Memory, now: Date, calendar: Calendar = .current) -> [BlockItemDTO] {
        items.filter { i in memory.seen[i.key].map { calendar.isDate($0, inSameDayAs: now) } ?? true }
    }

    /// Rows you haven't seen yet: the dot on the bell.
    static func unseen(_ items: [BlockItemDTO], memory: Memory) -> [BlockItemDTO] {
        items.filter { memory.seen[$0.key] == nil }
    }

    /// Remembers these as seen now (keeping the first time), and forgets anything from over two weeks ago.
    static func seeing(_ items: [BlockItemDTO], in memory: Memory, now: Date) -> Memory {
        var m = memory
        for i in items where m.seen[i.key] == nil { m.seen[i.key] = now }
        let cutoff = now.addingTimeInterval(-14 * 86_400)
        m.seen = m.seen.filter { $0.value > cutoff }
        m.told = m.told.filter { $0.value > cutoff }
        return m
    }

    // MARK: The evening digest

    /// When it comes: early evening, before people decide what to do with it.
    static let digestHour = 17
    static let digestMinute = 30

    /// The next early evening after `now`. One pending digest at a time, so never more than one a day.
    static func nextDigest(after now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: digestHour, minute: digestMinute, second: 0, of: now) ?? now
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }

    /// What's worth a digest at `fire`: not seen, not already told in an earlier digest, and still on then.
    static func digestItems(_ items: [BlockItemDTO], memory: Memory, fire: Date) -> [BlockItemDTO] {
        items.filter { i in
            memory.seen[i.key] == nil
                && (memory.told[i.key].map { $0 >= fire } ?? true)
                && (i.endsAt.map { $0 > fire } ?? true)
        }
    }

    /// "Dana made mango ice cream, and 2 more on your block." Nil when there's nothing new: no digest.
    static func digestBody(_ items: [BlockItemDTO], fire: Date, calendar: Calendar = .current) -> String? {
        guard let first = items.first else { return nil }
        let line = row(first, now: fire, calendar: calendar).line
        let more = items.count - 1
        return more == 0 ? "\(line)." : "\(line), and \(more) more on your block."
    }
}
