import Testing
import Foundation
import CoreLocation
@testable import LetsGo

@Suite("The lamppost poster")
struct PosterTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    /// Thursday, November 12, 2026.
    func thursday(_ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: h, minute: m))!
    }

    func game(mine: Bool = true, onServer: Bool = true, recurring: String = "") -> Gathering {
        let g = Gathering(
            title: "Pickup soccer", category: .play, details: "All levels.", placeName: "The park on Elm St",
            coordinate: .init(latitude: 37.76, longitude: -122.42), start: thursday(18, 30), end: thursday(20, 30),
            capacity: 12, hostName: "You", bring: "water", recurring: recurring, isMine: mine
        )
        if onServer { g.remoteID = UUID() }
        return g
    }

    @Test func onlyARealGatheringYouHostGetsAPoster() {
        let before = thursday(12)
        #expect(PosterCopy.unavailable(game(), now: before) == nil)
        #expect(PosterCopy.unavailable(game(mine: false), now: before) != nil)
        #expect(PosterCopy.unavailable(game(onServer: false), now: before) != nil)
        #expect(PosterCopy.unavailable(game(), now: thursday(21)) == "It's over.")
        let listing = game()
        listing.listingKey = "Pickup soccer|x"
        #expect(PosterCopy.unavailable(listing, now: before) != nil)
    }

    @Test func theWordsMatchTheDrawing() {
        let weekly = game(recurring: "Every Thursday")
        #expect(PosterCopy.when(weekly, calendar: cal) == "EVERY THURSDAY · 6:30")
        #expect(PosterCopy.when(game(), calendar: cal) == "THU, NOV 12 · 6:30")
        #expect(PosterCopy.line(game()) == "The park on Elm St. Bring water. All levels.")
        let jog = game()
        jog.start = thursday(8)
        #expect(PosterCopy.when(jog, calendar: cal) == "THU, NOV 12 · 8:00 AM")
    }

    @Test func longLinesAreCutAtAWord() {
        let g = game()
        g.details = String(repeating: "Very long words here ", count: 20)
        let line = PosterCopy.line(g, limit: 60)
        #expect(line.count <= 61 && line.hasSuffix("…"))
    }

    @Test func weeklyMatchesTheServersRule() {
        #expect(PosterCopy.isWeekly("Every Thursday"))
        #expect(PosterCopy.isWeekly("every thursdays"))
        #expect(!PosterCopy.isWeekly(""))
        #expect(!PosterCopy.isWeekly("Every so often"))
        #expect(PosterCopy.weekly(from: thursday(18), calendar: cal) == "Every Thursday")
    }

    @Test func contentWaitsForTheLink() {
        let g = game()
        #expect(PosterCopy.content(g, calendar: cal) == nil)
        g.posterURL = "https://example.test/p/k7m3qx"
        g.posterShortText = "example.test/p/k7m3qx"
        let content = PosterCopy.content(g, calendar: cal)
        #expect(content?.title == "Pickup soccer")
        #expect(content?.shortText == "example.test/p/k7m3qx")
    }

    @Test func paperSizes() {
        #expect(PosterPaper.letter.size == CGSize(width: 612, height: 792))
        #expect(abs(PosterPaper.a4.size.height - 841.89) < 0.01)
        #expect(PosterPaper.local(Locale(identifier: "en_US")) == .letter)
        #expect(PosterPaper.local(Locale(identifier: "en_GB")) == .a4)
    }

    /// The finder squares sit top-left, top-right and bottom-left. A flipped code wouldn't scan everywhere.
    @Test func theQRCodeIsTheRightWayUp() throws {
        let m = try #require(QRMatrix.modules(for: "https://example.test/p/k7m3qx"))
        #expect(m.count == m.first?.count)
        let dark = m.enumerated().flatMap { y, row in row.enumerated().filter(\.element).map { (x: $0.offset, y: y) } }
        let minX = try #require(dark.map(\.x).min()), maxX = try #require(dark.map(\.x).max())
        let minY = try #require(dark.map(\.y).min()), maxY = try #require(dark.map(\.y).max())
        func finder(_ x0: Int, _ y0: Int) -> Bool {
            // A finder's outer ring is seven dark modules on each side, with a light ring inside.
            (0..<7).allSatisfy { m[y0][x0 + $0] && m[y0 + 6][x0 + $0] && m[y0 + $0][x0] && m[y0 + $0][x0 + 6] }
                && !m[y0 + 1][x0 + 1]
        }
        #expect(finder(minX, minY))
        #expect(finder(maxX - 6, minY))
        #expect(finder(minX, maxY - 6))
        #expect(!finder(maxX - 6, maxY - 6))
    }
}
