import Testing
import Foundation
@testable import LetsGo

@Suite("What the map's pins say")
struct PinsTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func thing(_ title: String, kind: Candidate.Kind = .gathering, startsIn hours: Double = 1, price: Int? = nil) -> Candidate {
        let start = now.addingTimeInterval(hours * 3600)
        return Candidate(
            id: UUID(), kind: kind, title: title, category: kind == .drop ? .food : .music,
            start: start, end: start.addingTimeInterval(7200), meters: 400,
            priceFromCents: price, lat: 37.7599, lon: -122.4214
        )
    }

    func friend(_ name: String, porch: Bool = false, note: String = "", at: (Double, Double)? = nil, out: Friend.Out? = nil) -> Friend {
        Friend(
            id: UUID(), name: name,
            porchUntil: porch ? now.addingTimeInterval(3600) : now.addingTimeInterval(-60),
            porchNote: note, latitude: at?.0, longitude: at?.1, out: out
        )
    }

    // MARK: Events

    @Test func shortNamesStayWholeAndLongOnesAreCutAtAWord() {
        #expect(Pins.shortName("Jazz in the park") == "Jazz in the park")
        #expect(Pins.shortName("  Jazz   in the  park ") == "Jazz in the park")
        #expect(Pins.shortName("Thursday night jazz at the Royal Cuckoo") == "Thursday night…")
        // Never ends on a joiner.
        #expect(Pins.shortName("Board games and pizza at Hayes") == "Board games…")
        // One very long word is cut inside it.
        #expect(Pins.shortName("Supercalifragilisticexpialidocious") == "Supercalifragilis…")
        #expect(Pins.shortName("Jazz in the park").count <= Pins.nameLimit)
    }

    @Test func aPillSaysNowForWhatsOn() {
        let on = thing("Happy hour", startsIn: -0.5)
        #expect(Pins.time(on, now: now) == "Now")
        #expect(Pins.time(thing("Set"), now: now) != "Now")
    }

    // MARK: Food

    @Test func theKitchensTagIsItsCheapestDish() {
        #expect(Pins.priceTag(cents: 600) == "$6")
        #expect(Pins.priceTag(cents: 650) == "$6.50")
        #expect(Pins.priceTag(cents: nil) == nil)
        #expect(Pins.priceTag(cents: 0) == nil)
    }

    @Test func aDishForEveryKitchenUntilThereIsAPhoto() {
        #expect(KitchenLook.glyph(for: "Neapolitan pizza") == "🍕")
        #expect(KitchenLook.glyph(for: "Sunday tamales") == "🫔")
        #expect(KitchenLook.glyph(for: "Something new") == "🍽️")
    }

    // MARK: Friends

    @Test func initialsFromNames() {
        #expect(Pins.initials("Maya Chen") == "MC")
        #expect(Pins.initials("theo") == "T")
        #expect(Pins.initials("Ana María de la Cruz") == "AM")
        #expect(Pins.initials("") == "?")
    }

    @Test func onlyFriendsWhoAreSomewhereRealGoOnTheMap() {
        let lit = friend("Maya", porch: true, note: "walk?", at: (37.76, -122.42))
        let litNowhere = friend("Ben", porch: true)
        let off = friend("Theo", porch: false, at: (37.76, -122.42))
        let there = friend("Ana", out: Friend.Out(state: .there, title: "Trivia", place: "Zeitgeist", latitude: 37.77, longitude: -122.42))
        let heading = friend("Sam", out: Friend.Out(state: .heading, title: "Trivia", place: "Zeitgeist", latitude: 37.77, longitude: -122.42))
        let pins = Pins.friends([lit, litNowhere, off, there, heading], now: now)
        #expect(pins.map(\.name) == ["Ana", "Maya"])
        #expect(pins.first { $0.name == "Ana" }?.latitude == 37.77)
    }

    @Test func theBubbleIsTheirPorchNoteWhileTheLightIsOn() {
        #expect(Pins.bubble(friend("Maya", porch: true, note: "walk?"), now: now) == "walk?")
        #expect(Pins.bubble(friend("Maya", porch: true), now: now) == "up for it?")
        #expect(Pins.bubble(friend("Maya", porch: false, note: "walk?"), now: now) == nil)
        let long = Pins.bubble(friend("Maya", porch: true, note: "anyone want to get dumplings later"), now: now)
        #expect(long == "anyone want…")
    }

    // MARK: Room and merging

    @Test func pillsGrowWithTheirNames() {
        let short = Pins.footprint(thing("Jam"), now: now)
        let long = Pins.footprint(thing("Jazz in the park"), now: now)
        #expect(long.width > short.width)
        #expect(Pins.footprint(thing("Tamales", kind: .drop), now: now).height > short.height)
    }

    @Test func pinsSideBySideOverlapOnlyWhenTheirRoomsTouch() {
        let room = (width: 100.0, height: 30.0)
        #expect(Pins.overlap((0, 0), room, (90, 0), room))
        #expect(!Pins.overlap((0, 0), room, (110, 0), room))
        #expect(!Pins.overlap((0, 0), room, (0, 40), room))
    }

    // MARK: Chips

    @Test func chipsKeepTheirKindOfThing() {
        let jam = thing("Jam"), tamales = thing("Tamales", kind: .drop)
        #expect(MapLayer.all.keeps(jam) && MapLayer.all.keeps(tamales))
        #expect(MapLayer.food.keeps(tamales) && !MapLayer.food.keeps(jam))
        #expect(MapLayer.events.keeps(jam) && !MapLayer.events.keeps(tamales))
        #expect(MapLayer.friends.keeps(jam, goingIDs: [jam.id]) && !MapLayer.friends.keeps(tamales, goingIDs: [jam.id]))
        #expect(MapLayer.all.showsFriends && MapLayer.friends.showsFriends)
        #expect(!MapLayer.food.showsFriends && !MapLayer.events.showsFriends)
        #expect(MapLayer.allCases.map(\.label) == ["All", "Food", "Events", "Friends"])
    }
}
