import Foundation

/// What's still worth showing, what the store keeps, and when to look again. Plain rules, so
/// they're tested (`UpcomingTests`).
///
/// - Anything that has ended is off the map, the lists, Wren's pick and Plans' upcoming
///   sections: listings, server gatherings, things you host and things you joined. Something on
///   now stays until it ends, so a set that started last night and runs past midnight is still
///   there at 12:30 and gone at its end. Nothing from a past day is ever shown: by then it's over.
/// - Once ended, what you joined, checked in to or host stays in the store for your history
///   (Passport, the morning after); everything else is deleted.
/// - The app prunes on launch, on coming back, and while it's open: when the next thing on show
///   ends, and at midnight, when weekly listings roll on to a new day.
enum Upcoming {
    /// The parts of a thing the rules look at.
    struct Item: Sendable, Equatable {
        var start: Date
        var end: Date
        var joined = false
        var checkedIn = false
        var mine = false
    }

    enum Fate: Equatable, Sendable {
        /// Not over: shown.
        case show
        /// Over, but yours: kept for your history, never shown as something to go to.
        case history
        /// Over and nothing to do with you: deleted.
        case delete
    }

    static func isShown(end: Date, now: Date) -> Bool { end > now }

    static func isShown(_ item: Item, now: Date) -> Bool { isShown(end: item.end, now: now) }

    static func fate(of item: Item, now: Date) -> Fate {
        if isShown(item, now: now) { return .show }
        return item.joined || item.checkedIn || item.mine ? .history : .delete
    }

    /// When what's shown next changes: the soonest end still ahead, or midnight, whichever comes
    /// first. Never sooner than a second from now, so a timer can't spin.
    static func nextPrune(ends: [Date], now: Date, calendar: Calendar = .current) -> Date {
        let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(24 * 3600)
        let soonest = ends.filter { $0 > now }.min() ?? midnight
        return max(min(soonest, midnight), now.addingTimeInterval(1))
    }
}

extension Gathering {
    var upcoming: Upcoming.Item {
        Upcoming.Item(start: start, end: end, joined: isJoined, checkedIn: checkedInAt != nil, mine: isMine)
    }

    func isShown(at now: Date) -> Bool { Upcoming.isShown(upcoming, now: now) }
}
