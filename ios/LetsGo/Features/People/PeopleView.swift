import SwiftUI
import SwiftData
import MapKit

/// The People tab: your friends on a small map, your porch light, who's out now
/// (with a way to join them), whose porch lights are on (wave), invites, and crews.
struct PeopleView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case friends = "Friends", crews = "Crews", met = "Met"
        var id: String { rawValue }
    }

    @Environment(LocationService.self) private var location
    @Environment(HomeModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \Person.name) private var people: [Person]
    @Query(sort: \Crew.name) private var crews: [Crew]
    @Query(sort: \Gathering.start) private var gatherings: [Gathering]
    @Query private var kitchens: [Kitchen]
    @Query private var notes: [TasteNote]
    @Query(filter: #Predicate<Intro> { !$0.dismissed }) private var intros: [Intro]
    @AppStorage(MyPorchLight.untilKey) private var porchUntil: Double = 0

    @State private var segment: Segment = .friends
    @State private var path = NavigationPath()
    @State private var position: MapCameraPosition = HomeView.followMe
    @State private var busy = false
    @State private var problem: String?
    @State private var makingCrew = false
    @State private var openIntro: Intro?

    /// Friends need routes an older server doesn't have.
    private var friendsOnServer: Bool { APIConfig.isConfigured && ServerFeatures.shared.has(.people) }
    /// Why friends can't work right now, in one plain line.
    private var friendsUnavailable: String? {
        if !APIConfig.isConfigured { return "Friends need a server. Add one at the bottom of Passport, under Server." }
        return ServerFeatures.shared.has(.people) ? nil : ServerFeatures.Feature.people.comingSoon
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let now = timeline.date
                let friends = tonight(now: now)
                VStack(spacing: 0) {
                    header
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, minHeight: 250, alignment: .top)
                        .background(alignment: .top) { peopleMap(friends, now: now) }
                    panel(friends, now: now)
                        .padding(.top, -34)
                }
                .background(Palette.bg)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Gathering.self) { GatheringDetailView(gathering: $0) }
            .navigationDestination(for: Kitchen.self) { KitchenView(kitchen: $0) }
            .navigationDestination(for: Order.self) { OrderStatusView(order: $0) }
        }
        .sheet(isPresented: $model.addingFriend) { AddFriendView() }
        .sheet(isPresented: $makingCrew) { NewCrewView(people: people) }
        .sheet(item: $openIntro) { ThirdTimeView(intro: $0).presentationBackground(Palette.bg) }
        .errorAlert($problem)
    }

    /// Your friends, with tonight as the server has it.
    private func tonight(now: Date) -> [Friend] {
        people.map(\.snapshot)
    }

    // MARK: Top

    private var header: some View {
        HStack(alignment: .center) {
            Text("People").display(34)
            Spacer()
            HStack(spacing: 0) {
                ForEach(Segment.allCases) { s in
                    Button { withAnimation(.snappy) { segment = s } } label: {
                        Text(s.rawValue)
                            .font(.system(size: 13.5, weight: segment == s ? .semibold : .medium))
                            .foregroundStyle(segment == s ? Palette.onProminent : Palette.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(segment == s ? Palette.prominent : Color.clear, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(segment == s ? .isSelected : [])
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
    }

    private func peopleMap(_ friends: [Friend], now: Date) -> some View {
        let lit = MyPorchLight.until.map { $0 > now } ?? false
        return Map(position: $position, interactionModes: [.pan, .zoom]) {
            ForEach(Crowd.mapped(friends, now: now)) { f in
                if let at = f.coordinate {
                    Annotation(f.name, coordinate: at, anchor: .center) { FriendPin(friend: f, now: now) }
                        .annotationTitles(.hidden)
                }
            }
            Annotation("You", coordinate: location.center, anchor: .center) {
                ZStack {
                    if lit {
                        Circle()
                            .fill(RadialGradient(colors: [Palette.porch.opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: 36))
                            .frame(width: 72, height: 72)
                    }
                    Circle().fill(Palette.me).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                }
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .including([.park, .beach, .publicTransport])))
        .onAppear {
            // You a little below the middle, friends around you above the panel.
            position = .camera(MapCamera(centerCoordinate: location.center.offset(east: 0, north: 150), distance: 3200))
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [Palette.bg.opacity(0.95), Palette.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .allowsHitTesting(false)
        }
        .frame(height: 330)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Panel

    private func panel(_ friends: [Friend], now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Capsule().fill(Palette.raise).frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                switch segment {
                case .friends: friendsList(friends, now: now)
                case .crews: crewsList
                case .met: metList
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Palette.surface, in: UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34)
                .stroke(Palette.line, lineWidth: 1)
                .frame(height: 40)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func friendsList(_ friends: [Friend], now: Date) -> some View {
        PorchLightCard(
            until: porchUntil > 0 ? Date(timeIntervalSince1970: porchUntil) : nil, now: now, busy: busy,
            unavailable: friendsUnavailable
        ) { on in
            toggle(on)
        }
        if let intro = intros.first(where: { !$0.saidHi }) ?? intros.first {
            ThirdTimeRow(intro: intro) { openIntro = intro }
                .padding(.top, 14)
        }
        invites(now: now)
        let out = Crowd.outNow(friends)
        if !out.isEmpty {
            sectionTitle("Out now \u{00B7} \(out.count)", color: Palette.muted)
            ForEach(out) { f in outRow(f, now: now) }
        }
        let lit = Crowd.porchLights(friends, now: now)
        if !lit.isEmpty {
            sectionTitle("Porch lights on \u{00B7} \(lit.count)", color: Palette.porchSoft)
            ForEach(lit) { f in porchRow(f, now: now) }
        }
        let shownIDs = Set(out.map(\.id) + lit.map(\.id))
        let rest = friends.filter { !shownIDs.contains($0.id) }
        if !rest.isEmpty {
            sectionTitle("Everyone else", color: Palette.muted)
            ForEach(rest) { f in
                personRow(f, detail: f.wavedAt.map { "Waved at you \(When.relative($0, now: now))" } ?? "Home tonight") { EmptyView() }
            }
        }
        if friends.isEmpty {
            Text(friendsUnavailable ?? "No friends yet. Add one with a code: trade codes with someone you go out with, and they'll see your porch light and you'll see when they're out.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .padding(.top, 20)
        }
        Button { model.addingFriend = true } label: { Label("Add a friend", systemImage: "person.badge.plus") }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.top, 20)
            .disabled(!friendsOnServer)
    }

    @ViewBuilder
    private func invites(now: Date) -> some View {
        let asked = gatherings.filter { !$0.invitedBy.isEmpty && !$0.isJoined && $0.isShown(at: now) }
        if !asked.isEmpty {
            sectionTitle("Asked along \u{00B7} \(asked.count)", color: Palette.accentSoft)
            ForEach(asked) { g in
                Button { path.append(g) } label: {
                    HStack(spacing: 12) {
                        CategoryDot(category: g.category, size: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            Text("\(g.invitedBy) asked you \u{00B7} \(When.short(g.start, now: now))")
                                .font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text("See").font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Palette.onProminent)
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(Palette.prominent, in: .capsule)
                    }
                    .foregroundStyle(Palette.ink)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func outRow(_ f: Friend, now: Date) -> some View {
        let gathering = f.out?.gatheringID.flatMap { id in gatherings.first { $0.id == id } }
        let detail: String = {
            guard let out = f.out else { return "" }
            let what = out.title.lowercasedFirst
            let at = out.place.isEmpty ? "" : " at \(out.place)"
            return out.state == .there ? "At \(what)\(at)" : "Walking to \(what)\(at)"
        }()
        return personRow(f, detail: detail, ring: .none, dot: Palette.live) {
            if let gathering {
                if gathering.isJoined {
                    Text("You're in").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accentSoft)
                } else {
                    Button("Join") { path.append(gathering) }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Palette.onProminent)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(Palette.prominent, in: .capsule)
                        .buttonStyle(.plain)
                }
            } else if let at = f.coordinate {
                Text("\(Walk.minutes(location.center.distance(to: at))) min")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.soft)
            }
        }
    }

    private func porchRow(_ f: Friend, now: Date) -> some View {
        var parts: [String] = []
        if !f.porchNote.isEmpty { parts.append(f.porchNote) }
        if let until = f.porchUntil { parts.append("till \(NightPin.hour(until))") }
        if let at = f.coordinate { parts.append("\(Walk.minutes(location.center.distance(to: at))) min away") }
        let waved = f.youWavedAt.map { now.timeIntervalSince($0) < 2 * 3600 } ?? false
        return personRow(f, detail: parts.joined(separator: " \u{00B7} "), ring: .porch) {
            Button(waved ? "Waved" : "Wave") { wave(f) }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.porchSoft)
                .padding(.horizontal, 14).frame(height: 34)
                .background(Palette.porchSoft.opacity(0.14), in: .capsule)
                .overlay(Capsule().stroke(Palette.porchSoft.opacity(0.35)))
                .buttonStyle(.plain)
                .disabled(waved || busy)
        }
    }

    private func personRow<Trailing: View>(
        _ f: Friend, detail: String, ring: FriendAvatar.Ring = .none, dot: Color? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            FriendAvatar(friend: f, size: 40, ring: ring, ground: Palette.card)
                .overlay(alignment: .bottomTrailing) {
                    if let dot {
                        Circle().fill(dot).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Palette.card, lineWidth: 2.5))
                            .offset(x: 1, y: 1)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(f.name).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .frame(height: 56)
        .contextMenu {
            if let p = people.first(where: { $0.id == f.id }) {
                Button(role: .destructive) { unfriend(p) } label: {
                    Label("Remove friend", systemImage: "person.badge.minus")
                }
            }
        }
    }

    private func sectionTitle(_ text: String, color: Color) -> some View {
        HStack {
            Text(text).eyebrow(color)
            Spacer()
        }
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    // MARK: Met

    @ViewBuilder
    private var metList: some View {
        Text("People you keep checking in alongside. After three real check-ins together, either of you can say hi; both, and you're friends.")
            .font(.system(size: 14))
            .foregroundStyle(Palette.muted)
            .padding(.top, 4)
        ForEach(intros) { intro in
            ThirdTimeRow(intro: intro) { openIntro = intro }
                .padding(.top, 12)
        }
        if intros.isEmpty, let why = friendsUnavailable {
            Text(why)
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .padding(.top, 16)
        } else if intros.isEmpty {
            Text("Nobody yet. Keep showing up.")
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 16)
        }
    }

    // MARK: Crews

    @ViewBuilder
    private var crewsList: some View {
        let byID = Dictionary(people.map { ($0.id, $0.snapshot) }, uniquingKeysWith: { a, _ in a })
        if crews.isEmpty {
            Text(people.isEmpty
                 ? "A crew is the people you keep going out with, so Wren can plan for all of you at once. Add a friend first, then make one."
                 : "A crew is the people you keep going out with. Wren can plan for a whole crew at once.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .padding(.top, 8)
        }
        ForEach(crews) { crew in
            let members = crew.memberIDs.compactMap { byID[$0] }
            HStack(spacing: 12) {
                AvatarStack(friends: members, size: 34, includesYou: true, ground: Palette.card)
                VStack(alignment: .leading, spacing: 1) {
                    Text(crew.name).font(.system(size: 16, weight: .semibold))
                    Text(Crowd.names(members) + (members.isEmpty ? "Just you" : " and you"))
                        .font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer()
            }
            .frame(minHeight: 60)
            .contextMenu {
                Button(role: .destructive) { leave(crew) } label: {
                    Label(crew.isMine ? "Delete crew" : "Leave crew", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        Button { makingCrew = true } label: { Label("New crew", systemImage: "plus") }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.top, 16)
            .disabled(people.isEmpty || !friendsOnServer)
    }

    // MARK: Actions

    private func toggle(_ on: Bool) {
        let here = location.isUsingFallback ? nil : location.center
        run { () throws(APIError) in
            let until = try await Sync.porchLight(on: on, at: here)
            porchUntil = until?.timeIntervalSince1970 ?? 0
        }
    }

    private func wave(_ f: Friend) {
        guard let p = people.first(where: { $0.id == f.id }) else { return }
        run { () throws(APIError) in try await Sync.wave(p, context: context) }
    }

    private func unfriend(_ p: Person) {
        run { () throws(APIError) in try await Sync.unfriend(p, context: context) }
    }

    private func leave(_ crew: Crew) {
        run { () throws(APIError) in try await Sync.leave(crew, context: context) }
    }

    private func run(_ work: @escaping () async throws(APIError) -> Void) {
        busy = true
        Task {
            await attempt($problem, work)
            busy = false
        }
    }
}

/// Your porch light: on for two hours, friends close by can see you're up for something.
struct PorchLightCard: View {
    var until: Date?
    var now: Date
    var busy: Bool
    /// Why it can't be turned on right now (no server, or one without friends yet).
    var unavailable: String? = nil
    var onToggle: (Bool) -> Void

    var body: some View {
        let on = (until ?? .distantPast) > now
        HStack(spacing: 14) {
            ZStack {
                if on {
                    Circle()
                        .fill(RadialGradient(colors: [Palette.porch.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 35))
                        .frame(width: 70, height: 70)
                }
                Image(systemName: on ? "lightbulb.max.fill" : "lightbulb")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(on ? Palette.accentInk : Palette.muted)
                    .frame(width: 46, height: 46)
                    .background(on ? Palette.porch : Palette.raise, in: .circle)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("Porch light").font(.system(size: 17, weight: .bold))
                Text(on
                     ? "On till \(HomeLine.clock(until ?? now)). Friends close by can see you're up for something."
                     : unavailable ?? "Tells your friends you're up for something, for the next two hours. Only friends see it.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Toggle("Porch light", isOn: Binding(get: { on }, set: { onToggle($0) }))
                .labelsHidden()
                .tint(Palette.porch)
                .disabled(busy || (unavailable != nil && !on))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(on ? Palette.porch.opacity(0.12) : Palette.card, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(on ? Palette.porch.opacity(0.3) : Palette.line))
        .animation(.easeInOut(duration: 0.25), value: on)
        .sensoryFeedback(.impact(weight: .light), trigger: on)
    }
}
