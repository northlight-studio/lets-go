import SwiftUI
import SwiftData
import MapKit

/// Quick pick: the Signal look, left as it was. Black and lime over a darkened MapKit map,
/// the top three numbered with real walking routes and when to leave for each, and a ruler
/// of the next five hours you can drag to look ahead. Dark whatever the phone's appearance.
struct SignalView: View {
    @Environment(LocationService.self) private var location
    @Environment(HomeModel.self) private var model
    @Query(sort: \Gathering.start) private var gatherings: [Gathering]
    @Query private var kitchens: [Kitchen]
    @Query private var notes: [TasteNote]
    @Query private var people: [Person]

    @State private var position: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(center: LocationService.fallback, latitudinalMeters: 3000, longitudinalMeters: 3000))
    )
    @State private var routes = RouteBook()

    var onOpen: (Candidate) -> Void

    var body: some View {
        @Bindable var model = model
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            // The ruler moves "now" up to five hours ahead.
            let at = now.addingTimeInterval(model.ahead * 3600)
            let all = Nearby.candidates(gatherings: gatherings, kitchens: kitchens, from: location.center, now: at)
            let taste = Nearby.taste(notes: notes, gatherings: gatherings, kitchens: kitchens)
            let friends = people.map(\.snapshot)
            let shown = picks(all, taste: taste, friends: friends, at: at)
            let top = Signal.top(shown)
            ZStack(alignment: .top) {
                map(shown: shown, top: top, friends: friends, at: at)
                shade()
                VStack(alignment: .leading, spacing: 12) {
                    header(onNow: shown.filter { $0.start <= at }.count, now: now)
                    exit
                }
                .padding(.top, 4)
            }
            .overlay(alignment: .bottom) {
                SignalPanel(
                    top: top, total: shown.count, now: now, at: at,
                    walkMinutes: routes.legs.mapValues(\.minutes), ahead: $model.ahead,
                    onOpen: onOpen, onList: { model.showList() }
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .task(id: top.map(\.id.uuidString).joined() + location.center.roundedKey) {
                if !top.isEmpty { await routes.load(top, from: location.center) }
            }
        }
        .background(SignalPalette.bg)
        .environment(\.colorScheme, .dark)
    }

    private func picks(_ all: [Candidate], taste: Taste, friends: [Friend], at: Date) -> [Candidate] {
        let soon = all.filter { c in
            TimeWindow.now.contains(start: c.start, end: c.end, now: at)
                && (model.genre.map { c.category == $0 } ?? true)
                && (!model.freeOnly || c.isFree)
        }
        let ranked = Picks.picks(soon, now: at, taste: taste, limit: 80)
        guard model.friendsOnly else { return ranked }
        return ranked.filter { !Crowd.going(to: $0, among: friends).isEmpty }
    }

    private func map(shown: [Candidate], top: [Candidate], friends: [Friend], at: Date) -> some View {
        let numbers = Dictionary(top.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { a, _ in a })
        return Map(position: $position) {
            MapPolygon(coordinates: Self.wash(around: location.center))
                .foregroundStyle(SignalPalette.bg.opacity(0.62))
                .mapOverlayLevel(level: .aboveRoads)
            ForEach(top) { c in
                if let leg = routes.legs[c.id] {
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(SignalPalette.lime.opacity(0.25), lineWidth: 7)
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(SignalPalette.lime, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            UserAnnotation()
            ForEach(Crowd.mapped(friends, now: at)) { f in
                if let spot = f.coordinate {
                    Annotation(f.name, coordinate: spot, anchor: .center) {
                        Text(f.initial)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(SignalPalette.ink)
                            .frame(width: 20, height: 20)
                            .background(SignalPalette.bg, in: .circle)
                            .overlay(Circle().stroke(SignalPalette.ink, lineWidth: 1.5))
                    }
                    .annotationTitles(.hidden)
                }
            }
            ForEach(shown) { c in
                Annotation(c.title, coordinate: .init(latitude: c.lat, longitude: c.lon), anchor: .center) {
                    Button { onOpen(c) } label: {
                        if let number = numbers[c.id] {
                            SignalPin(number: number, minutes: routes.legs[c.id]?.minutes ?? c.walkMinutes, title: c.title)
                        } else {
                            SignalDot(later: c.start.timeIntervalSince(at) > 90 * 60)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .including([.park, .beach, .publicTransport])))
        .mapControls { MapCompass().mapControlVisibility(.hidden) }
        .ignoresSafeArea()
    }

    /// A square about 30 km across: enough to cover any zoom the map is used at.
    static func wash(around c: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let d = 0.15
        return [
            .init(latitude: c.latitude + d, longitude: c.longitude - d),
            .init(latitude: c.latitude + d, longitude: c.longitude + d),
            .init(latitude: c.latitude - d, longitude: c.longitude + d),
            .init(latitude: c.latitude - d, longitude: c.longitude - d),
        ]
    }

    /// The black fade behind the header.
    private func shade() -> some View {
        let ground = SignalPalette.bg
        return LinearGradient(
            stops: [
                .init(color: ground.opacity(0.96), location: 0),
                .init(color: ground.opacity(0.8), location: 0.5),
                .init(color: ground.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 300)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    private func header(onNow: Int, now: Date) -> some View {
        HStack(alignment: .top) {
            LiveMoreMark(size: 92, stacked: true, dot: SignalPalette.lime, ink: SignalPalette.ink)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    BlinkDot(color: SignalPalette.lime)
                    Text("\(onNow) ON NOW")
                        .foregroundStyle(SignalPalette.lime)
                }
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.4)
                .monospacedDigit()
                Text(placeLine(now: now))
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(SignalPalette.muted)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 16)
    }

    /// Signal's own way back out, in its own colours.
    private var exit: some View {
        Button { model.toggleSignal() } label: {
            Label("Quick pick", systemImage: "bolt.fill")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 15)
                .frame(height: 36)
                .foregroundStyle(SignalPalette.bg)
                .background(SignalPalette.lime, in: .capsule)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityHint("Back to the map")
        .accessibilityAddTraits(.isSelected)
    }

    /// "SAN FRANCISCO · SUNSET 6:07"
    private func placeLine(now: Date) -> String {
        var parts = [CityListings.covers(location.center) ? "SAN FRANCISCO" : "NEAR YOU"]
        if let set = Sun.sunset(on: now, at: location.center), set > now {
            parts.append("SUNSET \(NightPin.hour(set))")
        }
        return parts.joined(separator: " · ")
    }
}

/// A small dot that blinks: "on now".
struct BlinkDot: View {
    var color: Color
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.25 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}
