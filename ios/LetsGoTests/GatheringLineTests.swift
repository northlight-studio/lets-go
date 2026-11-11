import Testing
import Foundation
@testable import LetsGo

@Suite("The top of a gathering's page")
struct GatheringLineTests {
    let clock: (Date) -> String = { _ in "T" }
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func eyebrowSaysWhenInWords() {
        let now = at(11, 15) // Wednesday 3 PM
        #expect(GatheringLine.eyebrow(start: at(11, 18, 45), end: at(11, 20), now: now, calendar: calendar, clock: clock) == "Tonight · T")
        #expect(GatheringLine.eyebrow(start: at(11, 16), end: at(11, 17), now: now, calendar: calendar, clock: clock) == "Today · T")
        #expect(GatheringLine.eyebrow(start: at(12, 18), end: at(12, 20), now: now, calendar: calendar, clock: clock) == "Tomorrow · T")
        #expect(GatheringLine.eyebrow(start: at(11, 14), end: at(11, 17), now: now, calendar: calendar, clock: clock) == "On now · till T")
        let thursday = GatheringLine.eyebrow(start: at(13, 18, 45), end: at(13, 20), now: now, calendar: calendar, clock: clock)
        #expect(thursday.hasSuffix(" · T"))
        #expect(!thursday.hasPrefix("Tomorrow"))
    }

    @Test func whereLineHasThePlaceAndTheWalk() {
        #expect(GatheringLine.whereLine(place: "By the tennis courts", meters: 480) == "By the tennis courts · 6-minute walk")
        #expect(GatheringLine.whereLine(place: "", meters: 480) == "6-minute walk")
    }

    @Test func friendOnTheWayCard() {
        let leave = at(11, 18, 30)
        let meet = MeetUp(friendID: UUID(), friendName: "Maya", leave: leave, meetAt: leave.addingTimeInterval(120),
                          latitude: 0, longitude: 0, extraMinutes: 1)
        let card = GatheringLine.onTheWay(meet, clock: clock)
        #expect(card.title == "Maya's on the way")
        #expect(card.detail == "Two minutes from you. Leave at T and walk in together?")
    }

    @Test func shareCarriesThePosterLink() {
        #expect(GatheringLine.share(title: "Pickup soccer", eyebrow: "Tonight · T", place: "Dolores Park", link: nil)
            == "Pickup soccer, Tonight · T at Dolores Park")
        #expect(GatheringLine.share(title: "Run", eyebrow: "Tonight · T", place: "", link: "https://x.y/p/abc")
            == "Run, Tonight · T\nhttps://x.y/p/abc")
    }
}
