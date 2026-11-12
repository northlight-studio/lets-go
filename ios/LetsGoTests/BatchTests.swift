import Testing
import Foundation
import CoreGraphics
@testable import LetsGo

/// Post a batch, sell to your neighbors: the form, the window, the words, the slots and the photo size.
@Suite("Selling a batch")
struct BatchTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    /// Thursday 12 November 2026 at the given local time.
    func at(_ hour: Int, _ minute: Int = 0, day: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    // MARK: Price

    @Test func pricesAreIntegerCents() {
        #expect(BatchDraft.cents(from: "6") == 600)
        #expect(BatchDraft.cents(from: "$6") == 600)
        #expect(BatchDraft.cents(from: "6.5") == 650)
        #expect(BatchDraft.cents(from: "6.50") == 650)
        #expect(BatchDraft.cents(from: " 12.05 ") == 1205)
        #expect(BatchDraft.cents(from: ".75") == 75)
    }

    @Test func notAPrice() {
        #expect(BatchDraft.cents(from: "") == nil)
        #expect(BatchDraft.cents(from: "0") == nil)
        #expect(BatchDraft.cents(from: "six") == nil)
        #expect(BatchDraft.cents(from: "6.505") == nil)
        #expect(BatchDraft.cents(from: "1.2.3") == nil)
        #expect(BatchDraft.cents(from: "-3") == nil)
        #expect(BatchDraft.cents(from: "1001") == nil)
    }

    // MARK: The window

    @Test func tonightSevenToNine() throws {
        let d = BatchDraft()
        let w = try #require(d.window(now: at(15), calendar: cal))
        #expect(w.start == at(19))
        #expect(w.end == at(21))
        #expect(BatchCopy.window(w.start, w.end, now: at(15), calendar: cal) == "Tonight · pickup 7 to 9")
    }

    @Test func tomorrowAndHalfHours() throws {
        var d = BatchDraft()
        d.day = .tomorrow
        d.from = 11.5
        d.to = 13
        let w = try #require(d.window(now: at(22), calendar: cal))
        #expect(w.start == at(11, 30, day: 13))
        #expect(BatchCopy.window(w.start, w.end, now: at(22), calendar: cal) == "Tomorrow · pickup 11:30 to 1")
    }

    @Test func lateInTheEveningItStartsTomorrow() {
        #expect(BatchDraft.starting(now: at(15), calendar: cal).day == .today)
        #expect(BatchDraft.starting(now: at(21), calendar: cal).day == .tomorrow)
    }

    @Test func backwardsHoursHaveNoWindow() {
        var d = BatchDraft()
        d.from = 21
        d.to = 20
        #expect(d.window(now: at(12), calendar: cal) == nil)
    }

    // MARK: What's missing

    @Test func saysWhatsMissingFirstThingFirst() {
        var d = BatchDraft()
        let now = at(15)
        #expect(d.problem(now: now, needsAddress: true, needsPermit: true, calendar: cal) == "Say what it is.")
        d.title = "Mango sticky rice ice cream"
        #expect(d.problem(now: now, needsAddress: true, needsPermit: true, calendar: cal) == "Set a price.")
        d.priceText = "6"
        #expect(d.problem(now: now, needsAddress: true, needsPermit: true, calendar: cal)?.hasPrefix("Add your address") == true)
        d.address = "3100 24th St"
        #expect(d.problem(now: now, needsAddress: true, needsPermit: true, calendar: cal) == "Confirm your home kitchen permit.")
        d.permitConfirmed = true
        #expect(d.problem(now: now, needsAddress: true, needsPermit: true, calendar: cal) == nil)
    }

    @Test func aKitchenWithAPermitAndAddressIsNotAskedAgain() {
        var d = BatchDraft()
        d.title = "Ube pints"
        d.priceText = "7"
        #expect(d.problem(now: at(15), needsAddress: false, needsPermit: false, calendar: cal) == nil)
    }

    @Test func aWindowThatsOverIsCaught() {
        var d = BatchDraft()
        d.title = "Bread"
        d.priceText = "8"
        #expect(d.problem(now: at(21, 30), needsAddress: false, needsPermit: false, calendar: cal) == "That window's over. Pick tomorrow.")
    }

    // MARK: Words

    @Test func countsAndPlurals() {
        #expect(BatchCopy.count(1, "pint") == "1 pint")
        #expect(BatchCopy.count(8, "pint") == "8 pints")
        #expect(BatchCopy.count(2, "box of 6") == "2 boxes of 6")
        #expect(BatchCopy.count(3, "patty") == "3 patties")
        #expect(BatchCopy.count(3, "") == "3")
    }

    @Test func priceLine() {
        #expect(BatchCopy.price(600, unit: "pint") == "$6 a pint")
        #expect(BatchCopy.price(450, unit: "order") == "$4.50 an order")
        #expect(BatchCopy.price(600, unit: "") == "$6 each")
    }

    @Test func leftLine() {
        #expect(BatchCopy.left(8, of: 12, unit: "pint") == "8 of 12 pints left")
        #expect(BatchCopy.left(3, of: 10, unit: "") == "3 of 10 left")
        #expect(BatchCopy.left(0, of: 10, unit: "pint") == "Sold out")
    }

    @Test func reserveButtonSaysHowYouPay() {
        #expect(BatchCopy.reserve(quantity: 1, unit: "pint", totalCents: 650, pay: .inApp) == "Reserve a pint · $6.50")
        #expect(BatchCopy.reserve(quantity: 2, unit: "pint", totalCents: 1260, pay: .inApp) == "Reserve 2 pints · $12.60")
        #expect(BatchCopy.reserve(quantity: 1, unit: "pint", totalCents: 600, pay: .atPickup) == "Reserve a pint · pay at pickup")
        #expect(BatchCopy.reserve(quantity: 3, unit: "", totalCents: 900, pay: .atPickup) == "Reserve 3 · pay at pickup")
    }

    @Test func receiptSaysPlainlyWhatsOwed() {
        #expect(BatchCopy.receipt(.atPickup, totalCents: 1200, cook: "Dana") == "Pay Dana $12 at pickup.")
        #expect(BatchCopy.receipt(.paid, totalCents: 1260, cook: "Dana") == "Paid $12.60 in the app.")
        #expect(BatchCopy.payLine(pay: .atPickup, cook: "Dana", totalCents: 600).hasPrefix("Pay Dana $6 at pickup."))
    }

    @Test func theCodeIsEasyToSay() {
        #expect(BatchCopy.spoken("482") == "4 8 2")
        #expect(BatchCopy.spoken("") == "")
    }

    @Test func kitchenLine() {
        #expect(BatchCopy.kitchenLine(walkMinutes: 4, rating: 4.9, reviews: 23, regulars: 12) == "4-minute walk · ★ 4.9 (23) · 12 regulars")
        #expect(BatchCopy.kitchenLine(walkMinutes: 6, rating: nil, reviews: 0, regulars: 0) == "6-minute walk · New")
    }

    @Test func clockSteps() {
        #expect(BatchCopy.clock(19) == "7 PM")
        #expect(BatchCopy.clock(19.5) == "7:30 PM")
        #expect(BatchCopy.clock(11) == "11 AM")
        #expect(BatchCopy.clock(12) == "12 PM")
    }

    // MARK: Payment states

    @Test func expiredAndRefundedAreNotPickups() {
        #expect(PaymentState.atPickup.isLive && PaymentState.unpaid.isLive && PaymentState.paid.isLive)
        #expect(!PaymentState.refunded.isLive && !PaymentState.expired.isLive)
        #expect(PaymentState(rawValue: "at_pickup") == .atPickup)
        #expect(PayMode(rawValue: "in_app") == .inApp)
    }

    // MARK: Slots

    @Test func openSlotsSkipFullAndPast() {
        let start = at(19), end = at(20)
        let all = BatchSlots.all(start: start, end: end)
        #expect(all == [at(19), at(19, 15), at(19, 30), at(19, 45)])
        let open = BatchSlots.open(start: start, end: end, full: [at(19, 30)], now: at(19, 20))
        // 7:00 ended at 7:15; 7:15 is still on until 7:30; 7:30 is full.
        #expect(open == [at(19, 15), at(19, 45)])
    }

    // MARK: Photo

    @Test func photosShrinkToAbout1200() {
        #expect(PhotoPrep.fit(CGSize(width: 4032, height: 3024)) == CGSize(width: 1200, height: 900))
        #expect(PhotoPrep.fit(CGSize(width: 3024, height: 4032)) == CGSize(width: 900, height: 1200))
        #expect(PhotoPrep.fit(CGSize(width: 800, height: 600)) == CGSize(width: 800, height: 600))
    }
}
