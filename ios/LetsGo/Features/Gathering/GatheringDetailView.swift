import SwiftUI
import SwiftData
import MapKit

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

    /// Close enough to count as being there.
    private let checkInRadius: CLLocationDistance = 200

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        titleBlock(now: now)
                        InfoStrip(items: facts(now: now))
                        whosIn(now: now)
                        if let note = tipNote(now: now) { TipNote(text: note) }
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
                    .padding(.top, 6)
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Palette.bg)
            .safeAreaInset(edge: .bottom) { actions(now: now) }
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

    private func titleBlock(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(gathering.recurring.isEmpty ? gathering.category.label : "\(gathering.category.label) · \(gathering.recurring)")
                .eyebrow()
            Text(gathering.title).display(28).foregroundStyle(Palette.ink)
            Label(gathering.placeName, systemImage: "mappin.and.ellipse")
                .font(.system(size: 15))
                .foregroundStyle(Palette.muted)
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
    private func whosIn(now: Date) -> some View {
        let me = Candidate(gathering, from: location.center)
        let going = friendsGoing(now: now)
        if !gathering.isListing || !going.isEmpty {
            WhosInCard(
                gathering: gathering, friends: going,
                meet: gathering.isJoined || gathering.isLive(at: now) ? nil : MeetUp.best(here: location.center, friends: going, to: me, now: now),
                now: now
            )
        }
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

    private func actions(now: Date) -> some View {
        let distance = location.center.distance(to: gathering.coordinate)
        let canCheckIn = !location.isUsingFallback && distance <= checkInRadius && gathering.checkInOpen(at: now)
        return HStack(spacing: 10) {
            if gathering.checkedInAt != nil {
                Button("You're here") {}.buttonStyle(PrimaryButtonStyle(color: gathering.category.color)).disabled(true)
            } else if canCheckIn {
                Button("Check in") {
                    let at = location.center
                    let with = friendsGoing(now: now)
                    run { () throws(APIError) in
                        earned = try await Sync.checkIn(gathering, at: at, context: context)
                        Ledger.arrive(gathering.placeName, genre: gathering.category, with: with, isSample: gathering.isSample, context: context)
                        here = HereMoment(title: gathering.placeName, genre: gathering.category, checkedInAt: .now,
                                          friends: with, stamped: earned != nil)
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: gathering.category.color))
            } else if gathering.isJoined {
                Button("You're in") {}
                    .buttonStyle(PrimaryButtonStyle(color: Palette.raise))
                    .disabled(true)
                if !gathering.isMine {
                    Button("Leave") {
                        run { () throws(APIError) in try await Sync.leave(gathering, context: context) }
                    }
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 15)
                        .card()
                }
            } else {
                Button(gathering.isFull ? "Full" : gathering.isListing ? "I'm going" : "I'm in") {
                    run { () throws(APIError) in try await Sync.join(gathering, context: context) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(gathering.isFull)
            }
            if gathering.checkedInAt != nil {
                Button { here = HereMoment(title: gathering.placeName, genre: gathering.category, checkedInAt: gathering.checkedInAt ?? now,
                                           friends: friendsGoing(now: now), stamped: true) } label: {
                    Image(systemName: "moon.stars")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("You're here")
            } else if gathering.isJoined, !canCheckIn, distance > checkInRadius, !gathering.hasEnded(at: now) {
                Button { walkThere(now: now) } label: { Label("Walk", systemImage: "figure.walk") }
                    .buttonStyle(SecondaryButtonStyle())
                    .fixedSize()
                    .accessibilityLabel("Walk me there, eyes up")
            } else if !people.isEmpty {
                Button("Bring someone") { inviting = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .fixedSize()
            }
        }
        .sensoryFeedback(.success, trigger: gathering.isJoined)
        .disabled(busy)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Palette.bg)
    }

    private func walkThere(now: Date) {
        walk = WalkTarget(title: gathering.placeName, genre: gathering.category, latitude: gathering.latitude,
                          longitude: gathering.longitude, start: gathering.start, friends: friendsGoing(now: now))
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
        .presentationBackground(Palette.bg)
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
