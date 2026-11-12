import SwiftUI
import SwiftData
import MapKit

/// The opening screen: the map, edge to edge, in MapKit's own standard style (light by
/// day, the evening map after dark, as the phone's appearance goes). A glass search
/// capsule and filter button over it, glass chips under them, pins in their kind's colour
/// that pulse as they fill, a dotted yellow ring for a ten-minute walk, the route to
/// Wren's pick in yellow, and the pick itself on a glass sheet at the bottom. "Quick
/// pick" turns it into Signal: black and lime, the top three numbered, with walking routes
/// and when to leave for each.
struct HomeView: View {
    @Environment(LocationService.self) private var location
    @Environment(SyncStatus.self) private var sync
    @Environment(\.modelContext) private var context
    @Query(sort: \Gathering.start) private var gatherings: [Gathering]
    @Query private var kitchens: [Kitchen]
    @Query private var notes: [TasteNote]
    @Query private var people: [Person]

    @Environment(HomeModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var position: MapCameraPosition = HomeView.followMe
    @State private var hostingBlank = false
    /// "Not tonight": skipped on the Wren card for this session.
    @State private var skipped: Set<UUID> = []
    @State private var routes = RouteBook()
    @State private var joining = false
    @State private var problem: String?
    @Namespace private var mapScope

    /// Ten minutes at 80 m a minute.
    static let walkRadius: CLLocationDistance = 800

    /// Follow you, or (without a fix) look at the fallback neighborhood. Not `.automatic`:
    /// that would frame the night wash, which is 30 km across.
    static var followMe: MapCameraPosition {
        .userLocation(fallback: .region(MKCoordinateRegion(center: LocationService.fallback, latitudinalMeters: 3000, longitudinalMeters: 3000)))
    }

    var body: some View {
        @Bindable var model = model
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            let signal = model.mode == .signal && !model.walking
            // Signal's ruler moves "now" up to five hours ahead.
            let at = signal && model.window == .now ? now.addingTimeInterval(model.ahead * 3600) : now
            let all = Nearby.candidates(gatherings: gatherings, kitchens: kitchens, from: location.center, now: at)
            let taste = Nearby.taste(notes: notes, gatherings: gatherings, kitchens: kitchens)
            let friends = tonight(all, taste: taste, now: at)
            let shown = filtered(all, taste: taste, friends: friends, now: now, at: at)
            let top = signal ? Signal.top(shown) : []
            // Wren's pick: the first thing not skipped. Its route is drawn in yellow.
            let pick = signal || model.walking ? nil : shown.first { !skipped.contains($0.id) }
            ZStack(alignment: .top) {
                map(shown: shown, top: top, pick: pick, friends: friends, now: at, signal: signal)
                if signal { shade() }
                if model.walking { SkyBand(now: now).allowsHitTesting(false) }
                VStack(alignment: .leading, spacing: 12) {
                    header(signal: signal, onNow: shown.filter { $0.start <= at }.count, now: now)
                    if !model.walking { chips(signal: signal, friendsOut: Crowd.mapped(friends, now: at).count) }
                }
                .padding(.top, 4)
            }
            .overlay(alignment: .bottom) {
                bottom(signal: signal, top: top, shown: shown, friends: friends, now: now, at: at)
            }
            .mapScope(mapScope)
            .task(id: (top + (pick.map { [$0] } ?? [])).map(\.id.uuidString).joined() + location.center.roundedKey) {
                let wanted = top + (pick.map { [$0] } ?? [])
                if !wanted.isEmpty { await routes.load(wanted, from: location.center) }
            }
        }
        .background(model.mode == .signal ? SignalPalette.bg : Palette.bg)
        .errorAlert($problem)
        .sheet(isPresented: $model.listOpen) {
            NearbySheet()
                .environment(model)
                .environment(location)
                .environment(sync)
                .presentationDetents([HomeModel.half, .large], selection: $model.detent)
                .presentationBackgroundInteraction(.enabled(upThrough: HomeModel.half))
                // Dragging the content moves the sheet first, then scrolls once it's all the way up.
                .presentationContentInteraction(.resizes)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $hostingBlank) { NewGatheringView(draft: nil) }
        .onChange(of: model.focus) { _, focus in
            guard let focus, !model.walking else { return }
            withAnimation(.smooth(duration: 0.6)) {
                // Sit the place in the visible top half, above the sheet.
                position = .camera(MapCamera(centerCoordinate: focus.coordinate.offset(east: 0, north: -260), distance: 2200))
            }
        }
        .onChange(of: location.center.roundedKey) { if model.walking { followInWorld() } }
        .onAppear {
            // In the city, the listings are spread out: start wide enough to see a few neighborhoods.
            if CityListings.covers(location.center) {
                position = .camera(MapCamera(centerCoordinate: location.center.offset(east: 0, north: -900), distance: 9000))
            }
        }
    }

    // MARK: Bottom

    /// Your people tonight, where the server says they are.
    private func tonight(_ all: [Candidate], taste: Taste, now: Date) -> [Friend] {
        people.map(\.snapshot)
    }

    private func filtered(_ all: [Candidate], taste: Taste, friends: [Friend], now: Date, at: Date) -> [Candidate] {
        let shown = model.query.isEmpty ? model.visible(all, now: at, taste: taste) : Search.results(model.query, in: all, now: now)
        guard model.friendsOnly else { return shown }
        return shown.filter { !Crowd.going(to: $0, among: friends).isEmpty }
    }

    /// Signal's panel or Wren's card, with the locate and walk buttons over it.
    private func bottom(signal: Bool, top: [Candidate], shown: [Candidate], friends: [Friend], now: Date, at: Date) -> some View {
        @Bindable var model = model
        return VStack(alignment: .trailing, spacing: 10) {
            mapButtons
            if !model.walking {
                if signal {
                    SignalPanel(
                        top: top, total: shown.count, now: now, at: at,
                        walkMinutes: routes.legs.mapValues(\.minutes), ahead: $model.ahead,
                        onOpen: { open($0) }, onList: { model.showList() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    WrenCard(
                        picks: shown.filter { !skipped.contains($0.id) }, now: at, friends: friends,
                        here: location.center, inCity: CityListings.covers(location.center), busy: joining,
                        walkMinutes: shown.first { !skipped.contains($0.id) }.flatMap { routes.legs[$0.id]?.minutes },
                        onOpen: { open($0) }, onJoin: { join($0) }, onSkip: { skip($0) },
                        onList: { model.showList() }, onHost: { hostingBlank = true }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // MARK: Map

    private func map(shown: [Candidate], top: [Candidate], pick: Candidate?, friends: [Friend], now: Date, signal: Bool) -> some View {
        let ranked = shown.prefix(4).map(\.id)
        let numbers = Dictionary(top.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { a, _ in a })
        return Map(position: $position, scope: mapScope) {
            // Signal darkens the streets under its labels. The everyday map is MapKit's own,
            // untinted: light by day, the evening map after dark.
            if signal {
                MapPolygon(coordinates: Self.wash(around: location.center))
                    .foregroundStyle(SignalPalette.bg.opacity(0.62))
                    .mapOverlayLevel(level: .aboveRoads)
            }
            if !signal && !model.walking {
                MapCircle(center: location.center, radius: Self.walkRadius)
                    .foregroundStyle(.clear)
                    .stroke(Palette.walk, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2, 6]))
                if let pick, let leg = routes.legs[pick.id] {
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(Palette.walk, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            if signal {
                ForEach(top) { c in
                    if let leg = routes.legs[c.id] {
                        MapPolyline(coordinates: leg.coordinates)
                            .stroke(SignalPalette.lime.opacity(0.25), lineWidth: 7)
                        MapPolyline(coordinates: leg.coordinates)
                            .stroke(SignalPalette.lime, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            if model.walking {
                Annotation("You", coordinate: location.center, anchor: .bottom) { Avatar() }
                    .annotationTitles(.hidden)
            } else {
                UserAnnotation()
            }
            if !model.walking {
                ForEach(Crowd.mapped(friends, now: now)) { f in
                    if let at = f.coordinate {
                        Annotation(f.name, coordinate: at, anchor: .center) {
                            if signal {
                                Text(f.initial)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(SignalPalette.ink)
                                    .frame(width: 20, height: 20)
                                    .background(SignalPalette.bg, in: .circle)
                                    .overlay(Circle().stroke(SignalPalette.ink, lineWidth: 1.5))
                            } else {
                                FriendPin(friend: f, now: now)
                            }
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            ForEach(shown) { c in
                Annotation(c.title, coordinate: .init(latitude: c.lat, longitude: c.lon), anchor: model.walking ? .bottom : .center) {
                    Button { open(c) } label: {
                        pin(c, rank: ranked.firstIndex(of: c.id), number: numbers[c.id], picked: c.id == pick?.id, now: now, signal: signal)
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        // MapKit's own standard map, kept quiet: muted, with only parks, beaches and transit marked.
        .mapStyle(.standard(elevation: model.walking ? .realistic : .flat, emphasis: .muted, pointsOfInterest: .including([.park, .beach, .publicTransport])))
        // Signal is a night look whatever the time: its map stays dark.
        .environment(\.colorScheme, signal ? .dark : colorScheme)
        .mapControls {
            // Shown from the floating column instead (see `mapScope`).
            MapCompass().mapControlVisibility(.hidden)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func pin(_ c: Candidate, rank: Int?, number: Int?, picked: Bool, now: Date, signal: Bool) -> some View {
        if signal {
            if let number {
                SignalPin(number: number, minutes: routes.legs[c.id]?.minutes ?? c.walkMinutes, title: c.title)
            } else {
                SignalDot(later: c.start.timeIntervalSince(now) > 90 * 60)
            }
        } else if model.walking {
            VStack(spacing: 0) {
                NightPin(pick: c, size: 30, now: now, showsCaption: false)
                Beam(color: c.category.color)
            }
        } else if picked {
            NightPin(pick: c, size: 34, now: now, showsCaption: true, picked: true)
        } else if let rank {
            NightPin(pick: c, size: rank == 0 || model.selectedID == c.id ? 30 : 26, now: now, showsCaption: true)
        } else if model.selectedID == c.id {
            NightPin(pick: c, size: 30, now: now, showsCaption: true)
        } else {
            MapDot(genre: c.category, later: c.start.timeIntervalSince(now) > 90 * 60)
        }
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

    // MARK: Over the map

    /// Signal's black fade behind its header. The everyday map has none: glass sits on the map.
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

    @ViewBuilder
    private func header(signal: Bool, onNow: Int, now: Date) -> some View {
        if signal {
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
        } else {
            HStack(spacing: 8) {
                Button { model.startSearch() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                        Text(HomeLine.searchPrompt(model.window, inCity: CityListings.covers(location.center)))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityLabel(CityListings.covers(location.center) ? "Search San Francisco" : "Search nearby")
                filterMenu
            }
            .padding(.horizontal, 16)
        }
    }

    /// The round glass button by the search: the kinds that aren't chips, Quick pick and hosting.
    private var filterMenu: some View {
        @Bindable var model = model
        let menuKinds: [Genre] = [.play, .move, .party]
        let narrowed = model.friendsOnly || (model.genre.map { menuKinds.contains($0) } ?? false)
        return Menu {
            Button { model.toggleSignal() } label: { Label("Quick pick", systemImage: "bolt.fill") }
            Button { hostingBlank = true } label: { Label("Host something", systemImage: "plus") }
            Section("Show only") {
                ForEach(menuKinds) { g in
                    Toggle(isOn: Binding(get: { model.genre == g }, set: { model.genre = $0 ? g : nil })) {
                        Label(g.plural, systemImage: g.symbol)
                    }
                }
                Toggle(isOn: $model.friendsOnly) { Label("Friends going", systemImage: "person.2") }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(narrowed ? Palette.accentSoft : Palette.ink)
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Filters")
    }

    /// "SAN FRANCISCO · SUNSET 6:07"
    private func placeLine(now: Date) -> String {
        var parts = [CityListings.covers(location.center) ? "SAN FRANCISCO" : "NEAR YOU"]
        if let set = Sun.sunset(on: now, at: location.center), set > now {
            parts.append("SUNSET \(NightPin.hour(set))")
        }
        return parts.joined(separator: " · ")
    }

    private func chips(signal: Bool, friendsOut: Int) -> some View {
        @Bindable var model = model
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if signal {
                    // Signal's own way back out, in its own colours.
                    Button { model.toggleSignal() } label: {
                        Label("Quick pick", systemImage: "bolt.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 15)
                            .frame(height: 36)
                            .foregroundStyle(SignalPalette.bg)
                            .background(SignalPalette.lime, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Back to the map")
                    .accessibilityAddTraits(.isSelected)
                }
                ForEach(TimeWindow.allCases) { w in
                    FilterChip(title: w.label, on: model.window == w) {
                        model.window = w
                        if w != .now { model.ahead = 0 }
                    }
                }
                FilterChip(title: "Free", on: model.freeOnly) { model.freeOnly.toggle() }
                ForEach([Genre.food, .music]) { g in
                    FilterChip(title: g.plural, on: model.genre == g) { model.genre = model.genre == g ? nil : g }
                }
                if friendsOut > 0 || model.friendsOnly {
                    FilterChip(title: "Friends \u{00B7} \(friendsOut)", on: model.friendsOnly) { model.friendsOnly.toggle() }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
    }

    private var mapButtons: some View {
        VStack(spacing: 10) {
            if !model.walking { MapCompass(scope: mapScope) }
            circleButton(model.walking ? "map" : "figure.walk", label: model.walking ? "Back to the map" : "Walk view", on: model.walking) {
                toggleWalk()
            }
            circleButton("location.fill", label: "Show my location", on: position.followsUserLocation) { recenter() }
        }
        .padding(.trailing, 8)
    }

    private func circleButton(_ symbol: String, label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(on ? Palette.accentSoft : Palette.ink)
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private func open(_ c: Candidate) {
        switch c.kind {
        case .gathering:
            if let g = gatherings.first(where: { $0.id == c.id }) { model.open(g, id: g.id, at: g.coordinate) }
        case .drop:
            if let k = kitchens.first(where: { $0.id == c.id }) { model.open(k, id: k.id, at: k.coordinate) }
        }
    }

    private func join(_ c: Candidate) {
        guard c.kind == .gathering, let g = gatherings.first(where: { $0.id == c.id }) else { return open(c) }
        joining = true
        Task {
            await attempt($problem) { () throws(APIError) in try await Sync.join(g, context: context) }
            joining = false
        }
    }

    private func skip(_ c: Candidate) {
        withAnimation(.snappy) { _ = skipped.insert(c.id) }
    }

    private func toggleWalk() {
        model.walking.toggle()
        if model.walking {
            model.listOpen = false
            model.mode = .daylight
            followInWorld()
        } else {
            withAnimation(.smooth(duration: 0.8)) { position = HomeView.followMe }
        }
    }

    private func recenter() {
        if model.walking { followInWorld(); return }
        withAnimation(.smooth(duration: 0.8)) { position = HomeView.followMe }
    }

    private func followInWorld() {
        withAnimation(.smooth(duration: 1.0)) {
            position = .camera(MapCamera(centerCoordinate: location.center, distance: 520, heading: 20, pitch: 68))
        }
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

/// You, in walk view: a small figure standing on the street.
struct Avatar: View {
    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0xF2D3B6), Color(hex: 0xC99A78)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 18, height: 18)
            UnevenRoundedRectangle(topLeadingRadius: 11, bottomLeadingRadius: 7, bottomTrailingRadius: 7, topTrailingRadius: 11)
                .fill(LinearGradient(colors: [Color(hex: 0x6E8BFF), Color(hex: 0x3E58D6)], startPoint: .top, endPoint: .bottom))
                .frame(width: 24, height: 26)
            Ellipse().fill(.black.opacity(0.4)).frame(width: 30, height: 8).offset(y: -4)
        }
        .shadow(color: .black.opacity(0.3), radius: 4, y: 3)
        .accessibilityLabel("You")
    }
}

/// The light column under a marker in walk view.
struct Beam: View {
    var color: Color

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [color, color.opacity(0)], startPoint: .top, endPoint: .bottom))
            .frame(width: 2, height: 46)
    }
}

/// A band of sky over walk view that follows the real time of day.
struct SkyBand: View {
    var now: Date

    var body: some View {
        let hour = Calendar.current.component(.hour, from: now)
        let top: Color = switch hour {
        case 5..<9: Color(hex: 0xF4B78F)
        case 9..<17: Color(hex: 0x8EC3F2)
        case 17..<20: Color(hex: 0xE58F73)
        default: Color(hex: 0x1B2346)
        }
        LinearGradient(colors: [top.opacity(0.75), top.opacity(0)], startPoint: .top, endPoint: .bottom)
            .frame(height: 220)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
    }
}
