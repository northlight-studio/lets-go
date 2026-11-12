import Foundation
import CoreGraphics

// Post a batch, sell to your neighbors. The plain logic behind the screens: the 30-second form,
// the pickup window, the words on the listing and the receipt, and the photo's size.

/// How a batch is paid for: in the app (Stripe, once the cook has set up payouts) or to the cook
/// at pickup.
nonisolated enum PayMode: String, Sendable {
    case inApp = "in_app"
    case atPickup = "at_pickup"
}

/// Where an order's money stands. `unpaid` holds the stock until it's paid (15 minutes); `expired`
/// is a hold that ran out first (the server canceled it and put the stock back).
nonisolated enum PaymentState: String, Sendable {
    case atPickup = "at_pickup"
    case unpaid
    case paid
    case refunded
    case expired

    /// Still something to go and pick up (or to pay for).
    var isLive: Bool { self != .refunded && self != .expired }
}

/// The "Sell something" form, as plain values.
nonisolated struct BatchDraft: Equatable, Sendable {
    enum Day: Equatable, Sendable {
        case today, tomorrow
        case on(Date)
    }

    enum Spot: String, CaseIterable, Sendable {
        case porch, door
        var label: String { self == .porch ? "My porch" : "My door" }
    }

    var title = ""
    /// As typed: "6", "6.50", "$6".
    var priceText = ""
    var count = 8
    /// What one is: "pint", "box of 6". Empty for a plain count.
    var unit = ""
    var day: Day = .today
    /// 24-hour, on the half hour: 19 is 7 PM, 19.5 is 7:30.
    var from: Double = 19
    var to: Double = 21
    var spot: Spot = .porch
    var tags: Set<String> = []
    var address = ""
    var pickupNote = ""
    var permitConfirmed = false

    /// The ones a seller picks from: allergens first, then diets.
    static let tagOptions = [
        "Contains dairy", "Contains eggs", "Contains nuts", "Contains peanuts", "Contains gluten", "Contains soy",
        "Contains sesame", "Contains shellfish", "Vegan", "Vegetarian", "Gluten-free", "Dairy-free",
    ]

    /// Integer cents from what was typed, or nil when it isn't a price. "6" → 600, "6.5" → 650, "$6.50" → 650.
    static func cents(from text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let dollars = Int(parts[0].isEmpty ? "0" : parts[0]), dollars >= 0 else { return nil }
        var cents = 0
        if parts.count == 2 {
            let frac = parts[1]
            guard frac.count <= 2, frac.allSatisfy(\.isNumber) else { return nil }
            cents = Int(frac.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        }
        let total = dollars * 100 + cents
        return total > 0 && total <= 100_000 ? total : nil
    }

    var priceCents: Int? { Self.cents(from: priceText) }

    /// The pickup window as dates, or nil when the hours are backwards.
    func window(now: Date, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        guard to > from else { return nil }
        let base: Date
        switch day {
        case .today: base = calendar.startOfDay(for: now)
        case .tomorrow: base = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        case .on(let d): base = calendar.startOfDay(for: d)
        }
        let start = base.addingTimeInterval(from * 3600)
        let end = base.addingTimeInterval(to * 3600)
        return (start, end)
    }

    /// What's still missing, in words, or nil when it's ready to post.
    func problem(now: Date, needsAddress: Bool, needsPermit: Bool, calendar: Calendar = .current) -> String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return "Say what it is." }
        if priceCents == nil { return "Set a price." }
        if count < 1 { return "Make at least one." }
        guard let w = window(now: now, calendar: calendar) else { return "The pickup window has to end after it starts." }
        if w.end <= now { return "That window's over. Pick tomorrow." }
        if needsAddress, address.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Add your address. Only people who reserve see it."
        }
        if needsPermit, !permitConfirmed { return "Confirm your home kitchen permit." }
        return nil
    }

    /// Tonight 7 to 9: the usual one, and where the form starts. After 9 it starts tomorrow.
    static func starting(now: Date, calendar: Calendar = .current) -> BatchDraft {
        var d = BatchDraft()
        let hour = Double(calendar.component(.hour, from: now)) + Double(calendar.component(.minute, from: now)) / 60
        if hour >= 20.5 { d.day = .tomorrow }
        return d
    }
}

/// The words on a batch's listing, the reserve button and the receipt.
nonisolated enum BatchCopy {
    /// "pint" → "pints", "box of 6" → "boxes of 6".
    static func plural(_ unit: String) -> String {
        guard !unit.isEmpty else { return unit }
        var words = unit.split(separator: " ", maxSplits: 1).map(String.init)
        let w = words[0]
        if w.hasSuffix("s") || w.hasSuffix("x") || w.hasSuffix("ch") || w.hasSuffix("sh") {
            words[0] = w + "es"
        } else if w.hasSuffix("y"), let last = w.dropLast().last, !"aeiou".contains(last) {
            words[0] = String(w.dropLast()) + "ies"
        } else {
            words[0] = w + "s"
        }
        return words.joined(separator: " ")
    }

    /// "1 pint", "8 pints", "3".
    static func count(_ n: Int, _ unit: String) -> String {
        unit.isEmpty ? "\(n)" : "\(n) \(n == 1 ? unit : plural(unit))"
    }

    /// "$6 a pint", "$6 each".
    static func price(_ cents: Int, unit: String) -> String {
        let a = unit.first.map { "aeiou".contains($0.lowercased()) } ?? false ? "an" : "a"
        return unit.isEmpty ? "\(Pricing.format(cents)) each" : "\(Pricing.format(cents)) \(a) \(unit)"
    }

    /// "8 of 12 pints left", "Sold out".
    static func left(_ left: Int, of total: Int, unit: String) -> String {
        left <= 0 ? "Sold out" : "\(left) of \(unit.isEmpty ? "\(total)" : count(total, unit)) left"
    }

    /// "Tonight · pickup 7 to 9", "Tomorrow · pickup 7:30 to 9", "Saturday · pickup 11 to 1".
    static func window(_ start: Date, _ end: Date, now: Date, calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDate(start, inSameDayAs: now) {
            day = calendar.component(.hour, from: start) >= 17 ? "Tonight" : "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else {
            day = start.formatted(.dateTime.weekday(.wide))
        }
        return "\(day) · pickup \(hour(start, calendar: calendar)) to \(hour(end, calendar: calendar))"
    }

    /// "7", "7:30" (12-hour, no AM/PM: the window says enough).
    static func hour(_ d: Date, calendar: Calendar = .current) -> String {
        let h = calendar.component(.hour, from: d), m = calendar.component(.minute, from: d)
        let h12 = h % 12 == 0 ? 12 : h % 12
        return m == 0 ? "\(h12)" : String(format: "%d:%02d", h12, m)
    }

    /// The half-hour steps on the form: 19 → "7 PM", 19.5 → "7:30 PM".
    static func clock(_ hours: Double) -> String {
        let h = Int(hours) % 24, m = Int(((hours - Double(Int(hours))) * 60).rounded())
        let h12 = h % 12 == 0 ? 12 : h % 12
        let half = h < 12 ? "AM" : "PM"
        return m == 0 ? "\(h12) \(half)" : String(format: "%d:%02d %@", h12, m, half)
    }

    /// The reserve button. In the app: "Reserve a pint · $6.50". At pickup: "Reserve a pint · pay at pickup".
    static func reserve(quantity: Int, unit: String, totalCents: Int, pay: PayMode) -> String {
        let what: String
        if unit.isEmpty {
            what = quantity == 1 ? "Reserve" : "Reserve \(quantity)"
        } else {
            let a = unit.first.map { "aeiou".contains($0.lowercased()) } ?? false ? "an" : "a"
            what = quantity == 1 ? "Reserve \(a) \(unit)" : "Reserve \(count(quantity, unit))"
        }
        return pay == .inApp ? "\(what) · \(Pricing.format(totalCents))" : "\(what) · pay at pickup"
    }

    /// Under the button, plainly.
    static func payLine(pay: PayMode, cook: String, totalCents: Int) -> String {
        pay == .inApp
            ? "Pay in the app with Apple Pay or a card. The exact address shows once it's paid."
            : "Pay \(cook) \(Pricing.format(totalCents)) at pickup. Paying in the app isn't set up for this kitchen yet."
    }

    /// On the pickup screen and the order.
    static func receipt(_ payment: PaymentState, totalCents: Int, cook: String) -> String {
        switch payment {
        case .atPickup: "Pay \(cook) \(Pricing.format(totalCents)) at pickup."
        case .paid: "Paid \(Pricing.format(totalCents)) in the app."
        case .unpaid: "Not paid yet. Pay to hold it; the hold lasts 15 minutes."
        case .refunded: "Refunded. It sold out before your payment came through."
        case .expired: "The hold ran out before it was paid. Reserve again if there are any left."
        }
    }

    /// "Ready at 7:45".
    static func ready(_ at: Date) -> String {
        "Ready at \(at.formatted(date: .omitted, time: .shortened))"
    }

    /// "482" → "4 8 2", easy to say at the door.
    static func spoken(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }

    /// "4-minute walk · ★ 4.9 (23) · 12 regulars".
    static func kitchenLine(walkMinutes: Int, rating: Double?, reviews: Int, regulars: Int) -> String {
        var parts = ["\(walkMinutes)-minute walk"]
        if let rating, reviews > 0 { parts.append(String(format: "★ %.1f (%d)", rating, reviews)) } else { parts.append("New") }
        if regulars > 0 { parts.append("\(regulars) regular\(regulars == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// "Dana's porch", "Dana's door".
    static func spot(_ spot: String, cook: String) -> String {
        "\(cook)'s \(spot == "door" ? "door" : "porch")"
    }
}

/// The batch's pickup slots: 15 minutes each across the window, minus full ones and ones gone by.
nonisolated enum BatchSlots {
    static let length: TimeInterval = 15 * 60

    static func all(start: Date, end: Date) -> [Date] {
        var out: [Date] = []
        var t = start
        while t < end {
            out.append(t)
            t = t.addingTimeInterval(length)
        }
        return out
    }

    static func open(start: Date, end: Date, full: [Date], now: Date) -> [Date] {
        let taken = Set(full.map { $0.timeIntervalSince1970.rounded() })
        return all(start: start, end: end).filter {
            $0.addingTimeInterval(length) >= now && !taken.contains($0.timeIntervalSince1970.rounded())
        }
    }
}

/// The photo: about 1200 px on the long side, never upscaled.
nonisolated enum PhotoPrep {
    static let longSide: CGFloat = 1200

    static func fit(_ size: CGSize, longSide: CGFloat = longSide) -> CGSize {
        let long = max(size.width, size.height)
        guard long > longSide, long > 0 else { return CGSize(width: size.width.rounded(), height: size.height.rounded()) }
        let scale = longSide / long
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
