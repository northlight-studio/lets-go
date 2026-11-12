import SwiftUI
import MapKit
import Observation

/// What the tabs, the map, its card and the list sheet share: the rail's day and how late
/// it looks, the filters, the search, the map's look, what's tapped, whether the list is
/// open and how tall, and where the map should look.
@Observable
final class HomeModel {
    /// The list's slim height: a few rows, with the map still there above it.
    static let slim = PresentationDetent.fraction(0.4)

    var tab: AppTab = .map
    /// The everyday map, or Signal when you just want to be told where to go.
    var mode: MapMode = .paper
    /// The rail's day (its start). Nil is today.
    var day: Date?
    /// How late the rail looks. Nil is its default (`Timetable.defaultUntil`).
    var until: Date?
    /// Hours past now Signal's ruler is showing.
    var ahead: Double = 0
    var genre: Genre?
    /// The chips under the search: all, food, events or friends.
    var layer: MapLayer = .all
    var freeOnly = false
    /// Only things your friends are going to.
    var friendsOnly = false
    var query = ""
    var listOpen = false
    var detent: PresentationDetent = HomeModel.slim
    /// Set when the list should open with the search field focused.
    var wantsSearch = false
    var path = NavigationPath()
    /// What you tapped on the map: its card is up, it's filled in the accent, and the walk
    /// ring and route are drawn.
    var selectedID: UUID?
    /// The map is being moved by hand: the tab bar steps out of the way.
    var exploring = false
    /// Bumped to ask the map to fly somewhere.
    var focus: Focus?
    /// The Dostoevsky splash: on first launch, and again from Passport.
    var showQuote = false
    /// A dark screen is up (gone dark, or a pocketed walk): phone time stops counting.
    var dark = false
    /// The morning after, when there's a night to show.
    var recap: Night?
    /// Put in Wren's box: what you said for a plan you're changing.
    var wrenDraft: String?
    /// The add-a-friend sheet on People, opened from the splash's "A friend sent me an invite".
    var addingFriend = false

    struct Focus: Equatable {
        var id = UUID()
        var latitude: Double
        var longitude: Double
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    // MARK: The rail

    /// The day the rail shows, as the start of that day. Falls back to today once the
    /// chosen day has passed.
    func railDay(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        guard let day, day > today else { return today }
        return day
    }

    func isToday(now: Date) -> Bool { railDay(now: now) == Calendar.current.startOfDay(for: now) }

    func span(now: Date) -> ClosedRange<Date> { Timetable.span(for: railDay(now: now), now: now) }

    /// How late the rail looks: what you dragged it to, kept inside today's rail as time passes.
    func railUntil(_ all: [Candidate], now: Date) -> Date {
        let rail = span(now: now)
        guard let until, until > rail.lowerBound else {
            return Timetable.defaultUntil(all, day: railDay(now: now), now: now)
        }
        return min(until, rail.upperBound)
    }

    /// What the map and the list show: the rail's window, narrowed by the chip (food or
    /// events; the Friends chip narrows by who's going, in `HomeView`), kind and price.
    func shown(_ all: [Candidate], now: Date) -> [Candidate] {
        Timetable.window(all, span: span(now: now), until: railUntil(all, now: now), now: now, genre: genre, freeOnly: freeOnly)
            .filter { layer == .friends || layer.keeps($0) }
    }

    func pickDay(_ d: Date, now: Date) {
        day = Calendar.current.isDate(d, inSameDayAs: now) ? nil : d
        until = nil
        selectedID = nil
    }

    var isFiltered: Bool { genre != nil || freeOnly || friendsOnly }

    // MARK: The list

    /// Open the list from the map, at its slim height.
    func showList() {
        tab = .map
        path = NavigationPath()
        detent = Self.slim
        selectedID = nil
        listOpen = true
    }

    func startSearch() {
        tab = .map
        wantsSearch = true
        detent = .large
        listOpen = true
    }

    /// Opens something's page in the list sheet and points the map at it.
    func open(_ value: some Hashable, id: UUID, at coordinate: CLLocationCoordinate2D) {
        tab = .map
        path = NavigationPath()
        path.append(value)
        selectedID = id
        focus = Focus(latitude: coordinate.latitude, longitude: coordinate.longitude)
        detent = .large
        listOpen = true
    }

    func toggleSignal() {
        withAnimation(.smooth(duration: 0.45)) {
            mode = mode == .signal ? .paper : .signal
            selectedID = nil
            if mode == .paper { ahead = 0 }
        }
    }
}

enum AppTab: Hashable {
    case map, people, plans, passport, wren
}

enum MapMode: Hashable {
    /// The everyday map: Neighborhood color, kitchens, events and friends as pins, with the time rail.
    case paper
    /// Black and lime: the top three, numbered, with when to leave.
    case signal
}
