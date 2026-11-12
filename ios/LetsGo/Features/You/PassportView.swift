import SwiftUI
import SwiftData

/// The Passport tab: where you showed up, the city list, and what you're into,
/// with the settings at the bottom.
struct PassportTab: View {
    var body: some View {
        NavigationStack {
            ScrollView { PassportView() }
                .scrollIndicators(.hidden)
                .background(Palette.bg)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: CityListRoute.self) { _ in ListsView() }
                .navigationDestination(for: Spot.self) { SpotView(spot: $0) }
                .navigationDestination(for: Gathering.self) { GatheringDetailView(gathering: $0) }
        }
    }
}

/// Your passport: stamps for places you showed up, and what you're into.
struct PassportView: View {
    @Environment(\.modelContext) private var context
    @Environment(LocationService.self) private var location
    @Environment(HomeModel.self) private var model
    @Query(sort: \Stamp.earnedAt, order: .reverse) private var stamps: [Stamp]
    @Query(sort: \TasteNote.createdAt) private var notes: [TasteNote]
    @Query private var gatherings: [Gathering]
    @Query private var orders: [Order]
    @Query(sort: \Night.evening, order: .reverse) private var nights: [Night]
    @Query private var people: [Person]

    @Environment(SyncStatus.self) private var sync
    @State private var newNote = ""
    @AppStorage(APIClient.nameKey) private var displayName = ""
    @AppStorage(APIConfig.overrideKey) private var serverURL = ""

    /// Stamps you can work toward, shown locked until earned.
    private let goals: [(key: String, title: String, symbol: String, category: Genre)] = [
        ("first-checkin", "First show-up", "figure.wave", .play),
        ("first-host", "Hosted one", "flag.fill", .party),
        ("first-poster", "Put one up", "doc.richtext", .party),
        ("opened-kitchen", "Opened a kitchen", "house.fill", .food),
        ("first-review", "First review", "text.bubble.fill", .food),
        ("checkins-5", "Five show-ups", "star.circle", .move),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            counts
            mostNightsWith
            lastNight
            nightsList
            cityCard
            stampGrid
            knows
            quoteCard
            serverSettings
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Passport").display(34)
                Spacer()
                Text(Date.now.formatted(.dateTime.year()))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.soft)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Palette.card, in: .capsule)
                    .overlay(Capsule().stroke(Palette.line))
            }
            Text("Who you were with, and where.")
                .font(.quiet(21))
                .foregroundStyle(Palette.soft)
        }
        .padding(.top, 8)
    }

    private var counts: some View {
        let out = nights.filter { !$0.stops.isEmpty }
        let showUps = gatherings.filter { $0.checkedInAt != nil }.count
        let met = Set(out.flatMap { $0.stops.flatMap(\.withNames) }).count
        let city = Spots.stamped(stamps).count
        return HStack(spacing: 8) {
            count(Text("\(max(out.count, showUps > 0 ? 1 : 0))"), "nights out")
            count(Text("\(met)"), met == 1 ? "person" : "people")
            NavigationLink(value: CityListRoute()) {
                count(Text("\(city)\(Text("/\(Spots.all.count)").font(.system(size: 18, weight: .bold)).foregroundStyle(Palette.muted))"), "Know your city")
            }
            .buttonStyle(.plain)
        }
    }

    private func count(_ v: Text, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            v.font(.system(size: 32, weight: .bold)).monospacedDigit().foregroundStyle(Palette.ink)
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 18)
    }

    /// Who you've been out with most: one count per night.
    @ViewBuilder
    private var mostNightsWith: some View {
        let ranked = PassportPeople.mostNightsWith(nights.map(\.stops), people: people.map(\.snapshot))
        if !ranked.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Most nights with").eyebrow()
                    Spacer()
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(ranked, id: \.friend.id) { r in
                            VStack(spacing: 6) {
                                FriendAvatar(friend: r.friend, size: 52)
                                Text(r.friend.firstName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                Text("\(r.nights)").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(Palette.accentSoft)
                            }
                            .frame(width: 58)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// Every night out, newest first: the date as a stamp, where, and who with.
    @ViewBuilder
    private var nightsList: some View {
        let out = nights.filter { !$0.stops.isEmpty }
        if !out.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Nights").eyebrow()
                ForEach(Array(out.prefix(12).enumerated()), id: \.element.id) { i, n in
                    let with = PassportPeople.with(n.stops, people: people.map(\.snapshot))
                    Button { model.recap = n } label: {
                        HStack(alignment: .top, spacing: 14) {
                            DateSeal(date: n.evening, color: n.stops.first?.genre.color ?? Palette.accent, tilt: [-8.0, 6, -4, 9][i % 4])
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PassportPeople.title(n.stops, evening: n.evening, with: with)).font(.system(size: 16, weight: .bold)).lineLimit(1)
                                Text(n.stops.map(\.title).joined(separator: " \u{00B7} ")).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1)
                                if !with.isEmpty {
                                    AvatarStack(friends: with, size: 22, ground: Palette.bg)
                                        .padding(.top, 6)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Palette.ink)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < min(out.count, 12) - 1 { Divider().overlay(Palette.line) }
                }
            }
        }
    }

    /// The latest night out, as a way back to its morning after.
    @ViewBuilder
    private var lastNight: some View {
        if let n = nights.first(where: { !$0.stops.isEmpty }) {
            Button { model.recap = n } label: {
                HStack(spacing: 14) {
                    Image(systemName: "sun.horizon.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.porch)
                        .frame(width: 44, height: 44)
                        .background(Palette.porch.opacity(0.12), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(n.evening.formatted(.dateTime.weekday(.wide))), lived").font(.system(size: 16, weight: .bold))
                        Text("\(n.stops.map(\.title).joined(separator: " \u{00B7} ")) \u{00B7} \(NightMath.miles(n.walkedMeters)) mi")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
                }
                .foregroundStyle(Palette.ink)
                .padding(14)
                .card(radius: 22)
            }
            .buttonStyle(.plain)
        }
    }

    private var cityCard: some View {
        let done = Spots.stamped(stamps)
        let total = Spots.all.count
        let close = Spots.all.filter { done[$0.id] == nil && location.center.distance(to: $0.coordinate) < 1609 }.count
        return NavigationLink(value: CityListRoute()) {
            HStack(spacing: 14) {
                ProgressRing(done: done.count, total: total, size: 56, line: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Spots.listTitle).font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.ink)
                    Text(done.isEmpty
                         ? "\(total) places every San Franciscan should go once. \(close) are under a mile from you."
                         : "\(done.count) done. \(close) of the rest are under a mile from you.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .padding(16)
            .card(radius: 22)
        }
        .buttonStyle(.plain)
    }

    private var quoteCard: some View {
        Button { model.showQuote = true } label: {
            HStack(spacing: 12) {
                Text("\u{201C}")
                    .font(.quiet(40))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read the quote again").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("\u{2018}Live more.\u{2019} Fyodor Dostoevsky, Demons")
                        .font(.quiet(15))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .card()
        }
        .buttonStyle(.plain)
    }

    private var stampGrid: some View {
        let earnedKeys = Set(stamps.map(\.key))
        let locked = goals.filter { !earnedKeys.contains($0.key) }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Stamps").eyebrow()
            if stamps.isEmpty {
                Text("Show up to something on the map and check in when you're there. Stamps only count in person.")
                    .font(.system(size: 14)).foregroundStyle(Palette.muted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 14) {
                ForEach(stamps) { s in
                    stampCell(StampBadge(symbol: s.symbol, color: s.category.color), s.title, dim: false)
                }
                ForEach(locked, id: \.key) { g in
                    stampCell(StampBadge(symbol: g.symbol, color: g.category.color, locked: true), g.title, dim: true)
                }
            }
        }
    }

    private func stampCell(_ badge: StampBadge, _ title: String, dim: Bool) -> some View {
        VStack(spacing: 5) {
            badge
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(dim ? Palette.muted : Palette.ink)
        }
    }

    private var knows: some View {
        let visible = notes.filter { !$0.isHidden }
        return VStack(alignment: .leading, spacing: 10) {
            Text("What you're into").eyebrow()
            if visible.isEmpty {
                Text("Nothing yet. This fills in from what you join, show up to and order, and it shapes what the map shows first.")
                    .font(.system(size: 14)).foregroundStyle(Palette.muted)
            }
            FlowLayout(spacing: 7) {
                ForEach(visible) { n in
                    HStack(spacing: 6) {
                        if let c = n.category { Image(systemName: c.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(c.color) }
                        Text(n.text).font(.system(size: 13, weight: .semibold))
                        Button {
                            n.isHidden = true
                            Ledger.save(context, "forget note")
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.muted)
                                .frame(width: 18, height: 18).background(Palette.raise, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Forget \(n.text)")
                    }
                    .padding(.leading, 11).padding(.trailing, 5).padding(.vertical, 5)
                    .card(radius: 999)
                }
            }
            HStack {
                TextField("Add one, like \"pickup basketball\"", text: $newNote)
                    .font(.system(size: 14))
                    .onSubmit(addNote)
                Button("Add", action: addNote).disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            .card(radius: 14)
        }
    }

    private var serverSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Server").eyebrow()
            TextField("Your name, as neighbors see it", text: $displayName)
                .font(.system(size: 15))
                .textContentType(.givenName)
                .submitLabel(.done)
                .onSubmit {
                    let name = displayName
                    Task { await sync.run { () throws(APIError) in try await Sync.saveName(name) } }
                }
            TextField("Server address, like https://….ngrok.app", text: $serverURL)
                .font(.system(size: 14, design: .monospaced))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text(serverLine)
                .font(.system(size: 12))
                .foregroundStyle(sync.problem == nil ? Palette.muted : Genre.food.color)
            if APIConfig.isConfigured {
                Button(sync.syncing ? "Syncing…" : "Sync now") {
                    let center = location.center
                    Task { await sync.run { () throws(APIError) in try await Sync.refresh(around: center, context: context) } }
                }
                .font(.system(size: 14, weight: .semibold))
                .disabled(sync.syncing)
            }
        }
        .padding(14)
        .card()
    }

    private var serverLine: String {
        if !APIConfig.isConfigured { return "No server: everything stays on this phone, and only you see what you post." }
        if let problem = sync.problem { return problem }
        if let at = sync.lastSynced { return "Synced \(at.formatted(date: .omitted, time: .shortened)). What you post reaches people nearby." }
        return "Not synced yet."
    }

    private func addNote() {
        let text = newNote.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let q = SearchQuery.parse(text)
        context.insert(TasteNote(key: "said:\(text.lowercased())", text: text, category: q.categories.first))
        Ledger.save(context, "add note")
        newNote = ""
    }
}
