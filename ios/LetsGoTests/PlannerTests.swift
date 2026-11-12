import Testing
import Foundation
import CoreLocation
@testable import LetsGo

@Suite("Wren plans for a group")
struct PlannerTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    /// October 2026: the 27th is a Tuesday, the 31st (Halloween) a Saturday.
    func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }

    var now: Date { date(27, 15) }
    let here = CLLocationCoordinate2D(latitude: 37.7596, longitude: -122.4269)

    func friend(_ name: String, free: Int?) -> Friend {
        Friend(id: UUID(), name: name, freeAfterHour: free)
    }

    func event(_ title: String, _ genre: Genre, day: Int, hour: Int, east: Double, north: Double, price: String = "") -> Candidate {
        let at = here.offset(east: east, north: north)
        return Candidate(
            id: UUID(), kind: .gathering, title: title, category: genre,
            start: date(day, hour), end: date(day, hour + 3), meters: here.distance(to: at),
            place: "22nd St", priceText: price, lat: at.latitude, lon: at.longitude
        )
    }

    // MARK: Reading the sentence

    @Test func namesAndADayMakeAPlan() throws {
        let maya = friend("Maya", free: 14), theo = friend("Theo", free: 16), jun = friend("Jun", free: 12)
        let r = try #require(PlanRequest.parse("something with Maya and Theo saturday", friends: [maya, theo, jun], now: now, calendar: cal))
        #expect(Set(r.friendIDs) == [maya.id, theo.id])
        #expect(r.day == cal.startOfDay(for: date(31, 12)))
        #expect(r.fromHour == nil)
    }

    @Test func timesAndAccentsAreRead() throws {
        let lucia = friend("Lucía", free: nil)
        let r = try #require(PlanRequest.parse("dinner with lucia after 6, done by 10", friends: [lucia], now: now, calendar: cal))
        #expect(r.friendIDs == [lucia.id])
        #expect(r.fromHour == 18)
        #expect(r.untilHour == 22)
    }

    @Test func aMoodIsNotAPlan() {
        #expect(PlanRequest.parse("live music tonight", friends: [friend("Maya", free: nil)], now: now, calendar: cal) == nil)
    }

    @Test func aCrewByName() throws {
        let maya = friend("Maya", free: nil), ben = friend("Ben", free: nil)
        let r = try #require(PlanRequest.parse("plan something for tuesday trivia", friends: [maya, ben],
                                               crews: [(name: "Tuesday trivia", memberIDs: [maya.id, ben.id])], now: now, calendar: cal))
        #expect(Set(r.friendIDs) == [maya.id, ben.id])
    }

    // MARK: Making the plan

    func halloween() -> (PlanRequest, [Friend], [Candidate], [DropSlot], [OutsideSpot]) {
        let maya = friend("Maya", free: 14), theo = friend("Theo", free: 17)
        let r = PlanRequest(text: "something with Maya and Theo saturday", friendIDs: [maya.id, theo.id],
                            day: cal.startOfDay(for: date(31, 12)), fromHour: nil, untilHour: nil)
        let show = event("Ghoul's Night Out", .music, day: 31, hour: 19, east: 300, north: -200, price: "$15")
        let run = event("Morning run", .move, day: 31, hour: 8, east: 100, north: 100)
        let park = here.offset(east: -150, north: -100)
        let tamales = DropSlot(kitchenID: UUID(), name: "Rosa's Tamales", cuisine: "Tamales", start: date(31, 16),
                               end: date(31, 19), left: 30, priceFromCents: 1600, latitude: park.latitude - 0.002,
                               longitude: park.longitude)
        let dolores = OutsideSpot(title: "Dolores Park", area: "Mission", latitude: park.latitude, longitude: park.longitude)
        return (r, [maya, theo], [show, run], [tamales], [dolores])
    }

    @Test func halloweenIsSorted() throws {
        let (r, friends, events, drops, outside) = halloween()
        let plan = try #require(Planner.plan(
            r, friends: friends, events: events, drops: drops, outside: outside, here: here,
            sunset: date(31, 18, 7), taste: Taste(), now: now, calendar: cal, clock: { _ in "T" }
        ))
        #expect(plan.title == "Halloween, sorted.")
        #expect(plan.stops.map(\.kind) == [.food, .outside, .event])
        #expect(plan.stops.map(\.title) == ["Rosa's Tamales", "Dolores Park", "Ghoul's Night Out"])
        // Food on the kitchen's own pickup grid, everything in order, walks between each.
        #expect(plan.stops[0].start == date(31, 16))
        #expect(plan.stops[1].start < plan.stops[2].start)
        #expect(plan.legs.count == 2)
        #expect(plan.checks.count == 4)
        #expect(plan.checks[0].title == "Maya's free after 2, Theo after 5")
        #expect(plan.checks[1].title.contains("Halloween"))
        #expect(plan.reply.hasSuffix("Want me to ask Maya and Theo?"))
        // Theo's free later than the plan starts, so he meets everyone at the show.
        #expect(plan.note.contains("Theo's free after 5, so they'll meet you at Ghoul's Night Out."))
    }

    @Test func anotherSkipsWhatWasOffered() throws {
        let (r, friends, events, drops, outside) = halloween()
        let first = try #require(Planner.plan(r, friends: friends, events: events, drops: drops, outside: outside, here: here,
                                              sunset: nil, taste: Taste(), now: now, calendar: cal))
        let offered = Set(first.stops.compactMap(\.gatheringID))
        let second = Planner.plan(r, friends: friends, events: events, drops: drops, outside: outside, here: here,
                                  sunset: nil, taste: Taste(), excluding: offered, now: now, calendar: cal)
        // The only other thing that day is the morning run, which ended before anyone's free.
        #expect(second == nil)
    }

    @Test func doneBySevenStillFindsTheShow() {
        var (r, friends, events, drops, outside) = halloween()
        r.untilHour = 19
        let plan = Planner.plan(r, friends: friends, events: events, drops: drops, outside: outside, here: here,
                                sunset: nil, taste: Taste(), now: now, calendar: cal)
        // The show starts at 7 and the plan has to be done by 7: nothing fits inside, so Wren
        // falls back to what's still on after the start time.
        #expect(plan?.stops.last?.title == "Ghoul's Night Out")
    }

    @Test func holidays() {
        #expect(Planner.holiday(on: date(31, 12), calendar: cal) == "Halloween")
        #expect(Planner.holiday(on: date(30, 12), calendar: cal) == nil)
        #expect(Planner.hourText(14) == "2")
        #expect(Planner.hourText(12) == "noon")
    }
}
