import Testing
import Foundation
@testable import LetsGo

@Suite("The map as a timetable")
struct TimetableTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    let en = Locale(identifier: "en_US")

    /// November 2026: the 12th is a Thursday.
    func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = d; c.hour = h; c.minute = m
        return cal.date(from: c)!
    }

    func thing(
        _ title: String, start: Date, hours: Double = 2, lat: Double = 37.7599, lon: Double = -122.4214,
        kind: Candidate.Kind = .gathering, genre: Genre = .music, price: String = "", meters: Double = 600
    ) -> Candidate {
        Candidate(
            id: UUID(), kind: kind, title: title, category: genre,
            start: start, end: start.addingTimeInterval(hours * 3600), meters: meters,
            place: "Valencia St", priceText: price, lat: lat, lon: lon
        )
    }

    // MARK: Days

    @Test func aThursdayCanLookAtTomorrowAndTheWeekend() {
        let days = Timetable.days(now: date(12, 18), calendar: cal)
        #expect(days == [date(12, 0), date(13, 0), date(14, 0), date(15, 0)])
        #expect(days.map { Timetable.label($0, now: date(12, 18), calendar: cal, locale: en) } == ["Today", "Tomorrow", "Saturday", "Sunday"])
    }

    @Test func aSaturdayIsTodayAndSunday() {
        #expect(Timetable.days(now: date(14, 11), calendar: cal) == [date(14, 0), date(15, 0)])
    }

    @Test func aSundayLooksAtMondayAndTheNextWeekend() {
        #expect(Timetable.days(now: date(15, 11), calendar: cal) == [date(15, 0), date(16, 0)])
        #expect(Timetable.days(now: date(16, 11), calendar: cal) == [date(16, 0), date(17, 0), date(21, 0), date(22, 0)])
    }

    // MARK: The rail

    @Test func todaysRailRunsFromNowUntilTwo() {
        let span = Timetable.span(for: date(12, 0), now: date(12, 17, 41), calendar: cal)
        #expect(span.lowerBound == date(12, 17, 41))
        #expect(span.upperBound == date(13, 2))
    }

    @Test func justAfterMidnightTonightStillEndsAtTwo() {
        #expect(Timetable.span(for: date(13, 0), now: date(13, 0, 30), calendar: cal).upperBound == date(13, 2))
        // Too close to two: the rail runs to tomorrow night's instead.
        #expect(Timetable.span(for: date(13, 0), now: date(13, 1, 30), calendar: cal).upperBound == date(14, 2))
    }

    @Test func anotherDayRunsFromFiveUntilTwo() {
        let span = Timetable.span(for: date(14, 0), now: date(12, 18), calendar: cal)
        #expect(span == date(14, 5)...date(15, 2))
    }

    @Test func ticksStartWithNowAndLabelWhatFits() {
        let span = Timetable.span(for: date(12, 0), now: date(12, 17, 41), calendar: cal)
        let ticks = Timetable.ticks(span, isToday: true, calendar: cal, locale: en)
        #expect(ticks.first?.label == "Now")
        #expect(ticks.first?.fraction == 0)
        // 6 PM to 2 AM: nine hours, labelled every other hour to fit, and 6 gives "Now" its room.
        #expect(ticks.count == 10)
        #expect(ticks.compactMap(\.label) == ["Now", "8", "10", "12", "2"])
        #expect(ticks.last?.fraction == 1)
        #expect(ticks.map(\.fraction) == ticks.map(\.fraction).sorted())
    }

    @Test func aLateRailLabelsEveryHour() {
        let span = Timetable.span(for: date(12, 0), now: date(12, 21, 10), calendar: cal)
        let labels = Timetable.ticks(span, isToday: true, calendar: cal, locale: en).compactMap(\.label)
        #expect(labels == ["Now", "10", "11", "12", "1", "2"])
    }

    @Test func draggingSnapsToTheHalfHour() {
        let span = date(14, 5)...date(15, 2)
        #expect(Timetable.until(at: 0.5, in: span, calendar: cal) == date(14, 15, 30))
        #expect(Timetable.until(at: 0.99, in: span, calendar: cal) == date(15, 2))
        // Never shorter than a half hour.
        #expect(Timetable.until(at: 0, in: span, calendar: cal) == date(14, 5, 30))
        #expect(Timetable.fraction(of: date(14, 15, 30), in: span) == 0.5)
    }

    @Test func todayOpensOnTheNextThreeHoursWhenThereIsEnough() {
        let now = date(12, 17, 41)
        let busy = [19, 20, 20, 23].map { thing("Set", start: date(12, $0)) }
        #expect(Timetable.defaultUntil(busy, day: date(12, 0), now: now, calendar: cal) == date(12, 21))
        // Only one by nine and more later: look until late instead.
        let quiet = [19, 22, 23].map { thing("Set", start: date(12, $0)) }
        #expect(Timetable.defaultUntil(quiet, day: date(12, 0), now: now, calendar: cal) == date(13, 2))
        // Another day: all of it.
        #expect(Timetable.defaultUntil(busy, day: date(14, 0), now: now, calendar: cal) == date(15, 2))
    }

    // MARK: The window

    @Test func theWindowIsOnNowPlusWhatStartsBeforeTheThumb() {
        let now = date(12, 18)
        let span = Timetable.span(for: date(12, 0), now: now, calendar: cal)
        let on = thing("Happy hour", start: date(12, 17), hours: 3)
        let soon = thing("Jazz jam", start: date(12, 19, 30))
        let later = thing("Late set", start: date(12, 22))
        let over = thing("Market", start: date(12, 10), hours: 4)
        let tomorrow = thing("Brunch", start: date(13, 11))
        let shown = Timetable.window([later, tomorrow, soon, over, on], span: span, until: date(12, 20), now: now)
        #expect(shown.map(\.title) == ["Happy hour", "Jazz jam"])
        let all = Timetable.window([later, tomorrow, soon, over, on], span: span, until: span.upperBound, now: now)
        #expect(all.map(\.title) == ["Happy hour", "Jazz jam", "Late set"])
    }

    @Test func anotherDayShowsOnlyWhatStartsThatDay() {
        let now = date(12, 18)
        let span = Timetable.span(for: date(13, 0), now: now, calendar: cal)
        let on = thing("Happy hour", start: date(12, 17), hours: 30)
        let friday = thing("Brunch", start: date(13, 11))
        let fridayNight = thing("Club night", start: date(14, 0, 30))
        let saturday = thing("Market", start: date(14, 9))
        let shown = Timetable.window([saturday, on, fridayNight, friday], span: span, until: span.upperBound, now: now)
        #expect(shown.map(\.title) == ["Brunch", "Club night"])
    }

    @Test func kindAndFreeNarrowTheWindow() {
        let now = date(12, 18)
        let span = Timetable.span(for: date(12, 0), now: now, calendar: cal)
        let jam = thing("Jazz jam", start: date(12, 19), price: "$10")
        let run = thing("Run club", start: date(12, 19), genre: .move)
        #expect(Timetable.window([jam, run], span: span, until: span.upperBound, now: now, genre: .music).map(\.title) == ["Jazz jam"])
        #expect(Timetable.window([jam, run], span: span, until: span.upperBound, now: now, freeOnly: true).map(\.title) == ["Run club"])
    }

    @Test func countsAndUntil() {
        #expect(Timetable.countLine(0) == "Nothing yet")
        #expect(Timetable.countLine(1) == "1 thing")
        #expect(Timetable.countLine(14) == "14 things")
        let span = date(12, 18)...date(13, 2)
        #expect(Timetable.untilLine(date(12, 20), span: span, calendar: cal, locale: en) == "until 8")
        #expect(Timetable.untilLine(date(12, 20, 30), span: span, calendar: cal, locale: en) == "until 8:30")
        #expect(Timetable.untilLine(date(13, 2), span: span, calendar: cal, locale: en) == "until late")
    }

    @Test func tagsAreStartTimesOrNow() {
        let now = date(12, 18)
        #expect(Timetable.tag(thing("Jam", start: date(12, 19, 30)), now: now, calendar: cal, locale: en) == "7:30")
        #expect(Timetable.tag(thing("Set", start: date(12, 20)), now: now, calendar: cal, locale: en) == "8:00")
        #expect(Timetable.tag(thing("Happy hour", start: date(12, 17)), now: now, calendar: cal, locale: en) == "Now")
    }

    // MARK: Merging

    @Test func tagsOnTopOfEachOtherMergeIntoACount() {
        let now = date(12, 18)
        let a = thing("Jam", start: date(12, 19))
        let b = thing("Late set", start: date(12, 21), lat: 37.75992, lon: -122.42142)
        let far = thing("Trivia", start: date(12, 20), lat: 37.7801, lon: -122.4101)
        let groups = Timetable.merge([b, far, a], zoom: 14, now: now)
        #expect(groups.count == 2)
        let merged = groups.first { !$0.isSingle }
        #expect(merged?.members.map(\.title) == ["Jam", "Late set"])
        #expect(merged?.id.hasPrefix("g:") == true)
        // The earlier one anchors the count.
        #expect(merged?.latitude == a.lat)
    }

    @Test func zoomingInPullsThemApart() {
        let now = date(12, 18)
        // About 60 m apart.
        let a = thing("Jam", start: date(12, 19))
        let b = thing("Late set", start: date(12, 21), lat: 37.7599, lon: -122.4207)
        #expect(Timetable.merge([a, b], zoom: 13, now: now).count == 1)
        #expect(Timetable.merge([a, b], zoom: 18, now: now).count == 2)
    }

    @Test func whatsOnNowLeadsAndTheTappedOneNeverMerges() {
        let now = date(12, 18)
        let later = thing("Late set", start: date(12, 21))
        let on = thing("Happy hour", start: date(12, 17), hours: 3, lat: 37.75991)
        let merged = Timetable.merge([later, on], zoom: 14, now: now)
        #expect(merged.count == 1)
        #expect(merged.first?.members.first?.title == "Happy hour")
        let tapped = Timetable.merge([later, on], zoom: 14, now: now, selected: later.id)
        #expect(tapped.count == 2)
        #expect(tapped.first { $0.members.first?.id == later.id }?.isSingle == true)
    }

    @Test func aSingleTagKeepsItsIDAcrossZooms() {
        let now = date(12, 18)
        let a = thing("Jam", start: date(12, 19))
        #expect(Timetable.merge([a], zoom: 12, now: now).first?.id == a.id.uuidString)
        #expect(Timetable.mergeZoom(14.37) == 14.25)
    }

    // MARK: The card

    @Test func thenNearbyIsTheNextThingCloseBy() {
        let jam = thing("Jazz jam", start: date(12, 20))
        let lateSet = thing("Late set", start: date(12, 21), lat: 37.7601)
        let earlier = thing("Happy hour", start: date(12, 19), lat: 37.7600)
        let farAway = thing("Trivia", start: date(12, 20, 30), lat: 37.79)
        let tomorrow = thing("Brunch", start: date(13, 11), lat: 37.7600)
        let next = Timetable.thenNearby(after: jam, in: [tomorrow, farAway, lateSet, earlier, jam])
        #expect(next?.title == "Late set")
        #expect(Timetable.thenNearby(after: lateSet, in: [jam, earlier]) == nil)
        #expect(Timetable.nearbyLine(lateSet, from: jam) == "Late set · 1-minute walk")
    }

    @Test func theCardSaysWhereTheWalkAndThePrice() {
        let now = date(12, 18)
        let clock: (Date) -> String = { _ in "T" }
        let jam = thing("Jazz jam", start: date(12, 20), price: "$10", meters: 720)
        #expect(Timetable.cardLine(jam, now: now, clock: clock) == "Valencia St · 9-minute walk · $10")
        #expect(Timetable.cardLine(jam, now: now, walkMinutes: 11, clock: clock) == "Valencia St · 11-minute walk · $10")
        let on = thing("Happy hour", start: date(12, 17), meters: 400)
        #expect(Timetable.cardLine(on, now: now, clock: clock) == "On till T · Valencia St · 5-minute walk · Free")
    }
}
