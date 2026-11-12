import Testing
import Foundation
@testable import LetsGo

@Suite("Wren's line on the map")
struct HomeLineTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func gathering(_ title: String, startsIn minutes: Double, meters: Double = 800,
                   capacity: Int = 0, going: Int = 0, place: String = "The Dubliner") -> Candidate {
        Candidate(
            id: UUID(), kind: .gathering, title: title, category: .party,
            start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + 120) * 60),
            meters: meters, capacity: capacity, going: going, place: place
        )
    }

    func drop(left: Int, total: Int, startsIn minutes: Double = 30) -> Candidate {
        Candidate(
            id: UUID(), kind: .drop, title: "Kenji's Curry Night", category: .food,
            start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + 120) * 60),
            meters: 400, dropLeft: left, dropTotal: total
        )
    }

    let clock: (Date) -> String = { _ in "T" }

    @Test func pinsPulseFasterAsTheyFill() throws {
        let empty = try #require(HomeLine.pulsePeriod(gathering("Trivia", startsIn: 30, capacity: 6, going: 0)))
        let most = try #require(HomeLine.pulsePeriod(gathering("Trivia", startsIn: 30, capacity: 6, going: 5)))
        #expect(most < empty)
        #expect(empty == 3.4)
        // Full: no pulse at all.
        #expect(HomeLine.pulsePeriod(gathering("Trivia", startsIn: 30, capacity: 6, going: 6)) == nil)
        // A drop fills by what's sold.
        let selling = try #require(HomeLine.pulsePeriod(drop(left: 4, total: 20)))
        #expect(selling < empty)
    }

    @Test func twoRingsOnceItsThreeQuartersFull() {
        #expect(HomeLine.isFillingFast(gathering("Trivia", startsIn: 30, capacity: 6, going: 5)))
        #expect(!HomeLine.isFillingFast(gathering("Trivia", startsIn: 30, capacity: 6, going: 2)))
        #expect(!HomeLine.isFillingFast(gathering("Trivia", startsIn: 30, capacity: 6, going: 6)))
    }

    @Test func badgesShowHowFull() {
        #expect(HomeLine.badge(gathering("Trivia", startsIn: 30, capacity: 6, going: 4)) == "4/6")
        #expect(HomeLine.badge(drop(left: 16, total: 20)) == "16 left")
        #expect(HomeLine.badge(gathering("Backyard set", startsIn: 30, going: 14)) == "14")
        #expect(HomeLine.badge(gathering("Open mic", startsIn: 30)) == nil)
    }

    @Test func picksMetaLineSaysHowFullTheWalkAndWhenToLeave() {
        let soccer = gathering("Pickup soccer", startsIn: 30, meters: 480, capacity: 6, going: 4)
        #expect(HomeLine.meta(for: soccer, now: now, clock: clock) == "4 of 6 in · 6-minute walk · leave by T")
        let on = gathering("Trivia", startsIn: -10, meters: 480, going: 9)
        #expect(HomeLine.meta(for: on, now: now, clock: clock) == "9 going · 6-minute walk · on now")
        let curry = drop(left: 4, total: 20)
        #expect(HomeLine.meta(for: curry, now: now, clock: clock) == "4 of 20 left · 5-minute walk · leave by T")
        // Nothing to count: it starts with the walk.
        let open = gathering("Open mic", startsIn: 30, meters: 480)
        #expect(HomeLine.meta(for: open, now: now, walkMinutes: 9, clock: clock) == "9-minute walk · leave by T")
    }

    @Test func othersCountsEveryoneNotShownAsAFace() {
        let soccer = gathering("Pickup soccer", startsIn: 30, capacity: 6, going: 4)
        #expect(HomeLine.others(soccer, friendsShown: 2) == "+2")
        #expect(HomeLine.others(soccer, friendsShown: 4) == nil)
    }

    @Test func searchPromptFollowsTheWindow() {
        #expect(HomeLine.searchPrompt(.tonight, inCity: false) == "Tonight, nearby")
        #expect(HomeLine.searchPrompt(.weekend, inCity: true) == "This weekend, in the city")
    }

    @Test func outsideTheCityItSaysSo() {
        #expect(HomeLine.empty(inCity: false).text.hasPrefix("Let's Go only knows San Francisco so far."))
        #expect(HomeLine.empty(inCity: true) == HomeLine.quiet)
    }

    @Test func leaveByIsTheStartLessTheWalk() {
        let trivia = gathering("Trivia", startsIn: 60, meters: 1440) // 18 minutes at 80 m a minute
        let leave = HomeLine.leaveBy(trivia, now: now)
        let expected = now.addingTimeInterval(42 * 60)
        #expect(abs(leave.timeIntervalSince(expected)) < 60)
        // A route from Apple Maps overrides the estimate.
        let routed = HomeLine.leaveBy(trivia, now: now, walkMinutes: 30)
        #expect(routed < leave)
        // Already late, or already on: leave now.
        #expect(HomeLine.leaveBy(gathering("Late", startsIn: 5, meters: 1600), now: now) == now)
    }

    @Test func wrenSaysWhenATeamNeedsPeople() {
        let line = HomeLine.sentence(for: gathering("Trivia", startsIn: 60, capacity: 6, going: 4), now: now, clock: clock)
        #expect(line.lead.hasPrefix("Trivia at The Dubliner starts at T"))
        #expect(line.emphasis == "they need two.")
        #expect(line.tail.contains("Leave at T"))
    }

    @Test func wrenSaysOneMore() {
        let line = HomeLine.sentence(for: gathering("Doubles", startsIn: 60, capacity: 4, going: 3), now: now, clock: clock)
        #expect(line.emphasis == "they need one more.")
    }

    @Test func somethingOnNowIsAWalkAway() {
        let line = HomeLine.sentence(for: gathering("Backyard set", startsIn: -20, meters: 400, going: 14, place: "Mira's backyard"), now: now, clock: clock)
        #expect(line.lead.contains("is on now"))
        #expect(line.emphasis == "14 people are going.")
        #expect(line.tail.contains("5-minute walk"))
    }

    @Test func dropsTalkAboutWhatsLeft() {
        let line = HomeLine.sentence(for: drop(left: 4, total: 20), now: now, clock: clock)
        #expect(line.lead.contains("opens at T"))
        #expect(line.emphasis == "4 of 20 left.")
        let plenty = HomeLine.sentence(for: drop(left: 18, total: 20), now: now, clock: clock)
        #expect(plenty.emphasis.isEmpty)
    }

    @Test func captionsAreShort() {
        #expect(HomeLine.caption(gathering("Trivia, team needs two", startsIn: 30)) == "Trivia")
        let long = HomeLine.caption(gathering("A very long name for a gathering that goes on", startsIn: 30))
        #expect(long.count <= 20)
        #expect(long.hasSuffix("…"))
    }
}

@Suite("Signal")
struct SignalTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func candidate(_ title: String, startsIn minutes: Double, capacity: Int = 0, going: Int = 0) -> Candidate {
        Candidate(
            id: UUID(), kind: .gathering, title: title, category: .play,
            start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + 90) * 60),
            meters: 400, capacity: capacity, going: going
        )
    }

    @Test func topThreeSkipsFullOnes() {
        let full = candidate("Full", startsIn: 10, capacity: 4, going: 4)
        let shown = [full, candidate("A", startsIn: 20), candidate("B", startsIn: 30), candidate("C", startsIn: 40), candidate("D", startsIn: 50)]
        #expect(Signal.top(shown).map(\.title) == ["A", "B", "C"])
    }

    @Test func rulerRunsFiveHours() throws {
        #expect(Signal.position(of: now, now: now) == 0)
        let half = try #require(Signal.position(of: now.addingTimeInterval(9000), now: now))
        #expect(abs(half - 0.5) < 0.001)
        #expect(Signal.position(of: now.addingTimeInterval(6 * 3600), now: now) == nil)
    }

    @Test func hourTicksAreOnTheHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let ticks = Signal.hourTicks(now: now, calendar: cal)
        #expect(!ticks.isEmpty)
        #expect(ticks.count <= 5)
        for t in ticks {
            #expect(cal.component(.minute, from: t) == 0)
            #expect(t > now)
        }
    }
}

@Suite("The quote")
struct QuoteTextTests {
    @Test func theWordsAreExact() {
        let expected = "I do not wish you much happiness\u{2014}it would bore you; I do not wish you trouble either; but, following the people\u{2019}s philosophy, I will simply repeat: \u{2018}Live more\u{2019} and try somehow not to be too bored; this useless wish I am adding on my own."
        #expect(QuoteText.full == expected)
        #expect(QuoteText.author == "Fyodor Dostoevsky")
        #expect(QuoteText.source == "Demons")
    }

    @Test func eachPartHasATimeAndTheyRunInOrder() {
        let parts = QuoteText.clauses.count + 3
        #expect(QuoteText.times.count == parts)
        #expect(QuoteText.times == QuoteText.times.sorted())
        #expect(QuoteText.buttonStep == QuoteText.times.count)
    }
}

@Suite("Wren")
struct WrenTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aPlanBecomesADraft() {
        let a = Wren.answer("host a slow jog sat 8am around the lake", candidates: [], taste: Taste(), now: now)
        #expect(a.draft != nil)
        #expect(a.picks.isEmpty)
    }

    @Test func aMoodFindsWhatsReallyNearby() {
        let jam = Candidate(
            id: UUID(), kind: .gathering, title: "Backyard jam", category: .music,
            start: now.addingTimeInterval(1800), end: now.addingTimeInterval(9000), meters: 300
        )
        let game = Candidate(
            id: UUID(), kind: .gathering, title: "Pickup soccer", category: .play,
            start: now.addingTimeInterval(1800), end: now.addingTimeInterval(9000), meters: 300
        )
        let a = Wren.answer("live music", candidates: [jam, game], taste: Taste(), now: now)
        #expect(a.picks.map(\.title) == ["Backyard jam"])
        #expect(a.reply.contains("Backyard jam"))
    }

    @Test func nothingMatchingOffersToHost() {
        let a = Wren.answer("karaoke", candidates: [], taste: Taste(), now: now)
        #expect(a.picks.isEmpty)
        #expect(a.reply.contains("host"))
    }
}
