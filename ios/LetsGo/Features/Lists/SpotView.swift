import SwiftUI
import SwiftData
import CoreLocation

/// A place from the city list: what it is, when to go, what not to miss, who's going
/// there soon, and a stamp once you've actually been.
struct SpotView: View {
    var spot: Spot

    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @Query private var stamps: [Stamp]
    @Query(sort: \Gathering.start) private var gatherings: [Gathering]
    @State private var earned: Stamp?
    @State private var hosting: GatheringDraft?
    @State private var here: HereMoment?

    /// Close enough to count as being there.
    private let checkInRadius: CLLocationDistance = 200

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let now = timeline.date
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SpotArt(spot: spot)
                        .frame(height: 230)
                        .clipShape(.rect(cornerRadius: 24))
                    titleBlock
                    InfoStrip(items: facts(now: now))
                    if let best = spot.best { TipNote(text: "**Best:** \(best)") }
                    if let tip = spot.tip { TipNote(text: tip) }
                    stops
                    people(now: now)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Palette.bg)
            .safeAreaInset(edge: .bottom) { actions }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $here) { YouAreHereView(moment: $0) }
        .sheet(item: $hosting) { NewGatheringView(draft: $0) }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(spot.kind.label) · \(spot.area)").eyebrow(spot.kind.color)
            Text(spot.title).display(28).foregroundStyle(Palette.ink)
            Text(spot.blurb).font(.system(size: 15)).foregroundStyle(Palette.muted)
        }
    }

    private func facts(now: Date) -> [InfoStrip.Item] {
        var items: [InfoStrip.Item] = []
        if let miles = spot.miles {
            items.append(.init(label: "Distance", value: "\(miles.formatted(.number.precision(.fractionLength(1)))) mi", detail: spot.kind == .hike ? "there and back" : "end to end"))
        }
        if let minutes = spot.minutes {
            let value = minutes < 60 ? "\(minutes) min" : "\((Double(minutes) / 60).formatted(.number.precision(.fractionLength(0...1)))) hr"
            items.append(.init(label: "Time", value: value, detail: "at a stroll"))
        }
        if let gain = spot.gainFeet {
            items.append(.init(label: "Climb", value: "\(gain) ft", detail: gain > 400 ? "some stairs" : "gentle"))
        }
        let meters = location.center.distance(to: spot.coordinate)
        let walk = Walk.minutes(meters)
        if items.count < 3 {
            if walk <= 30 {
                items.append(InfoStrip.Item(label: "From you", value: "\(walk) min", detail: "walk"))
            } else {
                items.append(InfoStrip.Item(label: "From you", value: "\((meters / 1609.34).formatted(.number.precision(.fractionLength(1)))) mi", detail: "away"))
            }
        }
        if items.count < 3, let set = Sun.sunset(on: now, at: spot.coordinate) {
            items.append(.init(label: "Sunset", value: set.formatted(.dateTime.hour().minute()), detail: set > now ? "today" : "was today"))
        }
        if items.count < 3 {
            items.append(.init(label: "Area", value: spot.kind.label, detail: spot.area))
        }
        return Array(items.prefix(3))
    }

    @ViewBuilder
    private var stops: some View {
        if let stops = spot.stops, !stops.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Don't miss").eyebrow()
                VStack(spacing: 0) {
                    ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                        HStack(spacing: 12) {
                            Text("\(i + 1)")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(spot.kind.color)
                                .frame(width: 28, height: 28)
                                .background(spot.kind.color.opacity(0.16), in: .circle)
                            Text(stop).font(.system(size: 15, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if i < stops.count - 1 { Divider().overlay(Palette.line).padding(.leading, 54) }
                    }
                }
                .card(radius: 18)
            }
        }
    }

    private func people(now: Date) -> some View {
        let nearby = gatherings
            .filter { !$0.hasEnded(at: now) && $0.coordinate.distance(to: spot.coordinate) < 600 }
            .prefix(3)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Go with people").eyebrow()
            if nearby.isEmpty {
                Text("Nobody's posted a time here yet. Pick one and anyone nearby can come.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(nearby)) { g in
                        NavigationLink(value: g) { GatheringLine(gathering: g, now: now) }
                            .buttonStyle(.plain)
                    }
                }
                .card(radius: 18)
            }
            Button { hosting = draft(now: now) } label: {
                Label("Post a time, anyone can join", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    /// A gathering at this place, starting at the top of the hour after next.
    private func draft(now: Date) -> GatheringDraft {
        let cal = Calendar.current
        let start = cal.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)?
            .addingTimeInterval(3600) ?? now.addingTimeInterval(2 * 3600)
        let category: Genre = spot.kind.genre == .food ? .party : spot.kind.genre
        return GatheringDraft(
            title: spot.kind == .hike ? "Hike: \(spot.title)" : spot.title,
            category: category,
            start: start,
            end: start.addingTimeInterval(2 * 3600),
            placeName: spot.title,
            latitude: spot.lat,
            longitude: spot.lon
        )
    }

    // MARK: Check in

    @ViewBuilder
    private var actions: some View {
        let stamp = stamps.first { $0.key == spot.stampKey }
        let meters = location.center.distance(to: spot.coordinate)
        VStack(spacing: 8) {
            if let stamp {
                Label("Stamped \(stamp.earnedAt.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.live)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            } else if meters <= checkInRadius && !location.isUsingFallback {
                Button {
                    earned = Ledger.visit(spot, context: context)
                    Ledger.arrive(spot.title, genre: spot.kind.genre, with: [], context: context)
                    here = HereMoment(title: spot.title, genre: spot.kind.genre, checkedInAt: .now, friends: [], stamped: earned != nil)
                } label: {
                    Label("I'm here. Stamp it.", systemImage: "checkmark.seal")
                }
                .buttonStyle(PrimaryButtonStyle(color: spot.kind.color))
            } else {
                if let maps = directions(meters: meters) {
                    Link(destination: maps) {
                        Label(meters > 2400 ? "Get there by transit" : "Walk there", systemImage: meters > 2400 ? "tram.fill" : "figure.walk")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                Text("Check in when you're there for a stamp.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private func directions(meters: Double) -> URL? {
        var u = URLComponents(string: "https://maps.apple.com/")
        u?.queryItems = [
            URLQueryItem(name: "daddr", value: "\(spot.lat),\(spot.lon)"),
            URLQueryItem(name: "q", value: spot.title),
            URLQueryItem(name: "dirflg", value: meters > 2400 ? "r" : "w"),
        ]
        return u?.url
    }
}

/// One gathering as a row that links to its page.
struct GatheringLine: View {
    var gathering: Gathering
    var now: Date

    var body: some View {
        HStack(spacing: 12) {
            CategoryDot(category: gathering.category, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(gathering.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(line).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var line: String {
        var parts = [When.relative(gathering.start, end: gathering.end, now: now)]
        if gathering.going > 0 { parts.append("\(gathering.going) going") }
        return parts.joined(separator: " · ")
    }
}
