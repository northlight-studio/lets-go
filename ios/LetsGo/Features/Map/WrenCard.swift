import SwiftUI
import CoreLocation

/// Wren's pick on a glass sheet over the map: "Wren's pick", the title, "4 of 6 in ·
/// 6-minute walk · leave by 6:40", who's in, and "I'm in" right there; "Not tonight"
/// moves on to the next one. Drag it up, or tap the handle, for the whole list. It's the
/// system's glass in the shape of a sheet rather than a presented sheet, so the tab bar
/// stays under it.
struct WrenCard: View {
    var picks: [Candidate]
    var now: Date
    /// Your friends, for who's going and who to walk in with.
    var friends: [Friend] = []
    var here: CLLocationCoordinate2D
    /// Listings only cover San Francisco so far (`CityListings.covers`).
    var inCity: Bool = true
    var busy: Bool
    /// The pick's walk from a real route, when there is one.
    var walkMinutes: Int? = nil
    var onOpen: (Candidate) -> Void
    var onJoin: (Candidate) -> Void
    var onSkip: (Candidate) -> Void
    var onList: () -> Void
    var onHost: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Palette.muted.opacity(0.5))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
                .onTapGesture(perform: onList)
                .accessibilityLabel("Show everything nearby")
                .accessibilityAddTraits(.isButton)
            header
            if let top = picks.first {
                let going = Crowd.going(to: top, among: friends)
                Button { onOpen(top) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(top.title)
                            .font(.system(size: 20, weight: .bold))
                            .tracking(-0.3)
                            .foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(HomeLine.meta(for: top, now: now, walkMinutes: walkMinutes))
                            .font(.system(size: 14))
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                        if let meet = MeetUp.best(here: here, friends: going, to: top, now: now) {
                            Text("Leave at \(HomeLine.clock(meet.leave)) and walk in with \(meet.friendName).")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Palette.accentSoft)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                if top.kind == .gathering, !going.isEmpty || top.isJoined || top.going > 0 {
                    faces(top, going: going)
                        .padding(.top, 10)
                }
                actions(top)
                    .padding(.top, 14)
                if let next = picks.dropFirst().first {
                    NextRow(pick: next, now: now) { onOpen(next) }
                        .padding(.top, 14)
                        .mask(LinearGradient(colors: [.black, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                }
            } else {
                line(HomeLine.empty(inCity: inCity)).padding(.top, 6)
                Button(action: onHost) { Label("Host something", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .glassPanel(radius: 34)
        .gesture(DragGesture(minimumDistance: 24).onEnded { v in
            if v.translation.height < -30 { onList() }
        })
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle").font(.system(size: 12, weight: .bold))
            Text("Wren's pick")
            Spacer()
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Palette.accentSoft)
    }

    /// Friends' faces, you if you're in, then "+2" for everyone else.
    private func faces(_ top: Candidate, going: [Friend]) -> some View {
        let shown = min(going.count, 5)
        return HStack(spacing: 6) {
            AvatarStack(friends: going, size: 28, includesYou: top.isJoined)
                .animation(.snappy, value: top.isJoined)
            if let others = HomeLine.others(top, friendsShown: shown) {
                Text(others)
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .frame(minWidth: 28, minHeight: 28)
                    .padding(.horizontal, 2)
                    .background(Palette.raise, in: .capsule)
                    .padding(.leading, going.isEmpty && !top.isJoined ? 0 : -10)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func line(_ l: HomeLine.Line) -> some View {
        Text("\(l.lead)\(Text(l.emphasis).foregroundStyle(Palette.accentSoft))\(l.tail)")
            .font(.system(size: 18, weight: .semibold))
            .tracking(-0.2)
            .lineSpacing(2)
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actions(_ top: Candidate) -> some View {
        HStack(spacing: 10) {
            switch top.kind {
            case .gathering:
                if top.isJoined {
                    Button { onOpen(top) } label: { Text("You're in").frame(maxWidth: .infinity) }
                        .buttonStyle(.glass)
                } else {
                    Button { onJoin(top) } label: { Text(top.spotsLeft == 0 ? "Full" : "I'm in").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent)
                        .tint(Palette.accent)
                        .foregroundStyle(Palette.accentInk)
                        .disabled(top.spotsLeft == 0 || busy)
                }
            case .drop:
                Button { onOpen(top) } label: { Text("Reserve a pickup").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
                    .foregroundStyle(Palette.accentInk)
            }
            Button("Not tonight") { onSkip(top) }
                .buttonStyle(.glass)
                .foregroundStyle(Palette.ink)
        }
        .font(.system(size: 17, weight: .semibold))
        .controlSize(.large)
        .sensoryFeedback(.success, trigger: top.isJoined)
    }
}

/// The next pick under Wren's line, half faded: there if the first isn't it.
private struct NextRow: View {
    var pick: Candidate
    var now: Date
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CategoryDot(category: pick.category, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(pick.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    }
                    Text(Picks.reason(pick, now: now))
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(pick.walkMinutes) min")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.soft)
            }
            .foregroundStyle(Palette.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
