import Testing
import Foundation
import CoreLocation
@testable import LetsGo

/// Supper club: the host's form, where you stand with a supper, and the words on its page and pin.
@Suite("Supper club")
struct SupperTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    /// November 2026 in San Francisco: the 12th is a Thursday, the 15th a Sunday.
    func at(_ hour: Int, _ minute: Int = 0, day: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func supper(
        seats: Int = 6, taken: Int = 4, start: Date? = nil, mine: Bool = false, canceled: Bool = false,
        seat: SeatDTO? = nil, pay: String = "in_app"
    ) -> SupperDTO {
        let s = start ?? at(19, day: 15)
        return SupperDTO(
            id: UUID(), title: "Oaxacan night", startsAt: s, endsAt: s.addingTimeInterval(3 * 3600),
            seats: seats, taken: taken, seatsLeft: max(0, seats - taken), priceCents: 1800, serviceCents: 90,
            seatTotalCents: 1890, pay: pay, menu: [CourseDTO(name: "Tlayudas", note: "black beans, quesillo")],
            tags: ["Vegetarian option"], houseNotes: "", photoUrl: nil,
            host: PersonDTO(id: UUID(), displayName: "Ana Ruiz"), kitchenId: UUID(),
            suppersHosted: 14, hostRating: 4.9, hostReviewCount: 22, lat: 37.76, lon: -122.42, exact: false,
            address: nil, distanceM: 480, friendsGoing: [], isMine: mine, canceled: canceled, mySeat: seat,
            refundUntil: s.addingTimeInterval(-48 * 3600), waiting: 0, table: []
        )
    }

    func seat(_ status: SeatStatus, _ payment: SeatPayment, payBy: Date? = nil) -> SeatDTO {
        SeatDTO(id: UUID(), status: status.rawValue, payment: payment.rawValue, note: "", priceCents: 1800,
                serviceCents: 90, totalCents: 1890, payBy: payBy)
    }

    // MARK: Where you stand

    @Test func aNeighborCanAskWhileThereAreSeats() {
        let now = at(12)
        #expect(SeatStage.of(supper(), now: now) == .open)
        #expect(SeatStage.of(supper(taken: 6), now: now) == .full)
        #expect(SeatStage.of(supper(mine: true), now: now) == .hosting)
    }

    @Test func theHostChooses() {
        let now = at(12)
        #expect(SeatStage.of(supper(seat: seat(.asked, .none)), now: now) == .asked)
        #expect(SeatStage.of(supper(seat: seat(.declined, .none)), now: now) == .declined)
        let by = at(12, day: 13)
        #expect(SeatStage.of(supper(seat: seat(.accepted, .unpaid, payBy: by)), now: now) == .toPay(by: by))
        #expect(SeatStage.of(supper(seat: seat(.accepted, .paid)), now: now) == .going(atDoor: false))
        #expect(SeatStage.of(supper(seat: seat(.accepted, .atDoor)), now: now) == .going(atDoor: true))
    }

    @Test func backingOutOrRunningOutOfTimeOpensItAgain() {
        let now = at(12)
        #expect(SeatStage.of(supper(seat: seat(.withdrawn, .refunded)), now: now) == .open)
        #expect(SeatStage.of(supper(seat: seat(.lapsed, .unpaid)), now: now) == .open)
        #expect(SeatStage.of(supper(taken: 6, seat: seat(.lapsed, .unpaid)), now: now) == .full)
    }

    @Test func calledOffAndAfterwards() {
        let during = at(20, day: 15)
        #expect(SeatStage.of(supper(canceled: true), now: at(12)) == .canceled)
        #expect(SeatStage.of(supper(seat: seat(.accepted, .paid)), now: during) == .after)
        #expect(SeatStage.of(supper(mine: true), now: during) == .after)
        // Asked but never got a seat, or paying when it started: it's over for you.
        #expect(SeatStage.of(supper(seat: seat(.asked, .none)), now: during) == .over)
        #expect(SeatStage.of(supper(seat: seat(.accepted, .unpaid)), now: during) == .over)
        #expect(SeatStage.of(supper(), now: during) == .over)
    }

    // MARK: The form

    @Test func startsOnTheComingSunday() {
        let thursday = SupperDraft.starting(now: at(12), calendar: cal)
        #expect(cal.isDate(thursday.day, inSameDayAs: at(0, day: 15)))
        #expect(thursday.window(calendar: cal).start == at(19, day: 15))
        #expect(thursday.window(calendar: cal).end == at(22, day: 15))
        #expect(thursday.seats == 6)
        // On a Sunday morning it's tonight; on a Sunday evening, next week's.
        #expect(cal.isDate(SupperDraft.starting(now: at(10, day: 15), calendar: cal).day, inSameDayAs: at(0, day: 15)))
        #expect(cal.isDate(SupperDraft.starting(now: at(16, day: 15), calendar: cal).day, inSameDayAs: at(0, day: 22)))
    }

    @Test func whatsMissing() {
        let now = at(12)
        var d = SupperDraft.starting(now: now, calendar: cal)
        #expect(d.problem(now: now, needsAddress: true, needsPermit: true, calendar: cal) == "Give it a name, like \"Oaxacan night\".")
        d.title = "Oaxacan night"
        #expect(d.problem(now: now, needsAddress: true, needsPermit: true, calendar: cal) == "Add at least one course.")
        d.courses[1].name = "  Mole negro "
        d.courses[1].note = "chicken or squash"
        #expect(d.menu == [CourseDTO(name: "Mole negro", note: "chicken or squash")])
        #expect(d.problem(now: now, needsAddress: true, needsPermit: true, calendar: cal) == "Set a price a seat.")
        d.priceText = "$18"
        #expect(d.priceCents == 1800)
        #expect(d.problem(now: now, needsAddress: true, needsPermit: true, calendar: cal)?.hasPrefix("Add your address") == true)
        d.address = "3100 24th St"
        #expect(d.problem(now: now, needsAddress: true, needsPermit: true, calendar: cal) == "Confirm your home kitchen permit.")
        d.permitConfirmed = true
        #expect(d.problem(now: now, needsAddress: true, needsPermit: true, calendar: cal) == nil)
        // Already on file: not asked again.
        d.address = ""
        d.permitConfirmed = false
        #expect(d.problem(now: now, needsAddress: false, needsPermit: false, calendar: cal) == nil)
        d.day = at(0, day: 10)
        #expect(d.problem(now: now, needsAddress: false, needsPermit: false, calendar: cal) == "Pick a time that hasn't passed.")
    }

    @Test func pricesAreIntegerCentsAndCapped() {
        var d = SupperDraft(day: at(0))
        d.priceText = "18.50"
        #expect(d.priceCents == 1850)
        d.priceText = "501"
        #expect(d.priceCents == nil)
        d.priceText = "eighteen"
        #expect(d.priceCents == nil)
    }

    // MARK: Words

    @Test func whenAndWhere() {
        let now = at(12)
        #expect(SupperCopy.when(at(19, day: 15), now: now, calendar: cal) == "Sunday · 7 PM")
        #expect(SupperCopy.when(at(19, 30), now: now, calendar: cal) == "Tonight · 7:30 PM")
        #expect(SupperCopy.when(at(19, day: 13), now: now, calendar: cal) == "Tomorrow · 7 PM")
        #expect(SupperCopy.at("Ana Ruiz") == "at Ana's")
        #expect(SupperCopy.payBy(at(19, day: 13), now: now, calendar: cal) == "Pay by tomorrow 7 PM")
        #expect(SupperCopy.payBy(nil, now: now, calendar: cal) == nil)
    }

    @Test func theHostLine() {
        #expect(SupperCopy.hostLine(hosted: 14, rating: 4.9, reviews: 22, walkMinutes: 6) == "14 suppers hosted · ★ 4.9 · 6-minute walk")
        #expect(SupperCopy.hostLine(hosted: 0, rating: nil, reviews: 0, walkMinutes: 3) == "First supper · 3-minute walk")
        #expect(SupperCopy.hostLine(hosted: 1, rating: 5, reviews: 0, walkMinutes: nil) == "1 supper hosted")
    }

    @Test func seatsAndThePin() {
        #expect(SupperCopy.seatsLine(taken: 4, seats: 6, priceCents: 1800) == "4 of 6 seats · 2 left · $18 a seat")
        #expect(SupperCopy.seatsLine(taken: 0, seats: 6, priceCents: 1850) == "6 seats · $18.50 a seat")
        #expect(SupperCopy.seatsLine(taken: 6, seats: 6, priceCents: 1800) == "All 6 seats taken · $18 a seat")
        #expect(SupperCopy.seatsTag(left: 2) == "2 seats")
        #expect(SupperCopy.seatsTag(left: 1) == "1 seat")
        #expect(SupperCopy.seatsTag(left: 0) == "Full")
        let pin = Candidate(supper(), from: CLLocationCoordinate2D(latitude: 37.76, longitude: -122.42))
        #expect(pin.kind == .supper && pin.place == "at Ana's")
        #expect(Pins.tag(pin) == "2 seats")
        #expect(MapLayer.food.keeps(pin) && !MapLayer.events.keeps(pin))
    }

    @Test func friendsGoing() {
        #expect(SupperCopy.friendsGoing(["Maya Chen"]) == "Maya is going")
        #expect(SupperCopy.friendsGoing(["Maya", "Theo"]) == "Maya and Theo are going")
        #expect(SupperCopy.friendsGoing(["Maya", "Theo", "Jun"]) == "Maya, Theo and Jun are going")
    }

    @Test func whatAskingMeans() {
        let now = at(12)
        let inApp = SupperCopy.askLine(host: "Ana", totalCents: 1890, inApp: true, refundUntil: at(19, day: 13), now: now, calendar: cal)
        #expect(inApp == "Ana chooses who comes. If Ana says yes, you pay $18.90 in the app and get the address. Back out by tomorrow 7 PM for all of it back; after that the seat goes back, the money doesn't.")
        let door = SupperCopy.askLine(host: "Ana", totalCents: 1800, inApp: false, refundUntil: at(19, day: 13), now: now, calendar: cal)
        #expect(door.contains("pay $18 at the door"))
        #expect(SupperCopy.refundRule(at(11), now: now, calendar: cal).hasPrefix("It's within two days"))
    }

    @Test func aServerWithoutSuppersSaysSo() {
        typealias F = ServerFeatures.Feature
        #expect(F.owning("/v1/suppers") == .suppers)
        #expect(F.owning("/v1/supper-seats/\(UUID().uuidString)/pay") == .suppers)
        #expect(F.owning("/v1/me/suppers") == .suppers)
        #expect(F.owning("/v1/orders/\(UUID().uuidString)/pay") == .selling)
        #expect(F.missing(in: ["/v1/nearby"]).contains(.suppers))
    }

    @Test func theHostSeesWhoIsAsking() {
        #expect(SupperCopy.guestLine(attended: 0, rating: nil, reviews: 0) == "New to suppers")
        #expect(SupperCopy.guestLine(attended: 3, rating: 4.8, reviews: 5) == "3 suppers · ★ 4.8 from 5")
        #expect(SupperCopy.hostSeats(taken: 4, seats: 6, waiting: 2) == "4 of 6 seats given · 2 asking")
        #expect(SupperCopy.stageLine(.hosting, host: "Ana", waiting: 1) == "1 neighbor is asking for a seat.")
        #expect(SupperCopy.stageLine(.asked, host: "Ana Ruiz") == "You asked. Ana will say yes or no; you'll see it here.")
    }
}
