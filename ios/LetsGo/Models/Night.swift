import Foundation
import SwiftData

/// One night out, from the first place you showed up until you went home: where you were,
/// who with, how far you walked, and how long Let's Go was open in your hand. Kept on
/// this phone only; it's what "You're here" and the morning after are made of.
@Model
final class Night {
    var id: UUID
    /// The evening it belongs to (`NightMath.evening`), so 1 AM still counts as last night.
    var evening: Date
    var startedAt: Date
    var lastActiveAt: Date
    var walkedMeters: Double
    /// Seconds Let's Go was open and lit during the night.
    var phoneSeconds: Double
    /// Each time you picked it up.
    var glances: [Date]
    var stops: [NightStop]
    var darkUntil: Date?
    var recapSeenAt: Date?

    init(evening: Date, startedAt: Date) {
        self.id = UUID()
        self.evening = evening
        self.startedAt = startedAt
        self.lastActiveAt = startedAt
        self.walkedMeters = 0
        self.phoneSeconds = 0
        self.glances = []
        self.stops = []
    }
}

/// A place you showed up during a night.
struct NightStop: Codable, Hashable, Sendable {
    var title: String
    var genreRaw: String
    var arrivedAt: Date
    /// Friends there with you (`Person.id`s) and their names, kept so the recap still reads after they change.
    var withIDs: [UUID] = []
    var withNames: [String] = []
    /// A stop at something from the old sample neighborhood. Only `SamplePurge` reads it.
    var isSample = false

    var genre: Genre { Genre(rawValue: genreRaw) ?? .party }
}

/// The arithmetic of a night. Plain functions, so they're tested.
enum NightMath {
    /// Nights run 5 AM to 5 AM: the evening a moment belongs to.
    static func evening(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(-5 * 3600))
    }

    /// Going dark lasts a couple of hours, to the next whole hour: "Go dark until 11".
    static func darkUntil(from now: Date, calendar: Calendar = .current) -> Date {
        let later = now.addingTimeInterval(90 * 60)
        let hour = calendar.dateInterval(of: .hour, for: later)?.end ?? later
        return hour
    }

    /// The morning after: a night with somewhere in it, the next day before 3 PM, not seen yet.
    static func wantsRecap(evening: Date, stops: Int, seen: Bool, now: Date, calendar: Calendar = .current) -> Bool {
        guard stops > 0, !seen else { return false }
        guard let next = calendar.date(byAdding: .day, value: 1, to: evening) else { return false }
        guard calendar.isDate(now, inSameDayAs: next) else { return false }
        let hour = calendar.component(.hour, from: now)
        return hour >= 5 && hour < 15
    }

    /// The ribbon: one colored stretch per place, from when you got there to the next place
    /// (or the end), with the walks between left gray. Fractions of the whole night, 0...1.
    struct Segment: Equatable, Sendable {
        var title: String
        var genre: Genre?
        var from: Double
        var to: Double
    }

    static func ribbon(stops: [NightStop], start: Date, end: Date) -> [Segment] {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return [] }
        func f(_ d: Date) -> Double { min(1, max(0, d.timeIntervalSince(start) / total)) }
        let sorted = stops.sorted { $0.arrivedAt < $1.arrivedAt }
        var out: [Segment] = []
        var cursor = 0.0
        for (i, s) in sorted.enumerated() {
            let a = f(s.arrivedAt)
            if a > cursor + 0.001 { out.append(Segment(title: "", genre: nil, from: cursor, to: a)) }
            // Each stay ends a short walk before the next place, or at the end of the night.
            let next = i + 1 < sorted.count ? f(sorted[i + 1].arrivedAt) : 1
            let b = i + 1 < sorted.count ? max(a, next - 0.03) : 1
            out.append(Segment(title: s.title, genre: s.genre, from: a, to: b))
            cursor = b
        }
        if cursor < 0.999 { out.append(Segment(title: "", genre: nil, from: cursor, to: 1)) }
        return out
    }

    /// "7h 20m", "45m".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// "2:36:12": the time-out clock.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 3600):\(String(format: "%02d", (s % 3600) / 60)):\(String(format: "%02d", s % 60))"
    }

    static func miles(_ meters: Double) -> String {
        (meters / 1609.34).formatted(.number.precision(.fractionLength(1)))
    }
}
