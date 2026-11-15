import Testing
import Foundation
@testable import LetsGo

@Suite("Right now")
struct RightNowTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func candidate(_ title: String, _ category: Genre = .play, startsIn minutes: Double, meters: Double = 400,
                   capacity: Int = 0, going: Int = 0) -> Candidate {
        Candidate(id: UUID(), kind: .gathering, title: title, category: category,
                  start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + 90) * 60),
                  meters: meters, capacity: capacity, going: going)
    }

    @Test func withoutFitsItIsExactlyPicks() {
        let all = [candidate("Near", startsIn: 10, meters: 100), candidate("Far", startsIn: 10, meters: 1400),
                   candidate("Later", startsIn: 150), candidate("Soon", startsIn: 30)]
        let plain = Picks.picks(all, now: now, taste: Taste())
        let three = RightNow.picks(all, now: now, taste: Taste(), fits: [:])
        #expect(three.map(\.title) == plain.map(\.title))
    }

    @Test func aGoodFitLiftsAThingOverACloserOne() {
        let near = candidate("Kids craft morning", startsIn: 10, meters: 100)
        let jazz = candidate("Jazz trio", .music, startsIn: 20, meters: 500)
        let three = RightNow.picks([near, jazz], now: now, taste: Taste(), fits: [jazz.id: 0.94, near.id: 0.0])
        #expect(three.first?.title == "Jazz trio")
    }

    @Test func whatHasEndedOrIsFullIsNeverPickedHoweverWellItFits() {
        let over = candidate("Over", startsIn: -200)
        let full = candidate("Full", startsIn: 10, capacity: 4, going: 4)
        let far = candidate("Tomorrow", startsIn: 600)
        let open = candidate("Open", startsIn: 10)
        let fits = [over.id: 1.0, full.id: 1.0, far.id: 1.0, open.id: 0.0]
        let three = RightNow.picks([over, full, far, open], now: now, taste: Taste(), fits: fits)
        #expect(three.map(\.title) == ["Open"])
    }

    @Test func onlyWhatPicksWouldConsiderIsSentToBeScored() {
        let all = [candidate("Open", startsIn: 10), candidate("Over", startsIn: -200), candidate("Tomorrow", startsIn: 600)]
        #expect(RightNow.eligible(all, now: now, taste: Taste()).map(\.title) == ["Open"])
    }

    @Test func theBodyCarriesEachThingByItsOwnID() {
        var supper = candidate("Dal and rice", .food, startsIn: 15)
        supper.kind = .supper
        supper.place = "Amina's kitchen"
        supper.priceFromCents = 900
        let body = RightNow.body(for: [supper], localTime: "Saturday 7:40 PM", notes: ["Into music"], wentTo: ["Sofar Sounds"])
        let expected = RightNowThingDTO(key: supper.id.uuidString, title: "Dal and rice", kind: "supper",
                                        genre: "food", place: "Amina's kitchen", price: "$9")
        #expect(body.things == [expected])
        #expect(body.taste == ["Into music"])
        #expect(body.wentTo == ["Sofar Sounds"])
    }

    @Test func aPriceInWordsWinsOverCents() {
        var gig = candidate("Jazz trio", .music, startsIn: 15)
        gig.priceText = "$10 at the door"
        gig.priceFromCents = 1250
        #expect(RightNow.thing(gig).price == "$10 at the door")
        gig.priceText = ""
        #expect(RightNow.thing(gig).price == "$12.50")
    }

    @Test func fitsComeBackByIDAndStayBetweenZeroAndOne() {
        let id = UUID()
        let dto = RightNowDTO(scored: true, fits: [
            RightNowFitDTO(key: id.uuidString, fit: 1.4),
            RightNowFitDTO(key: "not-an-id", fit: 0.5),
        ])
        #expect(RightNow.fits(from: dto) == [id: 1.0])
    }

    @Test func theTimeIsSaidInThePhonesOwnZone() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        // 2027-01-15 08:00 UTC is just after midnight on Friday in San Francisco.
        let text = RightNow.localTime(now, timeZone: zone)
        #expect(text.hasPrefix("Friday"))
        #expect(text.hasSuffix("AM"))
    }
}
