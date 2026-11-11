import SwiftUI
import SwiftData
import MapKit

/// A gathering's page: the map at the top fading into the page, under the system's glass
/// back and share buttons; when, the title, where and the walk; a seat per spot; the
/// friend on their way, if one is; "I'm in" (or "Walk with Maya"); and Wren's note.
struct GatheringDetailView: View {
    @Bindable var gathering: Gathering
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allGatherings: [Gathering]
    @Query private var kitchens: [Kitchen]
    @Query private var notes: [TasteNote]
    @Query private var people: [Person]
    @State private var earned: Stamp?
    @State private var inviting = false
    @State private var postering = false
    @State private var here: HereMoment?
    @State private var walk: WalkTarget?
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var problem: String?
    /// "Just go": joined without walking in with the friend on their way.
    @State private var justGo = false

    /// Close enough to count as being there.
    private let checkInRadius: CLLocationDistance = 200

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            let going = friendsGoing(now: now)
            let meet = meetUp(going: going, now: now)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    banner
                    VStack(alignment: .leading, spacing: 16) {
                        titleBlock(now: now)
                        whosIn(going: going, now: now)
                        if let meet { onTheWay(meet, going: going) }
                        actions(meet: meet, going: going, now: now)
                        if let note = wrenNote(going: going, now: now) { WrenNote(text: note) }
                        InfoStrip(items: facts(now: now))
                        if !gathering.details.isEmpty {
                            Text(gathering.details).font(.system(size: 15)).foregroundStyle(Palette.ink.opacity(0.9))
                        }
                        hostLine
                        if gathering.isMine { posterBlock(now: now) }
                        if gathering.isListing { listingLinks }
                        checkInHint(now: now)
                        if gathering.isSample { SampleNote() }
                        if gathering.isMine {
                            Button("Cancel this gathering", role: .destructive) { confirmDelete = true }
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.top, 6)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, -28)
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .background(Palette.bg)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: GatheringCopy.share(
                        title: gathering.title,
                        eyebrow: GatheringCopy.eyebrow(start: gathering.start, end: gathering.end, now: now),
                        place: gathering.placeName, link: gathering.posterURL
                    )) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $here) { YouAreHereView(moment: $0) }
        .fullScreenCover(item: $walk) { EyesUpView(target: $0) }
        .sheet(isPresented: $inviting) { InviteFriendsView(gathering: gathering) }
        .sheet(isPresented: $postering) { PosterSheet(gathering: gathering) }
        .errorAlert($problem)
        .confirmationDialog("Cancel \(gathering.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Cancel it", role: .destructive) {
                run { () throws(APIError) in
                    try await Sync.cancel(gathering, context: context)
                    dismiss()
                }
            }
        } message: {
            Text("It comes off the map for everyone.")
        }
    }

    /// The map around the place, fading into the page. Just to look at.
    private var banner: some View {
        let me = Candidate(gathering, from: location.center)
        return Map(initialPosition: .camera(MapCamera(centerCoordinate: gathering.coordinate.offset(east: 0, north: -90), distance: 1600)),
                   interactionModes: []) {
            UserAnnotation()
            Annotation(gathering.title, coordinate: gathering.coordinate, anchor: .center) {
                NightPin(pick: me, size: 30, now: .now, showsCaption: false, picked: false)
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .including([.park, .beach, .publicTransport])))
        .frame(height: 290)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func titleBlock(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(GatheringCopy.eyebrow(start: gathering.start, end: gathering.end, now: now)).eyebrow(Palette.accentSoft)
                if gathering.isSample { SampleTag() }
            }
            Text(gathering.title).display(32).foregroundStyle(Palette.ink)
            Text(GatheringCopy.whereLine(place: gathering.placeName, meters: location.center.distance(to: gathering.coordinate)))
                .font(.system(size: 15))
                .foregroundStyle(Palette.muted)
            if !gathering.recurring.isEmpty {
                Text("\(gathering.category.label) · \(gathering.recurring)")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    private func facts(now: Date) -> [InfoStrip.Item] {
        let live = gathering.isLive(at: now)
        return [
            .init(label: live ? "On" : "Starts", value: live ? "Now" : gathering.start.formatted(.dateTime.hour().minute()),
                  detail: live ? "until \(gathering.end.formatted(date: .omitted, time: .shortened))" : When.relative(gathering.start, now: now)),
            .init(label: "Walk", value: "\(Walk.minutes(location.center.distance(to: gathering.coordinate)))", detail: "minutes"),
            gathering.isListing
                ? .init(label: "Price", value: priceValue, detail: priceDetail)
                : .init(label: "Going", value: "\(gathering.going)", detail: gathering.capacity > 0 ? "of \(gathering.capacity)" : "so far"),
        ]
    }

    /// Your friends going to this, real or (placed) sample.
    private func friendsGoing(now: Date) -> [Friend] {
        let all = Nearby.candidates(gatherings: allGatherings, kitchens: kitchens, from: location.center, now: now)
        let taste = Nearby.taste(notes: notes, gatherings: allGatherings, kitchens: kitchens)
        let friends = Crowd.resolve(people.map(\.snapshot), picks: Picks.picks(all, now: now, taste: taste, limit: 12),
                                    here: location.center, now: now)
        return Crowd.going(to: Candidate(gathering, from: location.center), among: friends)
    }

    /// Seats and friends for things with people to count; for a listing, just your friends.
    @ViewBuilder
    private func whosIn(going: [Friend], now: Date) -> some View {
        if !gathering.isListing || !going.isEmpty {
            WhosInCard(gathering: gathering, friends: going, now: now)
        }
    }

    /// Wren's walk past a friend who's on the way: until you've said "Just go", or it's started.
    private func meetUp(going: [Friend], now: Date) -> MeetUp? {
        guard !justGo, gathering.checkedInAt == nil, !gathering.isLive(at: now), !gathering.hasEnded(at: now) else { return nil }
        return MeetUp.best(here: location.center, friends: going, to: Candidate(gathering, from: location.center), now: now)
    }

    /// "Maya's on the way · Two minutes from you. Leave at 6:32 and walk in together?"
    @ViewBuilder
    private func onTheWay(_ meet: MeetUp, going: [Friend]) -> some View {
        let words = GatheringCopy.onTheWay(meet)
        HStack(spacing: 12) {
            if let friend = going.first(where: { $0.id == meet.friendID }) {
                FriendAvatar(friend: friend, size: 38, ring: .live, ground: Palette.card)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(words.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(words.detail).font(.system(size: 14)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .card(radius: 22)
    }

    /// Wren's note under the buttons: who's already there, and why this one.
    private func wrenNote(going: [Friend], now: Date) -> String? {
        if gathering.hasEnded(at: now) { return nil }
        var parts: [String] = []
        let there = going.filter { $0.out?.state == .there }
        if gathering.checkedInAt == nil, let f = there.first {
            parts.append("\(f.firstName)'s already there\(there.count > 1 ? " with \(there.count - 1) more" : ""). It's a straight walk over.")
        }
        if let tip = tipNote(now: now) { parts.append(tip) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "Free" → "Free"; "$10–20" → "$10–20"; long text gets cut to its first part.
    private var priceValue: String {
        let p = gathering.priceText.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return "—" }
        let first = p.split(whereSeparator: { $0 == "(" || $0 == "," || $0 == ";" }).first.map(String.init) ?? p
        return first.trimmingCharacters(in: .whitespaces).count <= 9 ? first.trimmingCharacters(in: .whitespaces) : "See site"
    }

    private var priceDetail: String {
        priceValue.lowercased().hasPrefix("free") ? "just show up" : "per person"
    }

    private var listingLinks: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !gathering.address.isEmpty {
                Text(gathering.address).font(.system(size: 14)).foregroundStyle(Palette.muted).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if let s = gathering.sourceURL, let url = URL(string: s) {
                    Link(destination: url) { Label("Website", systemImage: "safari") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if let maps = mapsURL {
                    Link(destination: maps) { Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    /// Opens Apple Maps walking directions to the spot.
    private var mapsURL: URL? {
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [
            URLQueryItem(name: "daddr", value: "\(gathering.latitude),\(gathering.longitude)"),
            URLQueryItem(name: "q", value: gathering.placeName),
            URLQueryItem(name: "dirflg", value: "w"),
        ]
        return c?.url
    }

    private var hostLine: some View {
        HStack(spacing: 10) {
            Text(initials(gathering.hostName))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 38, height: 38)
                .background(Palette.raise, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(gathering.isMine ? "You're hosting" : gathering.isListing ? "Run by \(gathering.hostName)" : "\(gathering.hostName) runs this")
                    .font(.system(size: 14, weight: .semibold))
                if let host = gathering.sourceURL.flatMap({ URL(string: $0)?.host() }) {
                    Text("Listed from \(host.replacingOccurrences(of: "www.", with: ""))\(gathering.recurring.isEmpty ? "" : " · \(gathering.recurring)")")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else if !gathering.recurring.isEmpty {
                    Text(gathering.recurring).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    /// Hosts get a poster to print and tape up; people who scan it can say they're in from the web.
    /// Only for a real gathering on the server, never a sample.
    @ViewBuilder
    private func posterBlock(now: Date) -> some View {
        let unavailable = PosterCopy.unavailable(gathering, now: now)
        if !gathering.isSample, !gathering.hasEnded(at: now) {
            VStack(alignment: .leading, spacing: 8) {
                Button { postering = true } label: {
                    Label(gathering.posterCode == nil ? "Make a poster" : "Your poster", systemImage: "doc.richtext")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(unavailable != nil)
                if let unavailable {
                    Text(unavailable).font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else if !gathering.webNames.isEmpty {
                    Text("From your poster: \(gathering.webNames.joined(separator: ", "))")
                        .font(.system(size: 13)).foregroundStyle(Palette.muted)
                } else {
                    Text("Tape it up nearby. Anyone can scan it and say they're in, no app needed.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    @ViewBuilder
    private func checkInHint(now: Date) -> some View {
        if gathering.checkedInAt != nil {
            Label("You showed up. Stamp collected.", systemImage: "checkmark.seal.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(gathering.category.color)
        } else {
            Label("Check in when you're there to collect the \(gathering.placeName) stamp.", systemImage: "seal")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
        }
    }

    /// The one prominent button (yellow glass) and a clear glass one next to it.
    private func actions(meet: MeetUp?, going: [Friend], now: Date) -> some View {
        let distance = location.center.distance(to: gathering.coordinate)
        let canCheckIn = !location.isUsingFallback && distance <= checkInRadius && gathering.checkInOpen(at: now)
        let walkable = distance > checkInRadius && !gathering.hasEnded(at: now)
        let meetFriend = meet.flatMap { m in going.first { $0.id == m.friendID } }
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                if gathering.checkedInAt != nil {
                    prominent("You're here", tint: gathering.category.color) {}
                        .disabled(true)
                    Button { here = HereMoment(title: gathering.placeName, genre: gathering.category, checkedInAt: gathering.checkedInAt ?? now,
                                               friends: going, stamped: true) } label: {
                        Image(systemName: "moon.stars")
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("You're here")
                } else if canCheckIn {
                    prominent("Check in") {
                        let at = location.center
                        run { () throws(APIError) in
                            earned = try await Sync.checkIn(gathering, at: at, context: context)
                            Ledger.arrive(gathering.placeName, genre: gathering.category, with: going, isSample: gathering.isSample, context: context)
                            here = HereMoment(title: gathering.placeName, genre: gathering.category, checkedInAt: .now,
                                              friends: going, stamped: earned != nil)
                        }
                    }
                } else if gathering.isJoined {
                    if let meet, let meetFriend, walkable {
                        prominent("Walk with \(meet.friendName)", symbol: "figure.walk") { walkThere(with: [meetFriend]) }
                    } else if walkable {
                        prominent("Walk there", symbol: "figure.walk") { walkThere(with: going) }
                            .accessibilityLabel("Walk me there, eyes up")
                    } else {
                        Button { } label: { Text("You're in").frame(maxWidth: .infinity) }
                            .buttonStyle(.glass)
                            .disabled(true)
                    }
                    if !gathering.isMine {
                        Button("Leave") {
                            run { () throws(APIError) in try await Sync.leave(gathering, context: context) }
                        }
                        .buttonStyle(.glass)
                    }
                } else if let meet, !gathering.isFull {
                    // Say you're in, walking in with them; the card says when to leave.
                    prominent("Walk with \(meet.friendName)", symbol: "figure.walk") {
                        run { () throws(APIError) in try await Sync.join(gathering, context: context) }
                    }
                    Button("Just go") {
                        justGo = true
                        run { () throws(APIError) in try await Sync.join(gathering, context: context) }
                    }
                    .buttonStyle(.glass)
                } else {
                    prominent(gathering.isFull ? "Full" : gathering.isListing ? "I'm going" : "I'm in") {
                        run { () throws(APIError) in try await Sync.join(gathering, context: context) }
                    }
                    .disabled(gathering.isFull)
                }
            }
            if !people.isEmpty, gathering.checkedInAt == nil, !gathering.hasEnded(at: now) {
                Button { inviting = true } label: { Label("Bring someone", systemImage: "person.badge.plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Palette.ink)
        .controlSize(.large)
        .sensoryFeedback(.success, trigger: gathering.isJoined)
        .disabled(busy)
    }

    /// The system's prominent glass, in yellow (or the colour given) with dark ink.
    private func prominent(_ title: String, symbol: String? = nil, tint: Color = Palette.accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(Palette.accentInk)
        }
        .buttonStyle(.glassProminent)
        .tint(tint)
    }

    private func walkThere(with friends: [Friend]) {
        walk = WalkTarget(title: gathering.placeName, genre: gathering.category, latitude: gathering.latitude,
                          longitude: gathering.longitude, start: gathering.start, friends: friends)
    }

    private func run(_ work: @escaping () async throws(APIError) -> Void) {
        busy = true
        Task {
            await attempt($problem, work)
            busy = false
        }
    }

    private func tipNote(now: Date) -> String? {
        let sameKind = allGatherings.filter { $0.id != gathering.id && $0.category == gathering.category && $0.checkedInAt != nil }.count
        var parts: [String] = []
        if let left = gathering.spotsLeft, left > 0, left <= 3 {
            parts.append(left == 1 ? "They need **one more**." : "They need **\(left) more**.")
        }
        if sameKind > 0 {
            parts.append("You've shown up to \(sameKind) \(gathering.category.noun) before.")
        } else if gathering.going >= 6 {
            parts.append("Good one to try first: \(gathering.going) people, all from around here.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

struct StampEarnedView: View {
    var stamp: Stamp
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            StampBadge(symbol: stamp.symbol, color: stamp.category.color, size: 120)
                .padding(.top, 30)
            Text("Stamp collected").eyebrow(stamp.category.color)
            Text(stamp.title).display(26).multilineTextAlignment(.center)
            Text("It's in your passport.").foregroundStyle(Palette.muted)
            Spacer()
            Button("Nice") { dismiss() }.buttonStyle(PrimaryButtonStyle(color: stamp.category.color))
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

struct StampBadge: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 56
    var locked = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(locked ? 0.08 : 0.18))
            Circle()
                .stroke(color.opacity(locked ? 0.3 : 0.7), style: StrokeStyle(lineWidth: max(1.5, size / 40), dash: [size / 18, size / 22]))
                .padding(size * 0.07)
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(locked ? Palette.muted : color)
        }
        .frame(width: size, height: size)
        .opacity(locked ? 0.6 : 1)
    }
}
