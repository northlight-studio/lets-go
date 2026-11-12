import Foundation

// Supper club: dinner for a few neighbors at the host's place, at a set price a seat that covers the
// food. Neighbors ask for a seat, the host says yes or no, and the address goes only to guests the
// host said yes to. The plain logic behind the screens: the host's form, where you stand with a
// supper, and the words on the page, the pin and the receipt (tested in `SupperTests`).

/// A seat's request, as the server has it.
nonisolated enum SeatStatus: String, Sendable {
    case asked, accepted, declined, withdrawn, canceled, lapsed
}

/// A seat's money: nothing while asking; on a yes, at the door or in the app (unpaid → paid).
nonisolated enum SeatPayment: String, Sendable {
    case none
    case atDoor = "at_door"
    case unpaid, paid, refunded
}

/// Where you stand with a supper: what its page says at the bottom and which button it shows.
nonisolated enum SeatStage: Equatable, Sendable {
    /// It's yours.
    case hosting
    /// There's a seat and it hasn't started: ask.
    case open
    /// Every seat is given.
    case full
    /// You asked; the host hasn't answered.
    case asked
    /// The host said yes; pay in the app (by then, or the seat goes back).
    case toPay(by: Date?)
    /// You're going: paid, or paying at the door.
    case going(atDoor: Bool)
    case declined
    /// You didn't pay in time.
    case lapsed
    /// The host called it off.
    case canceled
    /// It's started or over (and you weren't at the table).
    case over
    /// It's started or over, and you were at it: reviews and adding the table.
    case after

    static func of(_ s: SupperDTO, now: Date) -> SeatStage {
        if s.canceled { return .canceled }
        let seat = s.mySeat
        let status = seat.flatMap { SeatStatus(rawValue: $0.status) }
        let payment = seat.flatMap { SeatPayment(rawValue: $0.payment) } ?? SeatPayment.none
        let confirmed = status == .accepted && (payment == .atDoor || payment == .paid)
        if s.startsAt <= now {
            return s.isMine || confirmed ? .after : .over
        }
        if s.isMine { return .hosting }
        switch status {
        case .asked: return .asked
        case .accepted:
            return confirmed ? .going(atDoor: payment == .atDoor) : .toPay(by: seat?.payBy)
        case .declined: return .declined
        case .lapsed: return s.seatsLeft > 0 ? .open : .full
        case .withdrawn, .canceled, nil: return s.seatsLeft > 0 ? .open : .full
        }
    }
}

/// Opens a supper's page in a navigation stack.
nonisolated struct SupperLink: Hashable, Sendable {
    var id: UUID
}

/// The host's form, as plain values.
nonisolated struct SupperDraft: Equatable, Sendable {
    struct Course: Equatable, Sendable, Identifiable {
        var id = UUID()
        var name = ""
        var note = ""
    }

    var title = ""
    /// The day (any time on it).
    var day: Date
    /// 24-hour, on the half hour: 19 is 7 PM.
    var from: Double = 19
    /// How long it runs, in hours.
    var hours: Double = 3
    var seats = 6
    /// A seat's price as typed: "18", "$18.50".
    var priceText = ""
    var courses: [Course] = [Course(), Course(), Course()]
    var tags: Set<String> = []
    var houseNotes = ""
    var address = ""
    var permitConfirmed = false

    static let maxSeats = 20
    /// What a guest might need to know before asking: options first, then allergens.
    static let tagOptions = [
        "Vegetarian option", "Vegan option", "Gluten-free option", "Contains nuts", "Contains dairy",
        "Contains gluten", "Contains shellfish", "Contains eggs", "Pets in the house",
    ]

    init(day: Date) {
        self.day = day
    }

    /// Integer cents, at most $500 a seat; nil when it isn't a price.
    var priceCents: Int? {
        guard let c = BatchDraft.cents(from: priceText), c <= 50_000 else { return nil }
        return c
    }

    /// When it starts and ends.
    func window(calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: day).addingTimeInterval(from * 3600)
        return (start, start.addingTimeInterval(hours * 3600))
    }

    /// The courses that have a name, in order.
    var menu: [CourseDTO] {
        courses
            .map { CourseDTO(name: $0.name.trimmingCharacters(in: .whitespaces), note: $0.note.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.name.isEmpty }
    }

    /// What's still missing, in words, or nil when it's ready.
    func problem(now: Date, needsAddress: Bool, needsPermit: Bool, calendar: Calendar = .current) -> String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name, like \"Oaxacan night\"." }
        if menu.isEmpty { return "Add at least one course." }
        if seats < 1 || seats > Self.maxSeats { return "Between 1 and \(Self.maxSeats) seats." }
        if priceCents == nil { return "Set a price a seat." }
        if window(calendar: calendar).start <= now { return "Pick a time that hasn't passed." }
        if needsAddress, address.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Add your address. Only guests you say yes to see it."
        }
        if needsPermit, !permitConfirmed { return "Confirm your home kitchen permit." }
        return nil
    }

    /// The coming Sunday at 7 for three hours, six seats: the usual one. On a Sunday before 3 PM, today.
    static func starting(now: Date, calendar: Calendar = .current) -> SupperDraft {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: now) // 1 is Sunday
        let hour = calendar.component(.hour, from: now)
        let ahead = weekday == 1 ? (hour < 15 ? 0 : 7) : 8 - weekday
        let day = calendar.date(byAdding: .day, value: ahead, to: today) ?? today
        return SupperDraft(day: day)
    }
}

/// The words on a supper's page, its pin and its buttons.
nonisolated enum SupperCopy {
    /// "Ana Ruiz" → "Ana".
    static func firstName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name
    }

    /// "at Ana's".
    static func at(_ host: String) -> String {
        "at \(firstName(host))'s"
    }

    /// "Sunday · 7 PM", "Tonight · 7:30 PM", "Tomorrow · 7 PM".
    static func when(_ start: Date, now: Date, calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDate(start, inSameDayAs: now) {
            day = calendar.component(.hour, from: start) >= 17 ? "Tonight" : "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else if let week = calendar.date(byAdding: .day, value: 6, to: calendar.startOfDay(for: now)), start < week {
            var f = Date.FormatStyle.dateTime.weekday(.wide)
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            if let locale = calendar.locale { f.locale = locale }
            day = start.formatted(f)
        } else {
            var f = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            if let locale = calendar.locale { f.locale = locale }
            day = start.formatted(f)
        }
        let h = calendar.component(.hour, from: start)
        return "\(day) · \(BatchCopy.hour(start, calendar: calendar)) \(h < 12 ? "AM" : "PM")"
    }

    /// "14 suppers hosted · ★ 4.9 · 6-minute walk". A first-time host: "First supper".
    static func hostLine(hosted: Int, rating: Double?, reviews: Int, walkMinutes: Int?) -> String {
        var parts: [String] = []
        parts.append(hosted == 0 ? "First supper" : hosted == 1 ? "1 supper hosted" : "\(hosted) suppers hosted")
        if let rating, reviews > 0 { parts.append("★ \(String(format: "%.1f", rating))") }
        if let walkMinutes { parts.append("\(walkMinutes)-minute walk") }
        return parts.joined(separator: " · ")
    }

    /// "4 of 6 seats · 2 left · $18 a seat"; "All 6 seats taken · $18 a seat".
    static func seatsLine(taken: Int, seats: Int, priceCents: Int) -> String {
        let left = max(0, seats - taken)
        let price = "\(Pricing.format(priceCents)) a seat"
        if left == 0 { return "All \(seats) seats taken · \(price)" }
        if taken == 0 { return "\(seats) seats · \(price)" }
        return "\(taken) of \(seats) seats · \(left) left · \(price)"
    }

    /// The tag under a supper's pin: "2 seats", "1 seat", "Full".
    static func seatsTag(left: Int) -> String {
        left <= 0 ? "Full" : left == 1 ? "1 seat" : "\(left) seats"
    }

    /// What asking means, before you ask: the host chooses, what a yes costs, and the rule for backing out.
    static func askLine(host: String, totalCents: Int, inApp: Bool, refundUntil: Date, now: Date, calendar: Calendar = .current) -> String {
        let who = firstName(host)
        if inApp {
            return "\(who) chooses who comes. If \(who) says yes, you pay \(Pricing.format(totalCents)) in the app and get the address. "
                + refundRule(refundUntil, now: now, calendar: calendar)
        }
        return "\(who) chooses who comes. If \(who) says yes, you get the address and pay \(Pricing.format(totalCents)) at the door. Can't make it? Give the seat back in the app so someone else can come."
    }

    /// "Back out by Friday 7 PM for all of it back; after that the seat goes back, the money doesn't."
    static func refundRule(_ until: Date, now: Date, calendar: Calendar = .current) -> String {
        if until <= now { return "It's within two days, so backing out now gives the seat back but not the money." }
        return "Back out by \(inline(until, now: now, calendar: calendar)) for all of it back; after that the seat goes back, the money doesn't."
    }

    /// The line over the button for where you stand.
    static func stageLine(_ stage: SeatStage, host: String, waiting: Int = 0) -> String? {
        let who = firstName(host)
        switch stage {
        case .hosting:
            return waiting == 0 ? nil : waiting == 1 ? "1 neighbor is asking for a seat." : "\(waiting) neighbors are asking for a seat."
        case .open: return nil
        case .full: return "Every seat is taken."
        case .asked: return "You asked. \(who) will say yes or no; you'll see it here."
        case .toPay: return "\(who) said yes. Pay to keep your seat and get the address."
        case .going(let atDoor): return atDoor ? "You're going. Pay \(who) at the door." : "You're going. It's paid."
        case .declined: return "\(who) can't fit you in this time."
        case .lapsed: return "The time to pay ran out, so the seat went back."
        case .canceled: return "\(who) called this one off. Anything you paid comes back to you."
        case .over: return "This supper has started."
        case .after: return nil
        }
    }

    /// "Pay by Friday 7 PM".
    static func payBy(_ date: Date?, now: Date, calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        return "Pay by \(inline(date, now: now, calendar: calendar))"
    }

    /// `when` inside a sentence: "tomorrow 7 PM", "Friday 7 PM".
    static func inline(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let w = when(date, now: now, calendar: calendar).replacingOccurrences(of: " · ", with: " ")
        for word in ["Tonight", "Today", "Tomorrow"] where w.hasPrefix(word) {
            return word.lowercased() + w.dropFirst(word.count)
        }
        return w
    }

    /// A guest asking, as the host sees them: "3 suppers · ★ 4.8 from 5", "New to suppers".
    static func guestLine(attended: Int, rating: Double?, reviews: Int) -> String {
        var parts: [String] = []
        parts.append(attended == 0 ? "New to suppers" : attended == 1 ? "1 supper" : "\(attended) suppers")
        if let rating, reviews > 0 { parts.append("★ \(String(format: "%.1f", rating)) from \(reviews)") }
        return parts.joined(separator: " · ")
    }

    /// "Maya is going", "Maya and Theo are going", "Maya, Theo and Jun are going" (first names).
    static func friendsGoing(_ names: [String]) -> String {
        let first = names.map(firstName)
        guard let last = first.last else { return "" }
        let who = first.count == 1 ? last : first.dropLast().joined(separator: ", ") + " and " + last
        return who + (first.count == 1 ? " is going" : " are going")
    }

    /// The host's line on the page: "4 of 6 seats given · 2 asking".
    static func hostSeats(taken: Int, seats: Int, waiting: Int) -> String {
        var line = "\(taken) of \(seats) seats given"
        if waiting > 0 { line += " · \(waiting) asking" }
        return line
    }
}
