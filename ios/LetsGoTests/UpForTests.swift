import Testing
import Foundation
import CoreLocation
@testable import LetsGo

@Suite("Up for something")
struct UpForTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let here = CLLocationCoordinate2D(latitude: 37.7596, longitude: -122.4269)

    func up(_ name: String, _ activity: String, minutes: Int?, for hours: Double = 1) -> Friend {
        var f = Friend(id: UUID(), name: name)
        f.porchUntil = now.addingTimeInterval(hours * 3600)
        f.porchNote = UpFor.label(activity: activity, words: "")
        f.upActivity = activity
        f.upWalkMinutes = minutes
        return f
    }

    // MARK: What you can say

    @Test func activitiesMatchTheServer() {
        #expect(UpFor.activities.map(\.key) == ["walk", "coffee", "drink", "pickup", "cooking"])
        #expect(UpFor.activities.map(\.label) == ["A walk", "Coffee", "A drink", "Pickup game", "Cooking"])
    }

    @Test func ownWordsReadAsThemselves() {
        #expect(UpFor.label(activity: "", words: "  Frisbee in the park ") == "Frisbee in the park")
        #expect(UpFor.label(activity: "walk", words: "ignored") == "A walk")
        #expect(UpFor.bubble(activity: "walk", words: "") == "walk?")
        #expect(UpFor.bubble(activity: "pickup", words: "") == "game?")
        #expect(UpFor.bubble(activity: "", words: "Frisbee, anyone") == "frisbee?")
        #expect(UpFor.bubble(activity: "", words: "") == "hi?")
    }

    @Test func theLineSaysWhoSeesItAndForHowLong() {
        #expect(UpFor.whoSees(hours: 2) == "Friends and people you've met see it for the next 2 hours.")
        #expect(UpFor.whoSees(hours: 1) == "Friends and people you've met see it for the next hour.")
        #expect(UpFor.hoursText(1) == "an hour")
        #expect(UpFor.hoursText(3) == "3 hours")
        #expect(UpFor.defaultHours == 2)
    }

    @Test func howMuchLonger() {
        #expect(UpFor.left(until: now.addingTimeInterval(60 * 60), now: now) == "for an hour")
        #expect(UpFor.left(until: now.addingTimeInterval(20 * 60), now: now) == "for 20 more min")
        #expect(UpFor.left(until: now.addingTimeInterval(150 * 60), now: now) == "for 3 hours")
        #expect(UpFor.left(until: now.addingTimeInterval(-60), now: now) == "")
    }

    @Test func theDayOverTheTitle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 18))!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9))!
        #expect(UpFor.dayLine(evening, calendar: calendar).hasSuffix(" evening"))
        #expect(UpFor.dayLine(morning, calendar: calendar).hasSuffix(" morning"))
    }

    // MARK: Up for something near you

    @Test func closestFirstWithWhatAndHowFarAndHowLong() {
        let maya = up("Maya Reyes", "walk", minutes: 6)
        let theo = up("Theo", "coffee", minutes: 2)
        let rows = UpFor.rows(friends: [maya, theo], met: [], now: now)
        #expect(rows.map(\.name) == ["Theo", "Maya"])
        #expect(rows.allSatisfy { $0.kind == .friend })
        #expect(rows[1].detail == "A walk \u{00B7} 6 min away \u{00B7} for an hour")
        #expect(rows[1].emoji == "\u{1F6B6}")
    }

    @Test func onlyWhileItsOn() {
        var gone = up("Omar", "drink", minutes: 3)
        gone.porchUntil = now.addingTimeInterval(-60)
        #expect(UpFor.rows(friends: [gone], met: [], now: now).isEmpty)
    }

    @Test func peopleYouveMetComeAfterFriends() {
        let maya = up("Maya", "walk", minutes: 9)
        let jun = up("Jun", "coffee", minutes: 1)
        let rows = UpFor.rows(friends: [maya], met: [jun], metTimes: [jun.id: 3], now: now)
        #expect(rows.map(\.kind) == [.friend, .met])
        #expect(rows[1].detail == "Coffee \u{00B7} met three times \u{00B7} for an hour")
    }

    @Test func friendsGoingToTheSameThingAreOneRowToJoin() {
        let game = UUID()
        func going(_ name: String) -> Friend {
            var f = Friend(id: UUID(), name: name)
            f.out = Friend.Out(state: .heading, title: "Pickup", place: "the Mission courts",
                               start: now.addingTimeInterval(1800), gatheringID: game)
            return f
        }
        let rows = UpFor.rows(friends: [going("Theo"), going("Ben"), going("Sam")], met: [], now: now)
        #expect(rows.count == 1)
        #expect(rows[0].kind == .gathering && rows[0].gatheringID == game)
        #expect(rows[0].name == "Theo + 2")
        #expect(rows[0].detail == "Pickup at the Mission courts")
    }

    @Test func upForSomethingWinsOverGoingSomewhere() {
        var maya = up("Maya", "walk", minutes: 4)
        maya.out = Friend.Out(state: .heading, title: "Trivia", place: "", start: now.addingTimeInterval(600), gatheringID: UUID())
        let rows = UpFor.rows(friends: [maya], met: [], now: now)
        #expect(rows.map(\.kind) == [.friend])
    }

    // MARK: A match

    @Test func whereAndWhen() {
        #expect(MatchCopy.lead(spot: "", meetAt: now, now: now) == "Finding somewhere about halfway\u{2026}")
        #expect(MatchCopy.lead(spot: "Dolores Park", meetAt: now.addingTimeInterval(15 * 60), now: now)
                == "Meet at Dolores Park in 15 minutes.")
        #expect(MatchCopy.lead(spot: "Dolores Park", meetAt: now.addingTimeInterval(-30), now: now) == "Meet at Dolores Park now.")
    }

    @Test func howFarOffTheyAreIsATimeNeverAPlace() {
        #expect(MatchCopy.them("Maya", walk: 6, onTheirWay: false, says: "") == "Maya's 6 minutes away.")
        #expect(MatchCopy.them("Maya", walk: 1, onTheirWay: true, says: "") == "Maya's on the way, 1 minute out.")
        #expect(MatchCopy.them("Maya", walk: nil, onTheirWay: false, says: "") == "")
        #expect(MatchCopy.them("Maya", walk: 3, onTheirWay: true, says: "I'm here") == "Maya says: I'm here.")
    }

    @Test func aParkAboutHalfwayBeatsACafeJustCloser() {
        let park = MeetSpot.Place(name: "Dolores Park", latitude: here.offset(east: 0, north: 200).latitude,
                                  longitude: here.longitude, isPark: true)
        let cafe = MeetSpot.Place(name: "Ritual Coffee", latitude: here.offset(east: 0, north: 120).latitude,
                                  longitude: here.longitude, isPark: false)
        let nearCafe = MeetSpot.Place(name: "Right here", latitude: here.latitude, longitude: here.longitude, isPark: false)
        #expect(MeetSpot.pick([park, cafe], near: here)?.name == "Dolores Park")
        #expect(MeetSpot.pick([park, nearCafe], near: here)?.name == "Right here")
    }

    @Test func nothingTooFarFromHalfway() {
        let far = here.offset(east: 2000, north: 0)
        let park = MeetSpot.Place(name: "Far Park", latitude: far.latitude, longitude: far.longitude, isPark: true)
        #expect(MeetSpot.pick([park], near: here) == nil)
        #expect(MeetSpot.pick([], near: here) == nil)
    }
}
