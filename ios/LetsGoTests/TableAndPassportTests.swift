import Testing
import Foundation
@testable import LetsGo

@Suite("The shared table")
struct SharedTableTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func friendsFirstThenOthersThenYourSeat() {
        let maya = Friend(id: UUID(), name: "Maya")
        let table = SharedTable.Table(seats: 8, taken: 5, friends: [(friend: maya, at: now)])
        let seats = SharedTable.seats(table)
        #expect(seats.count == 8)
        #expect(seats[0].kind == .friend(maya, now))
        let taken = seats.filter { if case .taken = $0.kind { return true } else { return false } }.count
        #expect(taken == 4)
        #expect(seats[5].kind == .yours)
        #expect(table.open == 3)
    }

    @Test func aFullTableHasNoSeatForYou() {
        let table = SharedTable.Table(seats: 4, taken: 4, friends: [])
        let yours = SharedTable.seats(table).contains { $0.kind == .yours }
        #expect(!yours)
    }

    @Test func realTablesComeFromTheServer() throws {
        let maya = Friend(id: UUID(), name: "Maya")
        let t = try #require(SharedTable.table(
            seats: 2, serverTaken: 3, serverFriends: [TableSeat(personID: maya.id, name: "Maya", at: now)], people: [maya],
            drop: (start: now, end: now.addingTimeInterval(7200))
        ))
        #expect(t.seats == 8)
        #expect(t.taken == 3)
        let names = t.friends.map { $0.friend.name }
        #expect(names == ["Maya"])
    }

    @Test func noPorchNoTable() {
        let t = SharedTable.table(seats: 0, serverTaken: 0, serverFriends: [], people: [],
                                  drop: (start: now, end: now.addingTimeInterval(7200)))
        #expect(t == nil)
    }
}

@Suite("Passport with people")
struct PassportPeopleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func mostNightsCountsEachNightOnce() {
        let maya = UUID(), theo = UUID()
        let one = [
            NightStop(title: "Tamales", genreRaw: "food", arrivedAt: now, withIDs: [maya], withNames: ["Maya"]),
            NightStop(title: "Show", genreRaw: "music", arrivedAt: now, withIDs: [maya, theo], withNames: ["Maya", "Theo"]),
        ]
        let two = [NightStop(title: "Trivia", genreRaw: "party", arrivedAt: now, withIDs: [maya], withNames: ["Maya"])]
        let ranked = PassportPeople.mostNightsWith([one, two], people: [])
        #expect(ranked.map(\.friend.name) == ["Maya", "Theo"])
        #expect(ranked.map(\.nights) == [2, 1])
    }

    @Test func titlesNameTheNight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let halloween = cal.date(from: DateComponents(year: 2026, month: 10, day: 31))!
        let stops = [
            NightStop(title: "Tamales", genreRaw: "food", arrivedAt: halloween),
            NightStop(title: "Make-Out Room", genreRaw: "music", arrivedAt: halloween),
        ]
        let with = [Friend(id: UUID(), name: "Maya"), Friend(id: UUID(), name: "Theo")]
        #expect(PassportPeople.title(stops, evening: halloween, with: with, calendar: cal) == "Halloween with Maya & Theo")
        let single = [NightStop(title: "Trivia at The Dubliner", genreRaw: "party", arrivedAt: now)]
        let tuesday = cal.date(from: DateComponents(year: 2026, month: 10, day: 27))!
        #expect(PassportPeople.title(single, evening: tuesday, with: [], calendar: cal) == "Trivia at The Dubliner")
    }
}
