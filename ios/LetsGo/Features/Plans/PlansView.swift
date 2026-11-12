import SwiftUI
import SwiftData
import CoreLocation

/// The Plans tab: what you've said yes to, then what's worth leaving the house for.
/// The best pick, what starts in the next hour, what's a short walk away, the week's
/// real listings day by day, home kitchens with a drop coming, and the city list.
struct PlansView: View {
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @Query(sort: \Gathering.start) private var gatherings: [Gathering]
    @Query private var kitchens: [Kitchen]
    @Query private var notes: [TasteNote]
    @Query private var stamps: [Stamp]
    @Query(sort: \Order.pickupAt) private var orders: [Order]
    @Query(sort: \SavedPlan.day) private var plans: [SavedPlan]
    @Query private var people: [Person]

    @State private var path = NavigationPath()
    @State private var day: Date?
    @State private var showWholeDay = false
    @State private var hosting = false
    @State private var selling = false
    /// New batches from kitchens you follow (push isn't set up yet, so they show here).
    @State private var kitchenNotes: [NoteDTO] = []

    var body: some View {
        NavigationStack(path: $path) {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let now = timeline.date
                let all = Nearby.candidates(gatherings: gatherings, kitchens: kitchens, from: location.center, now: now)
                let taste = Nearby.taste(notes: notes, gatherings: gatherings, kitchens: kitchens)
                let soon = Today.startingSoon(all, now: now, taste: taste)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(all, soon: soon, now: now)
                        planned(now: now)
                        yours(now: now)
                        followed(now: now)
                        pick(all, taste: taste, now: now)
                        soonStrip(soon, now: now)
                        walkable(all, excluding: Set(soon.map(\.id)), now: now)
                        week(now: now)
                        places
                        kitchenStrip(now: now)
                        listCard
                    }
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
                .background(Palette.bg)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Gathering.self) { GatheringDetailView(gathering: $0) }
            .navigationDestination(for: Kitchen.self) { KitchenView(kitchen: $0) }
            .navigationDestination(for: Spot.self) { SpotView(spot: $0) }
            .navigationDestination(for: Order.self) { OrderStatusView(order: $0) }
            .navigationDestination(for: MyKitchenRoute.self) { _ in MyKitchenView() }
            .navigationDestination(for: CityListRoute.self) { _ in ListsView() }
            .navigationDestination(for: KitchensRoute.self) { _ in KitchensPage() }
            .navigationDestination(for: SavedPlan.self) { PlanView(plan: $0) }
        }
        .sheet(isPresented: $hosting) { NewGatheringView(draft: nil) }
        .sheet(isPresented: $selling) { SellView() }
        .task { if ServerFeatures.shared.has(.selling), let n = try? await Sync.notes() { kitchenNotes = n } }
    }

    // MARK: Kitchens you follow

    /// "Dana's kitchen posted Mango sticky rice ice cream": unread notes, newest first.
    @ViewBuilder
    private func followed(now: Date) -> some View {
        let unread = kitchenNotes.filter { !$0.read }.prefix(4)
        if !unread.isEmpty {
            sectionHeader("New from kitchens you follow", action: "Clear") { clearNotes() }
            VStack(spacing: 0) {
                ForEach(Array(unread.enumerated()), id: \.element.id) { i, n in
                    Button { open(n) } label: {
                        HStack(spacing: 12) {
                            BatchPhoto(path: n.photoUrl, title: n.title, height: 44, radius: 12).frame(width: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.title.isEmpty ? "A new batch" : n.title)
                                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                                Text(n.kitchenName).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            if let at = n.startsAt {
                                Text(When.short(at, now: now)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(Palette.ink)
                            }
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    if i < unread.count - 1 { Divider().overlay(Palette.line).padding(.leading, 70) }
                }
            }
            .card(radius: 20)
            .padding(.horizontal, 16)
        }
    }

    private func open(_ n: NoteDTO) {
        if let k = kitchens.first(where: { $0.remoteID == n.kitchenId }) { path.append(k) }
    }

    private func clearNotes() {
        withAnimation { kitchenNotes = kitchenNotes.map { var n = $0; n.read = true; return n } }
        Task { try? await Sync.markNotesRead() }
    }

    // MARK: Plans Wren made

    @ViewBuilder
    private func planned(now: Date) -> some View {
        // Over two hours after its last stop starts, a plan is history, not something to go to.
        let upcoming = plans.filter { ($0.stops.last?.start ?? $0.day.addingTimeInterval(86_400)).addingTimeInterval(2 * 3600) > now }
        if !upcoming.isEmpty {
            sectionHeader("Your plans", detail: "Wren does the logistics. You show up.")
            VStack(spacing: 10) {
                ForEach(upcoming) { p in
                    let group = people.filter { p.friendIDs.contains($0.id) }.map(\.snapshot)
                    Button { path.append(p) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.dayLine).eyebrow(Palette.accentSoft)
                                Text(p.title).font(.system(size: 24, weight: .bold))
                                Text(p.stops.map(\.title).joined(separator: " \u{2192} "))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            AvatarStack(friends: group, size: 26, includesYou: true, ground: Palette.card)
                        }
                        .foregroundStyle(Palette.ink)
                        .padding(16)
                        .card(radius: 22)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            context.delete(p)
                            Ledger.save(context, "delete plan")
                        } label: { Label("Delete plan", systemImage: "trash") }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Yours

    /// What you've said yes to that hasn't happened yet: gatherings and pickups.
    @ViewBuilder
    private func yours(now: Date) -> some View {
        let joined = gatherings.filter { $0.isJoined && $0.isShown(at: now) }.prefix(6)
        let pickups = orders.filter { $0.status == .reserved && $0.payment.isLive && $0.pickupAt.addingTimeInterval(3600) > now }.prefix(4)
        if !joined.isEmpty || !pickups.isEmpty {
            sectionHeader("You're in", detail: "Show up, check in, collect the stamp.")
            VStack(spacing: 0) {
                ForEach(Array(joined.enumerated()), id: \.element.id) { i, g in
                    PickRow(pick: Candidate(g, from: location.center), now: now) { path.append(g) }
                        .padding(.horizontal, 14)
                    if i < joined.count - 1 || !pickups.isEmpty { Divider().overlay(Palette.line).padding(.leading, 66) }
                }
                ForEach(Array(pickups.enumerated()), id: \.element.id) { i, o in
                    Button { path.append(o) } label: {
                        HStack(spacing: 12) {
                            CategoryDot(category: .food, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.title.isEmpty ? (o.kitchen?.name ?? "Pickup") : o.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                                Text(o.title.isEmpty
                                     ? "\(o.itemCount) item\(o.itemCount == 1 ? "" : "s")\(o.eatOnPorch ? " · porch seat" : "")"
                                     : "\(o.kitchen?.name ?? "") · \(BatchCopy.count(o.itemCount, o.unit))\(o.payment == .unpaid ? " · not paid yet" : "")")
                                    .font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(When.short(o.pickupAt, now: now))
                                .font(.system(size: 14, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Palette.ink)
                        }
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    if i < pickups.count - 1 { Divider().overlay(Palette.line).padding(.leading, 66) }
                }
            }
            .padding(.vertical, 2)
            .card(radius: 20)
            .padding(.horizontal, 16)
        } else {
            sectionHeader("You're in", detail: "Nothing on your list yet.")
            VStack(alignment: .leading, spacing: 12) {
                Text("Say you're in to something below, or host something of your own and people nearby will see it.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { hosting = true } label: { Label("Host something", systemImage: "plus") }
                    Button { selling = true } label: { Label("Sell something", systemImage: "camera") }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: 20)
            .padding(.horizontal, 16)
        }
    }

    // MARK: Header

    private func header(_ all: [Candidate], soon: [Candidate], now: Date) -> some View {
        let near = Today.walkable(all, now: now, limit: 99).count
        let starting = soon.filter { $0.start > now }.count
        return VStack(alignment: .leading, spacing: 6) {
            Text("Plans").display(34).foregroundStyle(Palette.ink)
            Text(eyebrow(now: now)).eyebrow()
            Text(Today.headline(now: now))
                .font(.quiet(21))
                .foregroundStyle(Palette.soft)
                .padding(.top, 2)
            countLine(near: near, starting: starting)
                .font(.system(size: 15))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func eyebrow(now: Date) -> String {
        var parts = [now.formatted(.dateTime.weekday(.wide)), CityListings.covers(location.center) ? "San Francisco" : "Near you"]
        if let set = Sun.sunset(on: now, at: location.center), set > now {
            parts.append("sunset \(set.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func countLine(near: Int, starting: Int) -> Text {
        guard near > 0 else { return Text("Nothing within a 15-minute walk right now. The whole week is below.") }
        let things = Text(near == 1 ? "1 thing" : "\(near) things").foregroundStyle(Palette.live).fontWeight(.semibold)
        let tail = switch starting {
        case 0: ""
        case 1: " 1 starts in the next hour."
        default: " \(starting) start in the next hour."
        }
        return Text("\(things) within a 15-minute walk.\(tail)")
    }

    // MARK: The pick

    @ViewBuilder
    private func pick(_ all: [Candidate], taste: Taste, now: Date) -> some View {
        if let top = Picks.picks(all, now: now, taste: taste, limit: 1).first ?? Today.next(all, now: now) {
            PickCard(pick: top, now: now, why: why(top, taste: taste, now: now)) { open(top) }
                .padding(.horizontal, 16)
                .padding(.top, 20)
        }
    }

    private func why(_ c: Candidate, taste: Taste, now: Date) -> String {
        var parts: [String] = []
        if taste.weight(c.category) >= 0.5 { parts.append("You keep showing up to \(c.category.noun).") }
        if let spots = c.spotsLeft, spots <= 3 { parts.append(spots == 1 ? "One spot left." : "\(spots) spots left.") }
        if let left = c.dropLeft, left <= 10 { parts.append("\(left) left in this batch.") }
        if c.walkMinutes <= 10 { parts.append("It's a \(c.walkMinutes)-minute walk.") }
        if parts.isEmpty {
            let reason = Picks.reason(c, now: now)
            parts.append(reason.prefix(1).uppercased() + String(reason.dropFirst()) + ".")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Soon and close

    @ViewBuilder
    private func soonStrip(_ soon: [Candidate], now: Date) -> some View {
        if !soon.isEmpty {
            sectionHeader("In the next hour")
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(soon) { c in
                        SoonCard(pick: c, now: now) { open(c) }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func walkable(_ all: [Candidate], excluding: Set<UUID>, now: Date) -> some View {
        let items = Today.walkable(all, now: now, excluding: excluding)
        if !items.isEmpty {
            sectionHeader("Within a 15-minute walk", detail: "Show up, say hi.")
            rows(items, now: now)
        }
    }

    // MARK: This week

    private func week(now: Date) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        // A day picked earlier that has since passed falls back to today.
        let selected = day.flatMap { $0 >= today ? $0 : nil } ?? today
        let real = gatherings.filter { $0.isShown(at: now) }.map { Candidate($0, from: location.center) }
        let items = Today.happening(real, on: selected, now: now)
        let shown = showWholeDay ? items : Array(items.prefix(8))
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("This week", detail: CityListings.covers(location.center) ? "What's really on around San Francisco." : "What people nearby have posted.")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Today.week(of: now), id: \.self) { d in
                        dayChip(d, selected: cal.isDate(d, inSameDayAs: selected), past: d < today,
                                count: Today.happening(real, on: d, now: now).count)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 10)
            if items.isEmpty {
                Text(cal.isDate(selected, inSameDayAs: now) ? "Nothing else listed today." : "Nothing listed that day yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 20)
            } else {
                rows(shown, now: now)
                if items.count > shown.count {
                    Button("Show all \(items.count)") { showWholeDay = true }
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                }
            }
        }
    }

    private func dayChip(_ d: Date, selected: Bool, past: Bool, count: Int) -> some View {
        Button {
            day = d
            showWholeDay = false
        } label: {
            VStack(spacing: 2) {
                Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 11, weight: .semibold))
                Text(d.formatted(.dateTime.day())).font(.system(size: 17, weight: .bold)).monospacedDigit()
                Text(past ? " " : "\(count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(selected ? Palette.bg.opacity(0.7) : Palette.muted)
            }
            .frame(width: 48, height: 64)
            .foregroundStyle(selected ? Palette.bg : Palette.ink)
            .background(selected ? Palette.ink : Color.clear, in: .rect(cornerRadius: 16))
            .card(radius: 16)
        }
        .buttonStyle(.plain)
        .disabled(past)
        .opacity(past ? 0.4 : 1)
        .accessibilityLabel("\(d.formatted(.dateTime.weekday(.wide).month().day())), \(count) things")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Places

    @ViewBuilder
    private var places: some View {
        let done = Spots.stamped(stamps)
        let next = Spots.closest(Spots.all.filter { done[$0.id] == nil }, to: location.center).prefix(4)
        if !next.isEmpty {
            sectionHeader("Places to go", detail: "From the city list. Check in when you're there.", action: "See all") { path.append(CityListRoute()) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(next)) { s in
                    NavigationLink(value: s) { SpotCard(spot: s, meters: location.center.distance(to: s.coordinate)) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Kitchens

    @ViewBuilder
    private func kitchenStrip(now: Date) -> some View {
        let open = kitchens
            .filter { !$0.isMine && $0.nextDrop(after: now) != nil }
            .sorted { ($0.nextDrop(after: now)?.start ?? .distantFuture) < ($1.nextDrop(after: now)?.start ?? .distantFuture) }
            .prefix(6)
        if !open.isEmpty {
            sectionHeader("Home kitchens near you", action: "All kitchens") { path.append(KitchensRoute()) }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(open)) { k in
                        NavigationLink(value: k) { KitchenCard(kitchen: k, now: now, meters: location.center.distance(to: k.coordinate)) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        } else {
            if orders.contains(where: { $0.status == .pickedUp }) {
                // A pickup still waiting for its review lives in All kitchens → Your orders.
                sectionHeader("Home kitchens near you", detail: "No drops coming up nearby. Your orders are in here.",
                              action: "All kitchens") { path.append(KitchensRoute()) }
            } else {
                sectionHeader("Home kitchens near you", detail: "No kitchens nearby yet. When a neighbor posts a batch, it shows up here.",
                              action: "Open yours") { path.append(MyKitchenRoute()) }
            }
        }
        sellCard
    }

    /// Make something good? Put a batch on the map.
    private var sellCard: some View {
        Button { selling = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "camera")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
                    .background(Palette.raise, in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sell something").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.ink)
                    Text("Make something good? Snap it, set a price and a pickup time, and neighbors a short walk away can reserve it.")
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
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: The city list

    private var listCard: some View {
        let done = Spots.stamped(stamps)
        let total = Spots.all.count
        let close = Spots.all.filter { done[$0.id] == nil && location.center.distance(to: $0.coordinate) < 1609 }.count
        return Button { path.append(CityListRoute()) } label: {
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
        .padding(.horizontal, 16)
        .padding(.top, 28)
    }

    // MARK: Pieces

    private func sectionHeader(_ title: String, detail: String? = nil, action: String? = nil, run: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.ink)
                Spacer()
                if let action {
                    Button(action, action: run).font(.system(size: 15, weight: .semibold))
                }
            }
            if let detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }

    private func rows(_ items: [Candidate], now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                PickRow(pick: c, now: now) { open(c) }
                    .padding(.horizontal, 14)
                if i < items.count - 1 { Divider().overlay(Palette.line).padding(.leading, 66) }
            }
        }
        .padding(.vertical, 2)
        .card(radius: 20)
        .padding(.horizontal, 16)
    }

    private func open(_ c: Candidate) {
        switch c.kind {
        case .gathering:
            if let g = gatherings.first(where: { $0.id == c.id }) { path.append(g) }
        case .drop:
            if let k = kitchens.first(where: { $0.id == c.id }) { path.append(k) }
        }
    }
}

/// The big card at the top of Today: the one thing most worth going to.
struct PickCard: View {
    var pick: Candidate
    var now: Date
    var why: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                GenreArt(genre: pick.category, seed: pick.title)
                    .frame(height: 170)
                    .overlay(alignment: .topLeading) {
                        Label("Worth going", systemImage: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .glassEffect(.regular, in: .capsule)
                            .padding(12)
                    }
                VStack(alignment: .leading, spacing: 6) {
                    Text(pick.start <= now ? "On now · till \(pick.end.formatted(date: .omitted, time: .shortened))" : When.short(pick.start, now: now))
                        .eyebrow(pick.start <= now ? Palette.live : Palette.muted)
                    Text(pick.title)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                    Text(why)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        tag(pick.category.label, color: pick.category.color)
                        if pick.isFree { tag("Free") }
                        if !pick.place.isEmpty { tag(pick.place) }
                    }
                    .padding(.top, 4)
                    HStack {
                        Text("Let's go")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Palette.onProminent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .glassEffect(.regular.tint(Palette.prominent), in: .capsule)
                        Text(Walk.label(pick.meters))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 16)
                            .frame(height: 46)
                            .overlay(Capsule().stroke(Palette.line))
                    }
                    .padding(.top, 10)
                }
                .padding(16)
            }
            .card(radius: 24)
            .clipShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    private func tag(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(color ?? Palette.ink)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background((color ?? Palette.muted).opacity(0.16), in: .capsule)
    }
}

/// A card in the "In the next hour" strip.
struct SoonCard: View {
    var pick: Candidate
    var now: Date
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    CategoryDot(category: pick.category, size: 34)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(pick.start <= now ? Palette.live : Palette.star).frame(width: 7, height: 7)
                        Text(pick.start <= now ? "On now" : pick.start.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(pick.start <= now ? Palette.live : Palette.ink)
                    }
                }
                Text(pick.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 12)
                Text(pick.place.isEmpty ? pick.category.label : pick.place)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .padding(.top, 3)
                Divider().overlay(Palette.line).padding(.vertical, 10)
                HStack {
                    Text(Walk.label(pick.meters))
                    Spacer()
                    Text(pick.going > 0 ? "\(pick.going) going" : (pick.isFree ? "Free" : pick.priceText))
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink.opacity(0.85))
            }
            .padding(14)
            .frame(width: 232)
            .card(radius: 20)
        }
        .buttonStyle(.plain)
    }
}

/// A place from the city list, as a small card with its art.
struct SpotCard: View {
    var spot: Spot
    var meters: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpotArt(spot: spot).frame(height: 96)
            VStack(alignment: .leading, spacing: 3) {
                Text(spot.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text("\(spot.kind.label) · \(Walk.label(meters))")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .card(radius: 18)
        .clipShape(.rect(cornerRadius: 18))
    }
}

/// A home kitchen with a drop coming, for the strip on Today.
struct KitchenCard: View {
    var kitchen: Kitchen
    var now: Date
    var meters: Double

    var body: some View {
        let drop = kitchen.nextDrop(after: now)
        HStack(spacing: 12) {
            PhotoHero(kitchen: kitchen, height: 72, radius: 14).frame(width: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(kitchenLine(drop)).eyebrow(Genre.food.color)
                Text(kitchen.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(drop.map { $0.isSoldOut ? "Sold out · \(Walk.label(meters))" : "\($0.left) of \($0.total) left · \(Walk.label(meters))" } ?? kitchen.cuisine)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 280)
        .card(radius: 20)
    }

    private func kitchenLine(_ drop: Drop?) -> String {
        var parts: [String] = []
        if let drop { parts.append(drop.isLive(at: now) ? "Open now" : When.short(drop.start, now: now)) }
        return parts.joined(separator: " · ")
    }
}

/// Done out of total, as a ring.
struct ProgressRing: View {
    var done: Int
    var total: Int
    var size: CGFloat = 92
    var line: CGFloat = 9

    var body: some View {
        ZStack {
            Circle().stroke(Palette.line, lineWidth: line)
            Circle()
                .trim(from: 0, to: total > 0 ? CGFloat(done) / CGFloat(total) : 0)
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(done)").font(.system(size: size * 0.28, weight: .heavy)).monospacedDigit()
                if size >= 80 {
                    Text("of \(total)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(total) done")
    }
}
