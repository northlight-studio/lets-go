import SwiftUI
import SwiftData
import MapKit

/// What Wren checked, one line at a time: a spinner, then a tick.
struct ThinkingList: View {
    var checks: [Plan.Check]
    /// How far along: line i shows once step > i, and is done once step > i + 1.
    var step: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(checks.enumerated()), id: \.offset) { i, check in
                if step > i {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Palette.raise)
                            if step > i + 1 {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Palette.live)
                                    .transition(.scale.combined(with: .opacity))
                            } else {
                                ProgressView().controlSize(.small).tint(Palette.accentSoft)
                            }
                        }
                        .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.title).font(.system(size: 15, weight: .semibold))
                            Text(check.detail).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Palette.muted)
                        }
                    }
                    .frame(minHeight: 42)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}

/// The plan in Wren's thread: the window, who's in it, the stops in three columns, and
/// the two ways forward.
struct PlanCard: View {
    var plan: Plan
    var friends: [Friend]
    var onAsk: () -> Void
    var onAnother: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(window)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.accentSoft)
                Spacer()
                AvatarStack(friends: friends, size: 24, includesYou: true, ground: Palette.raise)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(plan.stops) { stop in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NightPin.hour(stop.start)).font(.system(size: 15, weight: .heavy)).monospacedDigit()
                        Capsule().fill(stop.genre.color).frame(height: 3)
                        Text(stop.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(stop.isSample ? "Sample" : stop.note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 14)
            HStack(spacing: 8) {
                Button(askTitle, action: onAsk)
                    .buttonStyle(PrimaryButtonStyle())
                Button("Another", action: onAnother)
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 16)
        }
        .padding(16)
        .background(Palette.card, in: .rect(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Palette.line))
    }

    private var askTitle: String { friends.isEmpty ? "Hold it" : "Ask \(Crowd.names(friends))" }

    /// "Sat, Oct 31 · 4:30–10 PM"
    private var window: String {
        guard let first = plan.stops.first, let last = plan.stops.last else { return plan.dayLine }
        let day = plan.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let end = last.start.addingTimeInterval(3 * 3600)
        return "\(day) \u{00B7} \(NightPin.hour(first.start))\u{2013}\(HomeLine.clock(end))"
    }
}

/// "Saturday, sorted." The plan on a map with its walks drawn, then the timeline:
/// what's held, who's in, when to leave for each stop, and Wren's note.
struct PlanView: View {
    @Bindable var plan: SavedPlan
    @Environment(LocationService.self) private var location
    @Environment(HomeModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Person.name) private var people: [Person]
    @Query private var gatherings: [Gathering]
    @Query private var kitchens: [Kitchen]
    @Query private var orders: [Order]

    @State private var routes = RouteBook()
    @State private var lines: [Int: [CLLocationCoordinate2D]] = [:]
    @State private var holding: Kitchen?
    @State private var walk: WalkTarget?
    @State private var bag: [UUID: Int] = [:]
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let now = timeline.date
            VStack(spacing: 0) {
                stopsMap
                    .frame(height: 300)
                    .overlay(alignment: .top) { walkingPill.padding(.top, 8) }
                sheet(now: now)
                    .padding(.top, -34)
            }
            .background(Palette.bg)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await loadRoutes() }
        .sheet(item: $holding) { k in
            if let drop = dropFor(k) {
                OrderView(kitchen: k, drop: drop, bag: $bag, preferredSlot: plan.stops.first(where: { $0.kitchenID == k.id })?.start)
            }
        }
        .fullScreenCover(item: $walk) { EyesUpView(target: $0) }
        .errorAlert($problem)
    }

    // MARK: Map

    private var stopsMap: some View {
        Map(initialPosition: .automatic) {
            ForEach(Array(plan.legs.indices), id: \.self) { i in
                if let coords = lines[i] {
                    MapPolyline(coordinates: coords).stroke(Palette.walk, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(Array(plan.stops.enumerated()), id: \.element.id) { i, stop in
                Annotation(stop.title, coordinate: stop.coordinate, anchor: .center) {
                    Text("\(i + 1)")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(stop.genre.ink)
                        .frame(width: 30, height: 30)
                        .background(stop.genre.color, in: .circle)
                        .overlay(Circle().stroke(Palette.card, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                }
                .annotationTitles(.hidden)
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .including([.park, .beach, .publicTransport])))
        .overlay(alignment: .top) {
            LinearGradient(colors: [Palette.bg.opacity(0.92), Palette.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
                .allowsHitTesting(false)
        }
    }

    private var walkingPill: some View {
        let miles = plan.meters / 1609.34
        return Label("\(miles.formatted(.number.precision(.fractionLength(1)))) mi of walking, total", systemImage: "figure.walk")
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 14)
            .frame(height: 32)
            .glassEffect(.regular, in: .capsule)
    }

    // MARK: Sheet

    private func sheet(now: Date) -> some View {
        let group = people.filter { plan.friendIDs.contains($0.id) }.map(\.snapshot)
        let inNow = whoIsIn(group, now: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(plan.dayLine).eyebrow(Palette.accentSoft)
                    Spacer()
                    if !group.isEmpty { status(group, in: inNow) }
                }
                Text(plan.title).display(34).padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(Array(plan.stops.enumerated()), id: \.element.id) { i, stop in
                        stopRow(stop, last: i == plan.stops.count - 1)
                        if i < plan.legs.count { legRow(plan.legs[i]) }
                    }
                }
                .padding(.top, 18)
                if !plan.note.isEmpty {
                    WrenNote(text: plan.note).padding(.top, 14)
                }
                HStack(spacing: 10) {
                    Button(plan.confirmed ? "Sorted" : "Looks good") { confirm() }
                        .buttonStyle(PrimaryButtonStyle(color: plan.confirmed ? Palette.accent.opacity(0.18) : Palette.accent,
                                                        ink: plan.confirmed ? Palette.accentSoft : Palette.accentInk))
                        .disabled(plan.confirmed || busy)
                    Button("Change") { change() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 18)
                .sensoryFeedback(.success, trigger: plan.confirmed)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Palette.surface, in: UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34))
    }

    private func status(_ group: [Friend], in ids: Set<UUID>) -> some View {
        let all = group.allSatisfy { ids.contains($0.id) }
        let label: String
        if all { label = "Everyone's in" } else if plan.askedAt == nil { label = "Not asked yet" } else { label = "\(ids.count) of \(group.count) in" }
        return HStack(spacing: 6) {
            AvatarStack(friends: group, size: 18, ground: Palette.card)
            Text(label)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(all ? Palette.live : Palette.soft)
            if group.contains(where: \.isSample) { SampleTag() }
        }
        .padding(.leading, 4).padding(.trailing, 10)
        .frame(height: 26)
        .background(all ? Palette.live.opacity(0.14) : Palette.raise, in: .capsule)
        .overlay(Capsule().stroke(all ? Palette.live.opacity(0.35) : Palette.line))
        .animation(.snappy, value: all)
    }

    private func stopRow(_ stop: Plan.Stop, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(NightPin.hour(stop.start))
                .font(.system(size: 15, weight: .heavy))
                .monospacedDigit()
                .frame(width: 48, alignment: .leading)
                .padding(.top, 1)
            VStack(spacing: 4) {
                Circle().fill(stop.genre.color).frame(width: 12, height: 12).padding(.top, 4)
                if !last { Rectangle().fill(Palette.raise).frame(width: 2) }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(stop.title).font(.system(size: 16, weight: .bold))
                    if held(stop) {
                        Text("HELD")
                            .font(.system(size: 10.5, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(Palette.live)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Palette.live.opacity(0.14), in: .rect(cornerRadius: 6))
                    }
                    if stop.isSample { SampleTag() }
                }
                Text(stop.note).font(.system(size: 13.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if Calendar.current.isDateInToday(stop.start), stop.start.addingTimeInterval(3600) > .now {
                    Button("Walk there, eyes up") {
                        let group = people.filter { plan.friendIDs.contains($0.id) }.map(\.snapshot)
                        walk = WalkTarget(title: stop.title, genre: stop.genre, latitude: stop.latitude,
                                          longitude: stop.longitude, start: stop.start, friends: group)
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.walk)
                    .padding(.top, 4)
                }
                if !held(stop), let action = holdAction(stop) {
                    Button(action.title, action: action.run)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.accentSoft)
                        .padding(.top, 4)
                        .disabled(busy)
                }
            }
            .padding(.bottom, 12)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func legRow(_ leg: Plan.Leg) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 48, height: 1)
            Rectangle().fill(Palette.raise).frame(width: 2).frame(width: 22)
            Text(leg.note).font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.muted)
                .padding(.bottom, 10)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: State

    /// Real friends are in when the server lists them on the event; sample ones say yes a
    /// moment after you ask (they're samples).
    private func whoIsIn(_ group: [Friend], now: Date) -> Set<UUID> {
        let event = plan.event.flatMap { e in gatherings.first { $0.id == e.gatheringID } }
        var ids = Set<UUID>()
        for f in group {
            if f.isSample {
                if let asked = plan.askedAt, now.timeIntervalSince(asked) > 4 { ids.insert(f.id) }
            } else if event?.friendIDs.contains(f.id) == true {
                ids.insert(f.id)
            }
        }
        return ids
    }

    private func held(_ stop: Plan.Stop) -> Bool {
        switch stop.kind {
        case .event:
            return gatherings.first { $0.id == stop.gatheringID }?.isJoined == true
        case .food:
            return orders.contains { $0.kitchen?.id == stop.kitchenID && Calendar.current.isDate($0.pickupAt, inSameDayAs: stop.start) }
        case .outside:
            return false
        }
    }

    private func holdAction(_ stop: Plan.Stop) -> (title: String, run: () -> Void)? {
        switch stop.kind {
        case .event:
            guard let g = gatherings.first(where: { $0.id == stop.gatheringID }) else { return nil }
            return ("Hold a spot", { join(g) })
        case .food:
            guard let k = kitchens.first(where: { $0.id == stop.kitchenID }), dropFor(k) != nil else { return nil }
            return ("Hold the \(NightPin.hour(stop.start)) slot", { startHolding(k) })
        case .outside:
            return nil
        }
    }

    private func dropFor(_ k: Kitchen) -> Drop? {
        guard let at = plan.stops.first(where: { $0.kitchenID == k.id })?.start else { return nil }
        return k.drops.first { $0.start <= at && at < $0.end }
    }

    // MARK: Actions

    private func startHolding(_ k: Kitchen) {
        // One of the first thing on the menu for each of you; change it on the next screen.
        if let first = k.sortedMenu.first { bag = [first.id: plan.friendIDs.count + 1] }
        holding = k
    }

    private func join(_ g: Gathering) {
        busy = true
        Task {
            await attempt($problem) { () throws(APIError) in try await Sync.join(g, context: context) }
            busy = false
        }
    }

    private func confirm() {
        plan.confirmed = true
        if plan.askedAt == nil { plan.askedAt = .now }
        Ledger.save(context, "confirm plan")
        if let e = plan.event, let g = gatherings.first(where: { $0.id == e.gatheringID }), !g.isJoined { join(g) }
    }

    private func change() {
        model.wrenDraft = plan.request
        model.tab = .wren
        dismiss()
    }

    private func loadRoutes() async {
        for i in plan.legs.indices where i + 1 < plan.stops.count {
            let a = plan.stops[i].coordinate, b = plan.stops[i + 1].coordinate
            if let leg = await routes.walk(from: a, to: b) {
                lines[i] = leg.coordinates
            } else {
                lines[i] = [a, b]
            }
        }
    }
}
