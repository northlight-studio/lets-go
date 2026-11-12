import Testing
import Foundation
@testable import LetsGo

@Suite("Nothing old on the map")
struct UpcomingTests {
    let cal = Calendar.current

    /// November 2026: the 11th and 18th are Wednesdays, the 12th a Thursday.
    func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    func listing(_ schedule: String) throws -> CityListings.Listing {
        let json = """
        [{"title":"Thing","genre":"music","venue":"Club","address":"","lat":37.76,"lon":-122.42,
          "schedule":\(schedule),"price":"","organizer":"Club","url":"","description":"","confidence":"high"}]
        """
        return try #require(CityListings.decode(Data(json.utf8)).first)
    }

    func gathering(start: Date, end: Date, joined: Bool = false, checkedIn: Date? = nil, mine: Bool = false) -> Gathering {
        let g = Gathering(
            title: "Thing", category: .music, placeName: "Club", coordinate: .init(latitude: 37.76, longitude: -122.42),
            start: start, end: end, hostName: "Club", isMine: mine
        )
        g.isJoined = joined || mine
        g.checkedInAt = checkedIn
        return g
    }

    @Test func aOneOffThatEndedIsGone() throws {
        let show = try listing(#"{"date":"2026-11-11","start":"19:00","end":"22:00"}"#)
        // The next morning there's nothing to lay out, and a row left over is deleted.
        #expect(CityListings.occurrences(of: show, from: date(12, 9)).isEmpty)
        let g = gathering(start: date(11, 19), end: date(11, 22))
        #expect(!g.isShown(at: date(12, 9)))
        #expect(Upcoming.fate(of: g.upcoming, now: date(12, 9)) == .delete)
        // Even later the same evening, once it's over.
        #expect(Upcoming.fate(of: g.upcoming, now: date(11, 22, 1)) == .delete)
    }

    @Test func somethingEndingLaterTodayStaysUntilItEnds() throws {
        let market = try listing(#"{"date":"2026-11-12","start":"10:00","end":"14:00"}"#)
        // Before it starts, and while it's on.
        #expect(CityListings.occurrences(of: market, from: date(12, 9)).count == 1)
        #expect(CityListings.occurrences(of: market, from: date(12, 13, 59)).count == 1)
        #expect(CityListings.occurrences(of: market, from: date(12, 14)).isEmpty)
        let g = gathering(start: date(12, 10), end: date(12, 14))
        #expect(Upcoming.fate(of: g.upcoming, now: date(12, 13, 59)) == .show)
        #expect(Upcoming.fate(of: g.upcoming, now: date(12, 14)) == .delete)
    }

    @Test func pastMidnightStaysUntilItsEnd() throws {
        let late = try listing(#"{"date":"2026-11-11","start":"22:00","end":"01:00"}"#)
        // It started yesterday, but it's on: shown at 12:30, gone at 1:00.
        let on = CityListings.occurrences(of: late, from: date(12, 0, 30))
        #expect(on.count == 1)
        #expect(on.first?.end == date(12, 1))
        #expect(CityListings.occurrences(of: late, from: date(12, 1)).isEmpty)
        let g = gathering(start: date(11, 22), end: date(12, 1))
        #expect(g.isShown(at: date(12, 0, 30)))
        #expect(!g.isShown(at: date(12, 1, 30)))
    }

    @Test func aWeeklyOneMovesOnToNextWeek() throws {
        let trivia = try listing(#"{"weekday":"Wednesday","start":"19:00","end":"21:00"}"#)
        // Thursday: last night's is gone, next Wednesday's is first.
        let thursday = CityListings.occurrences(of: trivia, from: date(12, 9))
        #expect(thursday.first?.start == date(18, 19))
        #expect(thursday.allSatisfy { $0.end > date(12, 9) })
        // During next Wednesday's, it's that one; after it ends, the one after.
        #expect(CityListings.occurrences(of: trivia, from: date(18, 20, 30)).first?.start == date(18, 19))
        #expect(CityListings.occurrences(of: trivia, from: date(18, 21, 30)).first?.start == date(25, 19))
    }

    @Test func joinedAndCheckedInLeaveTheMapButStayInHistory() {
        let after = date(12, 9)
        let joined = gathering(start: date(11, 19), end: date(11, 22), joined: true)
        let checkedIn = gathering(start: date(11, 19), end: date(11, 22), checkedIn: date(11, 19, 10))
        let hosted = gathering(start: date(11, 19), end: date(11, 22), mine: true)
        for g in [joined, checkedIn, hosted] {
            #expect(!g.isShown(at: after))
            #expect(Upcoming.fate(of: g.upcoming, now: after) == .history)
        }
        // Before it ends, a joined one shows like anything else.
        #expect(Upcoming.fate(of: joined.upcoming, now: date(11, 20)) == .show)
    }

    @Test func prunesWhenTheNextThingEndsOrAtMidnight() {
        let now = date(12, 18)
        // The soonest end still ahead.
        #expect(Upcoming.nextPrune(ends: [date(12, 22), date(12, 19, 30), date(12, 17)], now: now, calendar: cal) == date(12, 19, 30))
        // Nothing ending before midnight: midnight, when weekly listings roll on.
        #expect(Upcoming.nextPrune(ends: [date(13, 1)], now: now, calendar: cal) == date(13, 0))
        #expect(Upcoming.nextPrune(ends: [], now: now, calendar: cal) == date(13, 0))
    }
}
