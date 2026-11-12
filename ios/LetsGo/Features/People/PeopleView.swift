import SwiftUI
import SwiftData
import MapKit

/// The People tab: what you're up for, who's up for something near you (I'm in, Join, Wave),
/// the meet-up when someone's in, things friends asked you along to, people you've met, your
/// crews with their next plan, and a way in when it's empty.
struct PeopleView: View {
    @Environment(LocationService.self) private var location
    @Environment(HomeModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \Person.name) private var people: [Person]
    @Query(sort: \Crew.name) private var crews: [Crew]
    @Query(sort: \Gathering.start) private var gatherings: [Gathering]
    @Query(filter: #Predicate<Intro> { !$0.dismissed }) private var intros: [Intro]
    @Query(sort: \UpMatch.meetAt) private var matches: [UpMatch]
    @AppStorage(MyPorchLight.untilKey) private var upUntil: Double = 0
    @AppStorage(MyPorchLight.activityKey) private var upActivity = ""
    @AppStorage(MyPorchLight.noteKey) private var upWords = ""

    @State private var path = NavigationPath()
    @State private var busy = false
    @State private var problem: String?
    @State private var makingCrew = false
    @State private var openIntro: Intro?
    @State private var openMatch: UpMatch?
    @State private var invite: SharedText?

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(now: now)
                        content(now: now)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .background(Palette.bg)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Gathering.self) { GatheringDetailView(gathering: $0) }
            .navigationDestination(for: Kitchen.self) { KitchenView(kitchen: $0) }
            .navigationDestination(for: Order.self) { OrderStatusView(order: $0) }
            .navigationDestination(for: BlockRoute.self) { _ in BlockView() }
        }
        .onChange(of: BlockFeed.shared.openRequested, initial: true) { _, open in
            guard open else { return }
            BlockFeed.shared.openRequested = false
            path = NavigationPath([BlockRoute()])
        }
        .sheet(isPresented: $model.addingFriend) { AddFriendView() }
        .sheet(isPresented: $makingCrew) { NewCrewView(people: people) }
        .sheet(item: $openIntro) { ThirdTimeView(intro: $0).presentationBackground(Palette.bg) }
        .sheet(item: $openMatch) { MatchView(match: $0).presentationBackground(Palette.bg) }
        .sheet(item: $invite) { ShareSheet(text: $0.text).presentationDetents([.medium, .large]) }
        .task(id: matches.first?.id) { await keepUp() }
        .errorAlert($problem)
    }

    // MARK: Top

    private func header(now: Date) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(UpFor.dayLine(now)).eyebrow()
                Text("People").display(34)
            }
            Spacer()
            Button { path.append(BlockRoute()) } label: {
                Image(systemName: "bell")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 42, height: 42)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .overlay(alignment: .topTrailing) {
                        if BlockFeed.shared.hasNew {
                            Circle().fill(Palette.ink).frame(width: 9, height: 9).offset(x: -5, y: 5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(BlockFeed.shared.hasNew ? "Your block, something new" : "Your block")
            Button { model.addingFriend = true } label: {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 42, height: 42)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a friend")
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let friends = people.map(\.snapshot)
        let met = intros.map(\.friend)
        let metTimes = Dictionary(intros.map { ($0.id, $0.together.count) }, uniquingKeysWith: { a, _ in a })
        if let match = matches.first(where: { $0.endsAt > now }) {
            MatchCard(match: match, now: now, busy: busy, onOpen: { openMatch = match }, onMyWay: { onMyWay(match) })
        } else {
            UpForCard(
                until: upUntil > 0 ? Date(timeIntervalSince1970: upUntil) : nil,
                activity: upActivity, words: upWords, now: now, busy: busy, unavailable: friendsUnavailable,
                onStart: { activity, words, hours in start(activity, words, hours) },
                onStop: { stop() }
            )
        }

        nearYou(friends: friends, met: met, metTimes: metTimes, now: now)
        invites(now: now)
        metSection
        crewsSection(friends: friends, now: now)
        friendsSection(friends, now: now)
        wayIn(hasFriends: !friends.isEmpty)
    }

    // MARK: Up for something near you

    @ViewBuilder
    private func nearYou(friends: [Friend], met: [Friend], metTimes: [UUID: Int], now: Date) -> some View {
        let rows = UpFor.rows(friends: friends, met: met, metTimes: metTimes, now: now)
        sectionTitle("Up for something near you")
        if rows.isEmpty {
            Text(friendsUnavailable ?? (friends.isEmpty && met.isEmpty
                 ? "When friends and people you've met are up for something, they show here."
                 : "Nobody's up for anything right now. Say what you're up for and they'll see it."))
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(rows) { row in
            UpForRow(
                row: row, waved: waved(row, now: now), busy: busy, canMeet: ServerFeatures.shared.has(.upFor),
                onIn: { imIn(row) }, onWave: { wave(row) },
                onJoin: { if let g = gathering(row.gatheringID) { path.append(g) } }
            )
        }
    }

    private func waved(_ row: UpFor.Row, now: Date) -> Bool {
        guard let at = row.who.youWavedAt else { return false }
        return now.timeIntervalSince(at) < 2 * 3600
    }

    private func gathering(_ id: UUID?) -> Gathering? {
        id.flatMap { id in gatherings.first { $0.id == id } }
    }

    @ViewBuilder
    private func invites(now: Date) -> some View {
        let asked = gatherings.filter { !$0.invitedBy.isEmpty && !$0.isJoined && $0.isShown(at: now) }
        if !asked.isEmpty {
            sectionTitle("Asked along \u{00B7} \(asked.count)")
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
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
                    }
                    .foregroundStyle(Palette.ink)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: People you've met

    @ViewBuilder
    private var metSection: some View {
        let waiting = intros.filter { !$0.saidHi }
        if !waiting.isEmpty {
            sectionTitle("You've met")
            ForEach(waiting.prefix(3)) { intro in
                ThirdTimeRow(intro: intro) { openIntro = intro }
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: Crews

    @ViewBuilder
    private func crewsSection(friends: [Friend], now: Date) -> some View {
        let byID = Dictionary(friends.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        sectionTitle("Your crews")
        if crews.isEmpty {
            Text("A crew is the people you keep going out with: \u{201C}Thursday runners\u{201D}, \u{201C}trivia lot\u{201D}. Wren can plan for a whole crew at once.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(crews) { crew in
            let members = crew.memberIDs.compactMap { byID[$0] }
            let next = gathering(crew.nextGatheringID)
            Button {
                if let next { path.append(next) }
            } label: {
                HStack(spacing: 12) {
                    AvatarStack(friends: members, size: 34, includesYou: true, ground: Palette.bg)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(crew.name).font(.system(size: 16, weight: .semibold))
                        Text(crewLine(crew, members: members, now: now))
                            .font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if next != nil {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
                    }
                }
                .foregroundStyle(Palette.ink)
                .frame(minHeight: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) { leave(crew) } label: {
                    Label(crew.isMine ? "Delete crew" : "Leave crew", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        Button { makingCrew = true } label: { Label("New crew", systemImage: "plus") }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.top, 8)
            .disabled(people.isEmpty || !friendsOnServer)
    }

    /// "6 friends · next: Thursday run, Thu 7:00 AM"
    private func crewLine(_ crew: Crew, members: [Friend], now: Date) -> String {
        let who = members.isEmpty ? "Just you" : "\(members.count) friend\(members.count == 1 ? "" : "s")"
        guard let start = crew.nextStart, !crew.nextTitle.isEmpty, start > now.addingTimeInterval(-3 * 3600) else {
            return "\(who) \u{00B7} nothing planned yet"
        }
        return "\(who) \u{00B7} next: \(crew.nextTitle), \(When.short(start, now: now))"
    }

    // MARK: Friends

    @ViewBuilder
    private func friendsSection(_ friends: [Friend], now: Date) -> some View {
        if !friends.isEmpty {
            sectionTitle("Friends \u{00B7} \(friends.count)")
            ForEach(friends) { f in
                HStack(spacing: 12) {
                    FriendAvatar(friend: f, size: 36, ground: Palette.bg)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.name).font(.system(size: 15, weight: .semibold))
                        let detail = friendLine(f, now: now)
                        if !detail.isEmpty {
                            Text(detail).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .frame(minHeight: 48)
                .contextMenu {
                    if let p = people.first(where: { $0.id == f.id }) {
                        Button(role: .destructive) { unfriend(p) } label: {
                            Label("Remove friend", systemImage: "person.badge.minus")
                        }
                    }
                }
            }
        }
    }

    private func friendLine(_ f: Friend, now: Date) -> String {
        if let at = f.wavedAt, now.timeIntervalSince(at) < 2 * 3600 { return "Waved at you \(When.relative(at, now: now))" }
        if f.porchOn(at: now) { return "Up for \(UpFor.label(activity: f.upActivity, words: f.porchNote).lowercasedFirst)" }
        if let out = f.out { return out.state == .there ? "At \(out.title.lowercasedFirst)" : "Heading to \(out.title.lowercasedFirst)" }
        return ""
    }

    // MARK: A way in

    private func wayIn(hasFriends: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasFriends ? "Bring more of your people" : "Bring your people")
                .font(.system(size: 17, weight: .bold))
            Text("Send someone your one-use code from your contacts. And after three real check-ins at the same things as someone, they show up here to say hi.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button { inviteFromContacts() } label: {
                Label("Invite from contacts", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(busy || !friendsOnServer)
            Button("Got a code from someone? Add them") { model.addingFriend = true }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.soft)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(Palette.card, in: .rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Palette.line))
        .padding(.top, 28)
    }

    private func sectionTitle(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 17, weight: .bold))
            Spacer()
        }
        .padding(.top, 26)
        .padding(.bottom, 6)
    }

    // MARK: Actions

    private func start(_ activity: String, _ words: String, _ hours: Double) {
        let here = location.isUsingFallback ? nil : location.center
        run { () throws(APIError) in
            let until = try await Sync.upFor(activity: activity, words: words, hours: hours, at: here)
            upUntil = until.timeIntervalSince1970
        }
    }

    private func stop() {
        run { () throws(APIError) in
            try await Sync.upForOff()
            upUntil = 0
        }
    }

    private func imIn(_ row: UpFor.Row) {
        let here = location.isUsingFallback ? nil : location.center
        let id = row.who.id
        run { () throws(APIError) in
            try await Sync.imIn(id, at: here, context: context)
            openMatch = Sync.fetch(context, FetchDescriptor<UpMatch>()).first
        }
    }

    private func wave(_ row: UpFor.Row) {
        switch row.kind {
        case .friend:
            guard let p = people.first(where: { $0.id == row.who.id }) else { return }
            run { () throws(APIError) in try await Sync.wave(p, context: context) }
        case .met:
            guard let i = intros.first(where: { $0.id == row.who.id }) else { return }
            run { () throws(APIError) in try await Sync.wave(i, context: context) }
        case .gathering:
            break
        }
    }

    private func onMyWay(_ m: UpMatch) {
        let here = location.isUsingFallback ? nil : location.center
        run { () throws(APIError) in try await Sync.update(m, at: here, onMyWay: true, context: context) }
    }

    private func inviteFromContacts() {
        run { () throws(APIError) in
            let code = try await Sync.friendCode()
            invite = SharedText(text: "Come out with me on Let's Go. My friend code is \(AddFriendView.spaced(code.code)).")
        }
    }

    /// While you're meeting someone: find a spot about halfway if there isn't one, and every half
    /// minute tell the server where you are so both walk times stay right. Ends when the match does.
    private func keepUp() async {
        guard let m = matches.first else { return }
        let id = m.id
        if m.spotName.isEmpty, let area = m.area {
            let places = await SpotSearch.places(near: area)
            if let place = MeetSpot.pick(places, near: area) {
                await attempt($problem) { () throws(APIError) in try await Sync.setSpot(m, place, context: context) }
            }
        }
        while !Task.isCancelled {
            guard let current = matches.first(where: { $0.id == id }) else { return }
            let here = location.isUsingFallback ? nil : location.center
            do {
                try await Sync.update(current, at: here, context: context)
            } catch {
                // Offline for a moment; the next tick tries again.
            }
            try? await Task.sleep(for: .seconds(30))
        }
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
