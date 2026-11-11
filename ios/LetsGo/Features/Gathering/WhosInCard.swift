import SwiftUI
import SwiftData

/// Who's in on a gathering: a seat per spot when it's small enough to count, filled as
/// people say they're in. Your friends get a green ring, the seat that's yours if you want
/// it is ringed in yellow ("You?"), and your face pops into it when you join. Sits on the
/// page, not in a box.
struct WhosInCard: View {
    var gathering: Gathering
    var friends: [Friend]
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).eyebrow()
                Spacer()
                if gathering.capacity > 0 {
                    Text("\(Text("\(gathering.going)").foregroundStyle(Palette.ink)) of \(gathering.capacity)")
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                } else {
                    Text("\(gathering.going) going")
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                }
            }
            if (1...12).contains(gathering.capacity) {
                seats.padding(.top, 14)
            } else if !friends.isEmpty {
                AvatarStack(friends: friends, size: 40, includesYou: gathering.isJoined, ground: Palette.bg, limit: 8)
                    .padding(.top, 14)
            }
            notes
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: gathering.isJoined)
    }

    private var title: String {
        if gathering.isMine { return "Who's in" }
        if gathering.category == .party, (1...8).contains(gathering.capacity), !gathering.isListing {
            return "\(gathering.hostName.split(separator: " ").first.map(String.init) ?? gathering.hostName)'s team"
        }
        return "Who's in"
    }

    // MARK: Seats

    private enum Seat: Identifiable {
        case host(String), friend(Friend), you, taken(Int), open(Int), yours

        var id: String {
            switch self {
            case .host: "host"
            case .friend(let f): f.id.uuidString
            case .you: "you"
            case .taken(let i): "taken\(i)"
            case .open(let i): "open\(i)"
            case .yours: "yours"
            }
        }
    }

    private var seatList: [Seat] {
        let cap = gathering.capacity
        var seats: [Seat] = []
        var filled = gathering.going
        let hostCounts = !gathering.isListing && !gathering.isMine && !gathering.hostName.isEmpty
        if hostCounts, filled > 0 {
            seats.append(.host(gathering.hostName))
            filled -= 1
        }
        for f in friends.prefix(max(0, filled)) {
            seats.append(.friend(f))
        }
        filled -= min(filled, friends.count)
        if gathering.isJoined, filled > 0 {
            seats.append(.you)
            filled -= 1
        }
        if filled > 0 { for i in 0..<filled { seats.append(.taken(i)) } }
        if !gathering.isJoined, seats.count < cap { seats.append(.yours) }
        while seats.count < cap { seats.append(.open(seats.count)) }
        return Array(seats.prefix(cap))
    }

    private var seats: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 6), spacing: 12) {
            ForEach(seatList) { seat in
                VStack(spacing: 6) {
                    seatCircle(seat)
                    Text(seatLabel(seat))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(seatLabelColor(seat))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }

    @ViewBuilder
    private func seatCircle(_ seat: Seat) -> some View {
        switch seat {
        case .host(let name):
            Text(String(name.first ?? "?"))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color(hex: Friend.ink(for: name)))
                .frame(width: 46, height: 46)
                .background(Color(hex: Friend.hue(for: name)), in: .circle)
        case .friend(let f):
            FriendAvatar(friend: f, size: 46, ring: .live, ground: Palette.bg)
        case .you:
            Text("You")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Palette.me, in: .circle)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .taken:
            Circle().fill(Palette.raise).frame(width: 46, height: 46)
                .overlay(Image(systemName: "person.fill").font(.system(size: 17)).foregroundStyle(Palette.muted))
        case .yours:
            YourSeat()
        case .open:
            Circle().strokeBorder(Palette.muted.opacity(0.45), lineWidth: 1.5)
                .frame(width: 46, height: 46)
        }
    }

    private func seatLabel(_ seat: Seat) -> String {
        switch seat {
        case .host(let name): "\(name.split(separator: " ").first.map(String.init) ?? name) \u{00B7} host"
        case .friend(let f): f.firstName
        case .you: "You"
        case .taken: "In"
        case .yours: "Your seat"
        case .open: "Open"
        }
    }

    private func seatLabelColor(_ seat: Seat) -> Color {
        switch seat {
        case .yours: Palette.accentSoft
        case .open, .taken: Palette.muted
        default: Palette.ink
        }
    }

    // MARK: Notes

    @ViewBuilder
    private var notes: some View {
        let lines = noteLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(line.dot).frame(width: 6, height: 6).offset(y: -2)
                        Text(line.text).font(.system(size: 14)).foregroundStyle(Palette.soft)
                    }
                }
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1).padding(.top, 2) }
            .padding(.top, 10)
        }
    }

    private var noteLines: [(text: String, dot: Color)] {
        var out: [(text: String, dot: Color)] = []
        if !friends.isEmpty {
            let sample = friends.contains { $0.isSample } ? " (sample)" : ""
            out.append(("\(Crowd.names(friends)) \(friends.count == 1 ? "is" : "are") in\(sample).", Palette.live))
        }
        if !gathering.invitedBy.isEmpty, !gathering.isJoined {
            out.append(("\(gathering.invitedBy) asked you along.", Palette.accentSoft))
        }
        if !gathering.bring.isEmpty { out.append(("Bring: \(gathering.bring)", Palette.muted)) }
        return out
    }
}

/// The open seat that's yours if you want it: ringed in yellow, breathing.
private struct YourSeat: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .strokeBorder(Palette.accent, lineWidth: 2.5)
            .frame(width: 46, height: 46)
            .overlay(Text("You?").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.accentSoft))
            .background(Circle().fill(Palette.accent.opacity(on ? 0 : 0.3)).scaleEffect(on ? 1.3 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
            .accessibilityLabel("An open seat for you")
    }
}

/// Ask friends along to a gathering.
struct InviteFriendsView: View {
    var gathering: Gathering
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Person.name) private var people: [Person]
    @State private var picked: Set<UUID> = []
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if people.isEmpty {
                        Text("Add friends on the People tab, then bring them along.").foregroundStyle(Palette.muted)
                    }
                    ForEach(people) { p in
                        let going = gathering.friendIDs.contains(p.id)
                        Button {
                            if picked.contains(p.id) { picked.remove(p.id) } else { picked.insert(p.id) }
                        } label: {
                            HStack(spacing: 12) {
                                FriendAvatar(friend: p.snapshot, size: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name).foregroundStyle(Palette.ink)
                                    if going { Text("Already in").font(.system(size: 12)).foregroundStyle(Palette.live) }
                                }
                                if p.isSample { SampleTag() }
                                Spacer()
                                Image(systemName: picked.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(p.id) ? Palette.accent : Palette.muted)
                            }
                        }
                        .disabled(going)
                    }
                } footer: {
                    Text("They'll see it on their People tab. Sample people are only marked asked on this phone.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle("Bring someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ask") { ask() }.fontWeight(.bold).disabled(picked.isEmpty || busy)
                }
            }
            .errorAlert($problem)
        }
    }

    private func ask() {
        let chosen = people.filter { picked.contains($0.id) }
        busy = true
        Task {
            await attempt($problem) { () throws(APIError) in
                try await Sync.invite(chosen, to: gathering, context: context)
                dismiss()
            }
            busy = false
        }
    }
}
