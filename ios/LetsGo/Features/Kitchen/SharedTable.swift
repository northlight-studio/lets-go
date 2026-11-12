import SwiftUI

/// A kitchen's porch as a shared table: eat with whoever's there. Plain logic first.
enum SharedTable {
    struct Seat: Identifiable, Equatable {
        enum Kind: Equatable { case friend(Friend, Date), taken(Int), yours, open(Int) }
        var kind: Kind
        var id: String {
            switch kind {
            case .friend(let f, _): f.id.uuidString
            case .taken(let i): "taken\(i)"
            case .yours: "yours"
            case .open(let i): "open\(i)"
            }
        }
    }

    struct Table: Equatable {
        var seats: Int
        var taken: Int
        /// Friends sitting down, and when.
        var friends: [(friend: Friend, at: Date)]

        var open: Int { max(0, seats - taken) }

        static func == (a: Table, b: Table) -> Bool {
            a.seats == b.seats && a.taken == b.taken
                && a.friends.map { $0.friend } == b.friends.map { $0.friend } && a.friends.map { $0.at } == b.friends.map { $0.at }
        }
    }

    /// Four to a porch table, friends first, then everyone else who's eating there, then one open
    /// seat marked yours (if there is one), then the rest open.
    static func seats(_ t: Table) -> [Seat] {
        var out: [Seat] = []
        for f in t.friends.prefix(t.seats) { out.append(Seat(kind: .friend(f.friend, f.at))) }
        let others = max(0, min(t.taken, t.seats) - out.count)
        for i in 0..<others { out.append(Seat(kind: .taken(i))) }
        if out.count < t.seats { out.append(Seat(kind: .yours)) }
        while out.count < t.seats { out.append(Seat(kind: .open(out.count))) }
        return out
    }

    /// The table at a kitchen's next drop, from the server's numbers: seats, porch orders, friends at it.
    static func table(seats porchTables: Int, serverTaken: Int, serverFriends: [TableSeat], people: [Friend],
                      drop: (start: Date, end: Date)?) -> Table? {
        guard porchTables > 0, drop != nil else { return nil }
        let byID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let friends = serverFriends.map { s in (friend: byID[s.personID] ?? Friend(id: s.personID, name: s.name), at: s.at) }
        return Table(seats: porchTables * 4, taken: max(serverTaken, friends.count), friends: friends)
    }
}

/// The garage table card: seats filling up, your open one, who's sitting down when.
struct SharedTableCard: View {
    var table: SharedTable.Table
    var name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).eyebrow()
                Spacer()
                Text("\(Text("\(table.open)").foregroundStyle(Palette.ink)) of \(table.seats) seats open")
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6), count: 8), spacing: 8) {
                ForEach(SharedTable.seats(table)) { seat in
                    seatView(seat).aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(.top, 12)
            Text(line)
                .font(.system(size: 14))
                .foregroundStyle(Palette.soft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .card(radius: 22)
    }

    private var line: String {
        guard let first = table.friends.first else {
            return table.open > 0 ? "Eat with whoever's there. A porch seat's yours if one's open when you get there." : "The table's full tonight. Pickup still works."
        }
        let next = table.open > 0 ? ", and there's a seat open next to them" : ""
        return "Eat with whoever's there. \(first.friend.firstName) sits down at \(NightPin.hour(first.at))\(next)."
    }

    @ViewBuilder
    private func seatView(_ seat: SharedTable.Seat) -> some View {
        switch seat.kind {
        case .friend(let f, _):
            FriendAvatar(friend: f, size: 34, ring: .live, ground: Palette.card)
        case .taken(let i):
            let tones: [UInt32] = [0xC9C3B6, 0xA7B6C9, 0xC6B2A6, 0xB4C7B0]
            Circle().fill(Color(hex: tones[i % tones.count])).frame(width: 34, height: 34)
                .overlay(Image(systemName: "person.fill").font(.system(size: 13)).foregroundStyle(.black.opacity(0.45)))
        case .yours:
            Circle().strokeBorder(Palette.accent, lineWidth: 2.5)
                .frame(width: 34, height: 34)
                .overlay(Text("You?").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accentSoft))
                .accessibilityLabel("An open seat for you")
        case .open:
            Circle().strokeBorder(Palette.muted.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                .frame(width: 34, height: 34)
        }
    }
}

/// Kenji's garage with the door up: a long table lit from inside, string lights, steam.
struct GarageArt: View {
    var sign: String
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let door = CGRect(x: w * 0.28, y: h * 0.52, width: w * 0.44, height: h * 0.39)
            ZStack(alignment: .topLeading) {
                Color(hex: 0x14121B)
                // Roof and wall.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.07, y: h * 0.29))
                    p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.09))
                    p.addLine(to: CGPoint(x: w * 0.93, y: h * 0.29))
                    p.closeSubpath()
                }
                .fill(Color(hex: 0x1A1822))
                Rectangle().fill(Color(hex: 0x211E2A))
                    .frame(width: w * 0.78, height: h * 0.63).offset(x: w * 0.11, y: h * 0.28)
                // A lit window and a dark one.
                Rectangle().fill(Color(hex: 0xFFC88A, opacity: 0.85))
                    .frame(width: w * 0.14, height: h * 0.13).offset(x: w * 0.65, y: h * 0.33)
                Rectangle().fill(Color(hex: 0x2C2936))
                    .frame(width: w * 0.14, height: h * 0.13).offset(x: w * 0.21, y: h * 0.33)
                // The open door, warm inside, light spilling out.
                Path { p in
                    p.move(to: CGPoint(x: door.minX, y: door.maxY))
                    p.addLine(to: CGPoint(x: door.maxX, y: door.maxY))
                    p.addLine(to: CGPoint(x: door.maxX + w * 0.15, y: h))
                    p.addLine(to: CGPoint(x: door.minX - w * 0.15, y: h))
                    p.closeSubpath()
                }
                .fill(Color(hex: 0xFFB86B, opacity: 0.16))
                Rectangle().fill(Color(hex: 0xF2A65E)).frame(width: door.width, height: door.height).offset(x: door.minX, y: door.minY)
                Rectangle().fill(Color(hex: 0xFFD29A, opacity: 0.35)).frame(width: door.width, height: door.height).offset(x: door.minX, y: door.minY)
                // The table and the people at it.
                ForEach(0..<3, id: \.self) { i in
                    VStack(spacing: 1) {
                        Circle().fill(Color(hex: 0x3B2617)).frame(width: 17, height: 17)
                        UnevenRoundedRectangle(topLeadingRadius: 13, topTrailingRadius: 13).fill(Color(hex: 0x3B2617)).frame(width: 26, height: 14)
                    }
                    .offset(x: door.minX + door.width * (0.12 + 0.2 * CGFloat(i)), y: door.minY + door.height * 0.42)
                }
                Rectangle().fill(Color(hex: 0x4A2E1A)).frame(width: door.width * 0.7, height: 7)
                    .offset(x: door.minX + door.width * 0.07, y: door.minY + door.height * 0.68)
                // The pot, steaming.
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x5A3A22))
                    .frame(width: 26, height: 20).offset(x: door.minX + door.width * 0.8, y: door.minY + door.height * 0.44)
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(Color(hex: 0xFFF1DE).opacity(on ? 0 : 0.7)).frame(width: 2, height: 10)
                        .offset(x: door.minX + door.width * 0.82 + CGFloat(i) * 7, y: door.minY + door.height * 0.36 - (on ? 22 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 3.2).repeatForever(autoreverses: false).delay(Double(i) * 1.1), value: on)
                }
                // String lights across the door.
                ForEach(0..<7, id: \.self) { i in
                    let t = CGFloat(i) / 6
                    Circle().fill(Color(hex: 0xFFE2B5)).frame(width: 5, height: 5)
                        .shadow(color: Color(hex: 0xFFD9A0), radius: on ? 6 : 3)
                        .offset(x: door.minX - 6 + (door.width + 12) * t, y: door.minY - 8 + 10 * (1 - pow(2 * t - 1, 2)))
                }
                // The chalkboard.
                Text(sign.uppercased())
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.8)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(hex: 0xFFD9A0))
                    .frame(width: w * 0.11, height: h * 0.1)
                    .background(Color(hex: 0x2E2A36), in: .rect(cornerRadius: 3))
                    .offset(x: w * 0.15, y: h * 0.67)
                Rectangle().fill(Color(hex: 0x100E15)).frame(width: w, height: h * 0.09).offset(y: h * 0.91)
            }
        }
        .clipped()
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { on = true } } }
        .accessibilityHidden(true)
    }
}
