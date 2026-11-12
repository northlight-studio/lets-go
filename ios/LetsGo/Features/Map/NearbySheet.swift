import SwiftUI
import SwiftData
import MapKit

/// The list over the map: search, and what the map shows, grouped by when. Slim or full,
/// and a swipe down always puts it away. Places'
/// pages push inside it, so going back lands you on the list where you were.
struct NearbySheet: View {
    @Environment(HomeModel.self) private var model
    @Environment(LocationService.self) private var location
    @Query(sort: \Gathering.start) private var gatherings: [Gathering]
    @Query private var kitchens: [Kitchen]
    @Query private var people: [Person]

    @FocusState private var searching: Bool
    @State private var hosting: GatheringDraft?

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let now = timeline.date
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        searchBar
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                        if searching || !model.query.isEmpty {
                            searchContent(now: now)
                        } else {
                            nearby(now: now)
                        }
                    }
                    .padding(.bottom, 30)
                }
                .scrollDismissesKeyboard(.immediately)
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .containerBackground(.clear, for: .navigation)
            .navigationDestination(for: Gathering.self) { GatheringDetailView(gathering: $0) }
            .navigationDestination(for: Kitchen.self) { KitchenView(kitchen: $0) }
            .navigationDestination(for: Order.self) { OrderStatusView(order: $0) }
            .navigationDestination(for: MyKitchenRoute.self) { _ in MyKitchenView() }
            .navigationDestination(for: SupperLink.self) { SupperView(id: $0.id) }
        }
        .onChange(of: searching) { _, on in if on { model.detent = .large } }
        .onChange(of: model.path.count) { _, count in if count == 0 { model.selectedID = nil } }
        .onAppear {
            if model.wantsSearch {
                model.wantsSearch = false
                // Let the sheet finish presenting before the keyboard comes up.
                Task { try? await Task.sleep(for: .milliseconds(350)); searching = true }
            }
        }
        .sheet(item: $hosting) { NewGatheringView(draft: $0) }
    }

    // MARK: Search

    private var searchBar: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField(CityListings.covers(location.center) ? "Search San Francisco" : "Search nearby", text: $model.query)
                    .focused($searching)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 17))
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Palette.muted.opacity(0.16), in: .rect(cornerRadius: 12))
            if searching || !model.query.isEmpty {
                Button("Cancel") {
                    model.query = ""
                    searching = false
                    model.detent = HomeModel.slim
                }
                .font(.system(size: 17))
                .foregroundStyle(Palette.ink)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: searching)
    }

    @ViewBuilder
    private func searchContent(now: Date) -> some View {
        let all = Nearby.candidates(gatherings: gatherings, kitchens: kitchens, from: location.center, now: now)
            + SupperBook.shared.candidates(from: location.center, now: now)
        if model.query.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header("Try")
                ForEach(["Farmers market", "Trivia", "Run", "Salsa", "Free this weekend", "Pizza", "Comedy"], id: \.self) { s in
                    Button { model.query = s } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                                .frame(width: 38, height: 38)
                                .background(Palette.muted.opacity(0.14), in: .circle)
                            Text(s).font(.system(size: 17)).foregroundStyle(Palette.ink)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            let results = Search.results(model.query, in: all, now: now)
            if results.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Nothing matches \u{201C}\(model.query)\u{201D}.")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.muted)
                    Button {
                        hosting = GatheringDraft.from(SearchQuery.parse(model.query))
                    } label: {
                        Label("Host \u{201C}\(model.query)\u{201D}", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(16)
            } else {
                header("\(results.count) result\(results.count == 1 ? "" : "s")")
                rows(results, now: now)
            }
        }
    }

    // MARK: Nearby

    /// The same window as the map: the rail's day, until the thumb, narrowed by the filters.
    private func nearby(now: Date) -> some View {
        let all = Nearby.candidates(gatherings: gatherings, kitchens: kitchens, from: location.center, now: now)
            + SupperBook.shared.candidates(from: location.center, now: now)
        // Narrowed the same way as the map, so the two agree.
        let shown = model.narrowed(model.shown(all, now: now), friends: people.map(\.snapshot))
        let span = model.span(now: now)
        let day = Timetable.label(model.railDay(now: now), now: now)
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(Timetable.countLine(shown.count)) \u{00B7} \(day) \(Timetable.untilLine(model.railUntil(all, now: now), span: span))")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            if shown.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    let inCity = CityListings.covers(location.center)
                    Text(model.isFiltered ? "Nothing matches." : inCity ? "Nothing starts by then." : "Let's Go only knows San Francisco so far.")
                        .font(.headline)
                    Text(model.isFiltered ? model.emptyReason(inCity: inCity, hasFriends: !people.isEmpty)
                         : inCity ? "Drag the rail later or look at another day, or start something yourself."
                                  : "There are no listings here yet. Start something and it shows up for people nearby.")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                    Button { hosting = GatheringDraft.from(SearchQuery.parse("")) } label: {
                        Label("Host something", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(16)
            } else {
                ForEach(groups(shown, now: now), id: \.title) { group in
                    header(group.title, count: group.items.count)
                    rows(group.items, now: now)
                }
            }
        }
    }

    private struct Group { var title: String; var items: [Candidate] }

    /// On now, then the next few hours, then by day.
    private func groups(_ items: [Candidate], now: Date) -> [Group] {
        let cal = Calendar.current
        var order: [String] = []
        var buckets: [String: [Candidate]] = [:]
        for c in items {
            let title: String
            if c.start <= now {
                title = "On now"
            } else if cal.isDate(c.start, inSameDayAs: now) {
                title = c.start.timeIntervalSince(now) <= Picks.horizon ? "Next few hours" : "Later today"
            } else if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(c.start, inSameDayAs: t) {
                title = "Tomorrow"
            } else {
                title = c.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(c)
        }
        // Keep the time order of the groups even when the picks are ranked inside them.
        let rank = ["On now": 0, "Next few hours": 1, "Later today": 2, "Tomorrow": 3]
        return order
            .sorted { (rank[$0] ?? 10, buckets[$0]?.first?.start ?? .distantFuture) < (rank[$1] ?? 10, buckets[$1]?.first?.start ?? .distantFuture) }
            .map { Group(title: $0, items: buckets[$0] ?? []) }
    }

    // MARK: Rows

    private func header(_ title: String, count: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 20, weight: .bold))
            Spacer()
            if let count { Text("\(count)").font(.system(size: 15)).foregroundStyle(Palette.muted) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    private func rows(_ items: [Candidate], now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                PickRow(pick: c, now: now) { open(c) }
                    .padding(.horizontal, 16)
                    .contextMenu { menu(for: c) }
                if i < items.count - 1 { Divider().overlay(Palette.line).padding(.leading, 70) }
            }
        }
        .padding(.vertical, 2)
        .card(radius: 18)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func menu(for c: Candidate) -> some View {
        Button { open(c) } label: { Label("Open", systemImage: "arrow.up.right") }
        if let maps = directions(to: c) {
            Link(destination: maps) { Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") }
        }
        if c.kind == .gathering, let g = gatherings.first(where: { $0.id == c.id }), let s = g.sourceURL, let url = URL(string: s) {
            Link(destination: url) { Label("Website", systemImage: "safari") }
        }
    }

    private func directions(to c: Candidate) -> URL? {
        var u = URLComponents(string: "https://maps.apple.com/")
        u?.queryItems = [
            URLQueryItem(name: "daddr", value: "\(c.lat),\(c.lon)"),
            URLQueryItem(name: "q", value: c.kind == .gathering ? c.place : c.title),
            URLQueryItem(name: "dirflg", value: "w"),
        ]
        return u?.url
    }

    private func open(_ c: Candidate) {
        searching = false
        switch c.kind {
        case .gathering:
            if let g = gatherings.first(where: { $0.id == c.id }) { model.open(g, id: g.id, at: g.coordinate) }
        case .drop:
            if let k = kitchens.first(where: { $0.id == c.id }) { model.open(k, id: k.id, at: k.coordinate) }
        case .supper:
            model.open(SupperLink(id: c.id), id: c.id, at: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon))
        }
    }
}

/// One row in a list: tinted icon, name, the facts, and when.
struct PickRow: View {
    var pick: Candidate
    var now: Date
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CategoryDot(category: pick.category, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(pick.start <= now ? "Now" : pick.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(pick.start <= now ? Palette.accentSoft : Palette.ink)
                    Text(pick.start <= now ? "till \(pick.end.formatted(date: .omitted, time: .shortened))" : When.relative(pick.start, now: now))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        var parts: [String] = []
        if pick.kind == .gathering && !pick.place.isEmpty { parts.append(pick.place) }
        parts.append(Picks.reason(pick, now: now))
        return parts.joined(separator: " · ")
    }
}
