import SwiftUI
import SwiftData
import MapKit

/// The opening screen: *Paperwhite, with a timetable*. The map is the whole screen, drawn
/// in our own style (`PaperMap`), and every thing on it is its start time. On top, only a
/// slim search field and a small filter circle. At the bottom, the time rail picks the day
/// and how late to look, between a list button and a recenter button. Tap a time for its
/// card; flick the card down to put it away. The tab bar steps aside while you move the
/// map and comes back when you stop. "Quick pick" in the filter menu turns it into Signal.
struct HomeView: View {
    @Environment(LocationService.self) private var location
    @Environment(SyncStatus.self) private var sync
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Query(sort: \Gathering.start) private var gatherings: [Gathering]
    @Query private var kitchens: [Kitchen]
    @Query private var people: [Person]

    @Environment(HomeModel.self) private var model
    @State private var camera: PaperMap.Camera?
    @State private var routes = RouteBook()
    @State private var hostingBlank = false
    @State private var joining = false
    @State private var problem: String?
    @State private var credits = false
    /// Moved by hand since it opened: don't jump to your first location fix.
    @State private var touched = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if model.mode == .signal {
                    SignalView(onOpen: { open($0) })
                } else {
                    paper
                }
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .toolbarVisibility(model.exploring && model.mode == .paper ? .hidden : .visible, for: .tabBar)
        }
        .errorAlert($problem)
        .sheet(isPresented: $model.listOpen) {
            NearbySheet()
                .environment(model)
                .environment(location)
                .environment(sync)
                .presentationDetents([HomeModel.slim, .large], selection: $model.detent)
                .presentationBackgroundInteraction(.enabled(upThrough: HomeModel.slim))
                // Dragging the content moves the sheet first, then scrolls once it's all the way up.
                .presentationContentInteraction(.resizes)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $hostingBlank) { NewGatheringView(draft: nil) }
        .confirmationDialog("Map data", isPresented: $credits, titleVisibility: .visible) {
            ForEach(MapCredit.all) { c in
                Button(c.name) { openURL(c.link) }
            }
        }
        .onChange(of: model.focus) { _, focus in
            guard let focus else { return }
            camera = .init(kind: .show(latitude: focus.latitude, longitude: focus.longitude))
        }
        .onChange(of: location.isUsingFallback) { _, fallback in
            // The first real fix: look there, unless you've already moved the map.
            guard !fallback, !touched else { return }
            camera = .init(kind: .recenter(latitude: location.center.latitude, longitude: location.center.longitude))
        }
    }

    /// For the People map (MapKit): follow you, or without a fix look at the fallback neighborhood.
    static var followMe: MapCameraPosition {
        .userLocation(fallback: .region(MKCoordinateRegion(center: LocationService.fallback, latitudinalMeters: 3000, longitudinalMeters: 3000)))
    }

    // MARK: Paperwhite

    private var paper: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            let all = Nearby.candidates(gatherings: gatherings, kitchens: kitchens, from: location.center, now: now)
            let shown = narrowed(model.shown(all, now: now), now: now)
            let selected = model.selectedID.flatMap { id in all.first { $0.id == id } }
            let onMap = selected.map { s in shown.contains(where: { $0.id == s.id }) ? shown : shown + [s] } ?? shown
            ZStack {
                map(items: onMap, selected: selected, now: now)
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottom(all: all, shown: shown, selected: selected, now: now)
                }
            }
            .task(id: (selected?.id.uuidString ?? "") + location.center.roundedKey) {
                if let selected { await routes.load([selected], from: location.center) }
            }
        }
        .background(Palette.bg)
    }

    private func map(items: [Candidate], selected: Candidate?, now: Date) -> some View {
        PaperMap(
            items: items, now: now, selectedID: selected?.id,
            start: location.center, startZoom: CityListings.covers(location.center) ? 13.6 : 14.5,
            here: location.center,
            route: selected.flatMap { routes.legs[$0.id]?.coordinates } ?? [],
            camera: camera, dark: colorScheme == .dark,
            onSelect: { select($0) },
            onTapMap: { tapMap() },
            onMoving: { moving in
                if moving { touched = true }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { model.exploring = moving }
            }
        )
        .ignoresSafeArea()
    }

    /// Friends going, when that filter is on.
    private func narrowed(_ shown: [Candidate], now: Date) -> [Candidate] {
        guard model.friendsOnly else { return shown }
        let friends = people.map(\.snapshot)
        return shown.filter { !Crowd.going(to: $0, among: friends).isEmpty }
    }

    // MARK: Top

    private var topBar: some View {
        let inCity = CityListings.covers(location.center)
        return HStack(spacing: 8) {
            Button { model.startSearch() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text(inCity ? "Search San Francisco" : "Search nearby")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.body)
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel(inCity ? "Search San Francisco" : "Search nearby")
            filterMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// The small glass circle by the search: kinds, free, friends, Quick pick and hosting.
    private var filterMenu: some View {
        @Bindable var model = model
        return Menu {
            Section("Show only") {
                ForEach(Genre.allCases) { g in
                    Toggle(isOn: Binding(get: { model.genre == g }, set: { model.genre = $0 ? g : nil })) {
                        Label(g.plural, systemImage: g.symbol)
                    }
                }
                Toggle(isOn: $model.freeOnly) { Label("Free", systemImage: "tag") }
                Toggle(isOn: $model.friendsOnly) { Label("Friends going", systemImage: "person.2") }
            }
            Button { model.toggleSignal() } label: { Label("Quick pick", systemImage: "bolt") }
            Button { hostingBlank = true } label: { Label("Host something", systemImage: "plus") }
        } label: {
            Image(systemName: model.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(model.isFiltered ? "Filters, on" : "Filters")
    }

    // MARK: Bottom

    @ViewBuilder
    private func bottom(all: [Candidate], shown: [Candidate], selected: Candidate?, now: Date) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let selected, !model.listOpen {
                EventCard(
                    item: selected, now: now,
                    walkMinutes: routes.legs[selected.id]?.minutes,
                    next: Timetable.thenNearby(after: selected, in: all),
                    busy: joining,
                    onOpen: { open(selected) },
                    onJoin: { join(selected) },
                    onDirections: { directions(to: selected) },
                    onNext: { select($0) },
                    onDismiss: { deselect() }
                )
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            } else {
                if shown.isEmpty { emptyNote(now: now) }
                credit
                HStack(alignment: .bottom, spacing: 8) {
                    circle("list.bullet", label: "Show the list") { model.showList() }
                    rail(all: all, count: shown.count, now: now)
                    circle("location", label: "Show my location") { recenter() }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: selected?.id)
    }

    private func rail(all: [Candidate], count: Int, now: Date) -> some View {
        let day = model.railDay(now: now)
        let span = model.span(now: now)
        let options = Timetable.days(now: now).map { TimeRail.Option(day: $0, label: Timetable.label($0, now: now)) }
        return TimeRail(
            count: count, span: span, until: model.railUntil(all, now: now),
            ticks: Timetable.ticks(span, isToday: model.isToday(now: now)),
            days: options, day: day,
            onDay: { model.pickDay($0, now: now) },
            onUntil: { model.until = $0 }
        )
    }

    /// Nothing in the window: say so, and offer the way to start.
    private func emptyNote(now: Date) -> some View {
        let inCity = CityListings.covers(location.center)
        return HStack(spacing: 10) {
            Text(inCity ? "Nothing starts by then. Drag the rail later, or start something."
                        : "Let's Go only knows San Francisco so far. Host something here and people nearby will see it.")
                .font(.footnote)
                .foregroundStyle(Palette.soft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Host") { hostingBlank = true }
                .buttonStyle(.glassProminent)
                .tint(Palette.prominent)
                .foregroundStyle(Palette.onProminent)
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    /// The map's credit, small and quiet; tap for the links.
    private var credit: some View {
        Button { credits = true } label: {
            Text("© OpenStreetMap")
                .font(.caption2)
                .foregroundStyle(Palette.faint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map data: OpenStreetMap contributors and OpenFreeMap")
    }

    private func circle(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private func select(_ c: Candidate) {
        model.listOpen = false
        model.selectedID = c.id
        model.exploring = false
        camera = .init(kind: .show(latitude: c.lat, longitude: c.lon))
    }

    private func deselect() {
        model.selectedID = nil
    }

    private func tapMap() {
        if model.selectedID != nil { deselect() }
        model.exploring = false
    }

    private func recenter() {
        camera = .init(kind: .recenter(latitude: location.center.latitude, longitude: location.center.longitude))
    }

    /// Its page, in the list sheet.
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

    /// Walking directions in Apple Maps.
    private func directions(to c: Candidate) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)))
        item.name = c.kind == .gathering && !c.place.isEmpty ? c.place : c.title
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

/// Whose map this is: the data, the tiles and the schema.
struct MapCredit: Identifiable {
    var name: String
    var link: URL
    var id: String { name }

    static let all: [MapCredit] = [
        MapCredit(name: "© OpenStreetMap contributors", link: URL(string: "https://www.openstreetmap.org/copyright")!),
        MapCredit(name: "OpenFreeMap", link: URL(string: "https://openfreemap.org")!),
        MapCredit(name: "© OpenMapTiles", link: URL(string: "https://www.openmaptiles.org")!),
    ]
}
