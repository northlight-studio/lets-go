import Testing
import Foundation
import CoreLocation
@testable import LetsGo

@Suite("Your people tonight")
struct CrowdTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let here = CLLocationCoordinate2D(latitude: 37.7596, longitude: -122.4269)

    func gathering(_ title: String, startsIn minutes: Double, east: Double, north: Double,
                   capacity: Int = 0, going: Int = 0, friends: [UUID] = []) -> Candidate {
        let at = here.offset(east: east, north: north)
        return Candidate(
            id: UUID(), kind: .gathering, title: title, category: .party,
            start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + 120) * 60),
            meters: here.distance(to: at), capacity: capacity, going: going, place: "The Dubliner",
            lat: at.latitude, lon: at.longitude, friendIDs: friends
        )
    }

    func friend(_ name: String) -> Friend {
        Friend(id: UUID(), name: name)
    }

    @Test func friendsAreWhereTheServerSaid() {
        let sam = friend("Sam")
        let trivia = gathering("Trivia", startsIn: 60, east: 0, north: 400, capacity: 6)
        // Nobody is placed on anything: not on its list, not out heading there.
        #expect(Crowd.going(to: trivia, among: [sam]).isEmpty)
        // Going according to the server's list.
        let listed = gathering("Trivia", startsIn: 60, east: 0, north: 400, friends: [sam.id])
        #expect(Crowd.going(to: listed, among: [sam]).map(\.name) == ["Sam"])
        // Or out, heading to it.
        var maya = friend("Maya")
        maya.out = Friend.Out(state: .heading, title: "Trivia", place: "", start: trivia.start, gatheringID: trivia.id)
        #expect(Crowd.going(to: trivia, among: [sam, maya]).map(\.name) == ["Maya"])
    }

    @Test func namesReadLikeASentence() {
        let f = ["Maya", "Theo", "Jun", "Ben"].map { Friend(id: UUID(), name: $0) }
        #expect(Crowd.names(Array(f.prefix(1))) == "Maya")
        #expect(Crowd.names(Array(f.prefix(2))) == "Maya and Theo")
        #expect(Crowd.names(Array(f.prefix(3))) == "Maya, Theo and Jun")
        #expect(Crowd.names(f) == "Maya, Theo and 2 others")
    }

    @Test func porchLightsAreOnlyTheOnesStillOn() {
        var priya = friend("Priya")
        priya.porchUntil = now.addingTimeInterval(3600)
        var omar = friend("Omar")
        omar.porchUntil = now.addingTimeInterval(-60)
        #expect(Crowd.porchLights([priya, omar], now: now).map(\.name) == ["Priya"])
    }

    @Test func wrenRoutesYouPastAFriendOnTheWay() throws {
        let trivia = gathering("Trivia", startsIn: 40, east: 0, north: 1200)
        var maya = friend("Maya")
        let halfway = here.offset(east: 80, north: 600)
        maya.latitude = halfway.latitude
        maya.longitude = halfway.longitude
        maya.out = Friend.Out(state: .heading, title: "Trivia", place: "The Dubliner", start: trivia.start, gatheringID: trivia.id)
        let meet = try #require(MeetUp.best(here: here, friends: [maya], to: trivia, now: now))
        #expect(meet.friendName == "Maya")
        #expect(meet.leave > now)
        #expect(meet.leave < meet.meetAt)
        #expect(meet.meetAt < trivia.start)
        #expect(meet.extraMinutes <= 2)
    }

    @Test func noDetourThatDoublesTheWalk() {
        let trivia = gathering("Trivia", startsIn: 60, east: 0, north: 800)
        var maya = friend("Maya")
        let away = here.offset(east: 0, north: -900)
        maya.latitude = away.latitude
        maya.longitude = away.longitude
        maya.out = Friend.Out(state: .heading, title: "Trivia", place: "", start: trivia.start, gatheringID: trivia.id)
        #expect(MeetUp.best(here: here, friends: [maya], to: trivia, now: now) == nil)
    }

    @Test func wrenLeadsWithFriends() {
        let trivia = gathering("Trivia", startsIn: 60, east: 0, north: 1200, capacity: 6, going: 4)
        let friends = [friend("Maya"), friend("Theo")]
        let meet = MeetUp(friendID: friends[0].id, friendName: "Maya", leave: now.addingTimeInterval(1800),
                          meetAt: now.addingTimeInterval(2400), latitude: 0, longitude: 0, extraMinutes: 1)
        let line = HomeLine.sentence(for: trivia, now: now, friends: friends, meet: meet, clock: { _ in "T" })
        #expect(line.lead.hasPrefix("Maya and Theo are going to trivia at The Dubliner"))
        #expect(line.emphasis == "they need two.")
        #expect(line.tail == " Leave at T and you'll walk in with Maya.")
    }
}
