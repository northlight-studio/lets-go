import SwiftUI
import SwiftData
import MapKit
import UIKit

/// "I'm up for…": pick what (or say it in your own words), for how long, and who sees it.
struct UpForCard: View {
    var until: Date?
    var activity: String
    var words: String
    var now: Date
    var busy: Bool
    var onStart: (_ activity: String, _ words: String, _ hours: Double) -> Void
    var onStop: () -> Void

    /// An activity key, `ownWords`, or nothing yet.
    @State private var picked = ""
    @State private var own = ""
    @State private var hours = UpFor.defaultHours
    @State private var changing = false
    @FocusState private var typing: Bool

    private static let ownWords = "own"

    var body: some View {
        let on = (until ?? .distantPast) > now
        VStack(alignment: .leading, spacing: 12) {
            if on && !changing {
                lit
            } else {
                form(on: on)
            }
        }
        .padding(16)
        .background(on && !changing ? Palette.porch.opacity(0.1) : Palette.card, in: .rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(on && !changing ? Palette.porch.opacity(0.3) : Palette.line))
        .animation(.snappy(duration: 0.25), value: on)
        .animation(.snappy(duration: 0.25), value: changing)
        .sensoryFeedback(.impact(weight: .light), trigger: on)
    }

    private var lit: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(UpFor.emoji(activity)).font(.system(size: 26))
                    .frame(width: 46, height: 46)
                    .background(Palette.porch.opacity(0.22), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text("You're up for").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.porchSoft)
                    Text(UpFor.label(activity: activity, words: words).lowercasedFirst)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(2)
                }
            }
            Text(UpFor.whoSees(until: until ?? now, clock: HomeLine.clock(until ?? now)))
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Change") {
                    picked = UpFor.activity(activity) != nil ? activity : Self.ownWords
                    own = UpFor.activity(activity) == nil ? words : ""
                    changing = true
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Turn off") { onStop() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(busy)
            }
        }
    }

    private func form(on: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("I'm up for\u{2026}").font(.system(size: 20, weight: .bold))
                Spacer()
                if changing {
                    Button("Cancel") { changing = false }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .buttonStyle(.plain)
                }
            }
            FlowLayout(spacing: 8) {
                ForEach(UpFor.activities) { a in
                    chip("\(a.emoji) \(a.label)", key: a.key)
                }
                chip("\(UpFor.ownWordsEmoji) Your own words", key: Self.ownWords)
            }
            if picked == Self.ownWords {
                TextField("Frisbee, a bookstore, a long lunch", text: $own)
                    .font(.system(size: 16, weight: .medium))
                    .focused($typing)
                    .submitLabel(.done)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Palette.raise.opacity(0.6), in: .capsule)
                    .onChange(of: own) { _, new in if new.count > 80 { own = String(new.prefix(80)) } }
            }
            HStack(spacing: 6) {
                Text("For").font(.system(size: 15)).foregroundStyle(Palette.muted)
                Menu {
                    ForEach(UpFor.hourChoices, id: \.self) { h in
                        Button(UpFor.hoursText(h)) { hours = h }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(UpFor.hoursText(hours)).font(.system(size: 15, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Palette.ink)
                }
            }
            Text(UpFor.whoSees(hours: hours))
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(on ? "Update it" : "I'm up for it") {
                typing = false
                let key = picked == Self.ownWords ? "" : picked
                onStart(key, picked == Self.ownWords ? own : "", hours)
                changing = false
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy || !ready)
        }
    }

    private var ready: Bool {
        if picked == Self.ownWords { return !own.trimmingCharacters(in: .whitespaces).isEmpty }
        return UpFor.activity(picked) != nil
    }

    private func chip(_ title: String, key: String) -> some View {
        let on = picked == key
        return Button {
            withAnimation(.snappy(duration: 0.2)) { picked = on ? "" : key }
            if key == Self.ownWords && !on { typing = true }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Palette.onProminent : Palette.ink)
                .padding(.horizontal, 13)
                .frame(height: 36)
                .background(on ? Palette.prominent : Palette.raise.opacity(0.6), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One person (or one gathering) in "Up for something near you".
struct UpForRow: View {
    var row: UpFor.Row
    var waved: Bool
    var busy: Bool
    var onIn: () -> Void
    var onWave: () -> Void
    var onJoin: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FriendAvatar(friend: row.who, size: 42, ring: row.kind == .gathering ? .live : .porch, ground: Palette.surface)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 16, weight: .semibold))
                    if row.kind == .met {
                        Text("Met").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                            .padding(.horizontal, 6).frame(height: 18)
                            .background(Palette.raise.opacity(0.7), in: .capsule)
                    }
                }
                Text(row.emoji.isEmpty ? row.detail : "\(row.emoji) \(row.detail)")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            switch row.kind {
            case .gathering:
                if row.gatheringID != nil {
                    pill("Join", action: onJoin)
                }
            case .friend, .met:
                Button(action: onWave) {
                    Image(systemName: waved ? "hand.wave.fill" : "hand.wave")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(waved ? Palette.porchSoft : Palette.ink)
                        .frame(width: 36, height: 36)
                        .background(Palette.raise.opacity(0.6), in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(waved || busy)
                .accessibilityLabel(waved ? "Waved" : "Wave at \(row.name)")
                pill("I'm in", action: onIn)
                    .disabled(busy)
            }
        }
        .padding(.vertical, 8)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Palette.onProminent)
            .padding(.horizontal, 14).frame(height: 34)
            .background(Palette.prominent, in: .capsule)
            .buttonStyle(.plain)
    }
}

/// On People while you're meeting someone: who, where, when, and On my way.
struct MatchCard: View {
    var match: UpMatch
    var now: Date
    var busy: Bool
    var onOpen: () -> Void
    var onMyWay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Someone's in").eyebrow(Palette.accentSoft)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
                    }
                    Text(match.headline).font(.system(size: 22, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    Text(MatchCopy.lead(spot: match.spotName, meetAt: match.meetAt, now: now))
                        .font(.system(size: 15)).foregroundStyle(Palette.soft)
                    let them = MatchCopy.them(match.other.firstName, walk: match.theirWalkMinutes,
                                              onTheirWay: match.theyAreOnTheirWay, says: match.theySay)
                    if !them.isEmpty {
                        Text(them).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.muted)
                    }
                }
                .foregroundStyle(Palette.ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(match.iAmOnMyWay ? "You're on your way" : "On my way", action: onMyWay)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || match.iAmOnMyWay)
        }
        .padding(16)
        .background(Palette.card, in: .rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Palette.accent.opacity(0.3)))
    }
}

/// "You and Maya are going for a walk": the spot about halfway, when, your walk on a small map,
/// On my way, a short reply, and Done. Their walk is a time, never a line from where they are.
struct MatchView: View {
    @Bindable var match: UpMatch
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var route: [CLLocationCoordinate2D] = []
    @State private var busy = false
    @State private var problem: String?
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        // The other one tapped Done, or it ran out: nothing left to show.
        if match.isDeleted || match.modelContext == nil {
            Color.clear.onAppear { dismiss() }
        } else {
            page
        }
    }

    private var page: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        AvatarStack(friends: [match.other], size: 38, includesYou: true, ground: Palette.bg)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                                .frame(width: 34, height: 34)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")
                    }
                    .padding(.top, 8)
                    Text(match.headline).display(30).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MatchCopy.lead(spot: match.spotName, meetAt: match.meetAt, now: now))
                            .font(.system(size: 17, weight: .medium))
                        let them = MatchCopy.them(match.other.firstName, walk: match.theirWalkMinutes,
                                                  onTheirWay: match.theyAreOnTheirWay, says: match.theySay)
                        if !them.isEmpty {
                            Text(them).font(.system(size: 15)).foregroundStyle(Palette.muted)
                        }
                        if let mine = match.myWalkMinutes {
                            Text("Your walk: \(mine) min").font(.system(size: 15)).foregroundStyle(Palette.muted)
                        }
                    }
                    map
                    Button(match.iAmOnMyWay ? "You're on your way" : "On my way") { send(onMyWay: true) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(busy || match.iAmOnMyWay)
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(MatchCopy.replies, id: \.self) { reply in
                                Button(reply) { send(says: reply) }
                            }
                        } label: {
                            Label("Message", systemImage: "text.bubble")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button("Done") { finish() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .disabled(busy)
                    if !match.iSaid.isEmpty {
                        Text("You said: \(match.iSaid)").font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }
                    Label(MatchCopy.privacy, systemImage: "lock")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .background(Palette.bg)
        .task(id: match.spotName) { await drawWalk() }
        .errorAlert($problem)
    }

    private var map: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            UserAnnotation()
            if let spot = match.spot {
                Marker(match.spotName, systemImage: "mappin", coordinate: spot)
                    .tint(Palette.accent)
            }
            if route.count > 1 {
                MapPolyline(coordinates: route)
                    .stroke(Palette.walk, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .including([.park, .cafe])))
        .frame(height: 220)
        .clipShape(.rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line))
    }

    /// Your walk to the spot, from Apple Maps. Theirs isn't drawn: nobody gets where they are.
    private func drawWalk() async {
        guard let spot = match.spot else { return }
        let here = location.center
        let leg = await RouteBook().walk(from: here, to: spot)
        route = leg?.coordinates ?? [here, spot]
        let lats = route.map(\.latitude), lons = route.map(\.longitude)
        if let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() {
            let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
            let span = MKCoordinateSpan(latitudeDelta: max(0.004, (maxLat - minLat) * 1.6), longitudeDelta: max(0.004, (maxLon - minLon) * 1.6))
            camera = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    private func send(onMyWay: Bool? = nil, says: String? = nil) {
        let here = location.isUsingFallback ? nil : location.center
        busy = true
        Task {
            await attempt($problem) { () throws(APIError) in
                try await Sync.update(match, at: here, onMyWay: onMyWay, says: says, context: context)
            }
            busy = false
        }
    }

    private func finish() {
        let m = match
        busy = true
        dismiss()
        Task {
            await attempt($problem) { () throws(APIError) in try await Sync.done(m, context: context) }
            busy = false
        }
    }
}

/// Real public places about halfway, from Apple Maps on this phone: parks and cafés.
enum SpotSearch {
    static func places(near c: CLLocationCoordinate2D) async -> [MeetSpot.Place] {
        let request = MKLocalPointsOfInterestRequest(center: c, radius: MeetSpot.within)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.park, .cafe])
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.compactMap { item in
                guard let name = item.name, !name.isEmpty else { return nil }
                let at = item.placemark.coordinate
                return MeetSpot.Place(name: name, latitude: at.latitude, longitude: at.longitude,
                                      isPark: item.pointOfInterestCategory == .park)
            }
        } catch {
            return []
        }
    }
}

/// The share sheet, for sending your friend code to someone in your contacts.
struct ShareSheet: UIViewControllerRepresentable {
    var text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Something to share, as a sheet item.
struct SharedText: Identifiable {
    var text: String
    var id: String { text }
}
