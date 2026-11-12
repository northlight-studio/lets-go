import Testing
import Foundation
@testable import LetsGo

@Suite("Your block")
struct BlockTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    /// Thursday 12 November 2026, 4 PM.
    var now: Date { date(12, 16) }

    func item(_ key: String, _ kind: String = "batch", ends: Date? = nil, _ change: (inout BlockItemDTO) -> Void = { _ in }) -> BlockItemDTO {
        var i = BlockItemDTO(key: key, kind: kind, id: UUID())
        i.endsAt = ends
        change(&i)
        return i
    }

    // MARK: Words

    @Test func theTitleIsYourStreet() {
        #expect(Block.area(street: "24th Street", neighborhood: "Mission") == "24th Street and around")
        #expect(Block.area(street: " ", neighborhood: "Mission") == "Mission and around")
        #expect(Block.area(street: nil, neighborhood: nil) == "Around you")
    }

    @Test func aNeighborsBatch() {
        let i = item("batch:1") {
            $0.title = "Mango ice cream"
            $0.name = "Dana Whitfield's kitchen"
            $0.left = 8
            $0.unit = "pint"
            $0.startsAt = date(12, 19)
            $0.endsAt = date(12, 21)
            $0.walkMin = 4
            $0.photoUrl = "/v1/photos/x"
        }
        let row = Block.row(i, now: now, calendar: cal)
        #expect(row.line == "Dana made mango ice cream")
        #expect(row.detail.hasPrefix("8 pints left \u{00B7} pickup tonight "))
        #expect(row.detail.hasSuffix(" \u{00B7} 4 min"))
        #expect(row.thumb == .photo("/v1/photos/x", title: "Mango ice cream"))
    }

    @Test func aKitchenWithItsOwnNameIsntACook() {
        #expect(Block.cook("Wei's kitchen") == "Wei")
        #expect(Block.cook("Dana Whitfield\u{2019}s kitchen") == "Dana")
        #expect(Block.cook("Golden Dumpling") == nil)
        let i = item("batch:2") { $0.title = "Pork buns"; $0.name = "Golden Dumpling" }
        #expect(Block.row(i, now: now, calendar: cal).line == "Pork buns from Golden Dumpling")
    }

    @Test func aKitchenYouFollowIsBack() {
        let i = item("batch:3", "back") {
            $0.title = "Dumplings"
            $0.name = "Wei's kitchen"
            $0.startsAt = date(13, 18)
            $0.endsAt = date(13, 20)
        }
        let row = Block.row(i, now: now, calendar: cal)
        #expect(row.line == "Wei\u{2019}s dumplings, back tomorrow")
        #expect(row.detail.hasPrefix("You follow Wei's kitchen \u{00B7} pickup "))
        #expect(row.detail.hasSuffix("reserve now"))
        #expect(Block.day(date(15, 18), now: now, calendar: cal) == "Sunday")
        #expect(Block.day(date(12, 11), now: now, calendar: cal) == "today")
    }

    @Test func strangersAreCountsAndFriendsAreNamed() {
        #expect(Block.goingLine(friends: [], count: 3, title: "Jazz in the park") == "3 neighbors are going to Jazz in the park")
        #expect(Block.goingLine(friends: [], count: 1, title: "Jazz") == "1 neighbor is going to Jazz")
        #expect(Block.goingLine(friends: ["Maya"], count: 4, title: "Jazz") == "Maya is going to Jazz")
        #expect(Block.goingLine(friends: ["Maya", "Sam"], count: 0, title: "Jazz") == "Maya and Sam are going to Jazz")
        #expect(Block.goingLine(friends: ["Maya", "Sam", "Theo"], count: 0, title: "Jazz") == "Maya and 2 friends are going to Jazz")
    }

    @Test func peopleByFirstName() {
        let hi = item("neighbor:1", "neighbor") { $0.name = "Jun Park"; $0.together = 3 }
        let hiRow = Block.row(hi, now: now, calendar: cal)
        #expect(hiRow.line == "Say hi to Jun")
        #expect(hiRow.detail == "You\u{2019}ve been to 3 things together")
        #expect(hiRow.thumb == .initials("JP"))
        let up = item("up_for:1", "up_for") { $0.name = "Maya Reyes"; $0.title = "A walk"; $0.walkMin = 5 }
        let upRow = Block.row(up, now: now, calendar: cal)
        #expect(upRow.line == "Maya is up for a walk")
        #expect(upRow.detail == "5 min away")
    }

    @Test func unitsAndWhatsLeft() {
        #expect(Block.leftLine(8, unit: "pint") == "8 pints left")
        #expect(Block.leftLine(1, unit: "pint") == "1 pint left")
        #expect(Block.leftLine(2, unit: "box of 6") == "2 boxes of 6 left")
        #expect(Block.leftLine(3, unit: "") == "3 left")
        #expect(Block.leftLine(0, unit: "pint") == "sold out")
        #expect(Block.lowerFirst("Mango") == "mango")
        #expect(Block.lowerFirst("IPA flight") == "IPA flight")
        #expect(Block.lowerFirst("A walk") == "a walk")
        #expect(Block.lowerFirst("Coffee") == "coffee")
    }

    // MARK: Today's, then it ends

    @Test func seenOnAnEarlierDayDoesntComeBack() {
        let a = item("a"), b = item("b"), c = item("c")
        var memory = Block.Memory()
        memory = Block.seeing([a], in: memory, now: date(11, 18))
        memory = Block.seeing([b], in: memory, now: date(12, 9))
        #expect(Block.today([a, b, c], memory: memory, now: now, calendar: cal).map(\.key) == ["b", "c"])
        #expect(Block.unseen([a, b, c], memory: memory).map(\.key) == ["c"])
        // Seeing again keeps the first time.
        let again = Block.seeing([b], in: memory, now: date(12, 15))
        #expect(again.seen["b"] == date(12, 9))
    }

    @Test func memoryForgetsAfterTwoWeeks() {
        let m = Block.seeing([item("old")], in: Block.Memory(), now: date(1, 9))
        let later = Block.seeing([item("new")], in: m, now: date(20, 9))
        #expect(later.seen["old"] == nil && later.seen["new"] != nil)
    }

    // MARK: The evening digest

    @Test func digestIsEarlyEveningAndAtMostOnceADay() {
        #expect(Block.nextDigest(after: date(12, 16), calendar: cal) == date(12, 17, 30))
        #expect(Block.nextDigest(after: date(12, 17, 30), calendar: cal) == date(13, 17, 30))
        #expect(Block.nextDigest(after: date(12, 22), calendar: cal) == date(13, 17, 30))
    }

    @Test func digestOnlyWhenSomethingsNew() {
        let fire = date(12, 17, 30)
        let fresh = item("fresh", ends: date(12, 21)) { $0.title = "Mango ice cream"; $0.name = "Dana's kitchen" }
        let gone = item("gone", ends: date(12, 17))
        let seen = item("seen")
        let told = item("told")
        var memory = Block.seeing([seen], in: Block.Memory(), now: date(12, 10))
        memory.told["told"] = date(11, 17, 30)
        let picks = Block.digestItems([fresh, gone, seen, told], memory: memory, fire: fire)
        #expect(picks.map(\.key) == ["fresh"])
        #expect(Block.digestBody(picks, fire: fire, calendar: cal) == "Dana made mango ice cream.")
        #expect(Block.digestBody([fresh, item("x")], fire: fire, calendar: cal) == "Dana made mango ice cream, and 1 more on your block.")
        #expect(Block.digestBody([], fire: fire, calendar: cal) == nil)
        // Told for tonight's digest still counts tonight (it's the same digest, rewritten).
        memory.told["fresh"] = fire
        #expect(Block.digestItems([fresh], memory: memory, fire: fire).map(\.key) == ["fresh"])
    }
}
