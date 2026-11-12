import SwiftUI

/// A friend's initial in their color. A green ring when they're in on something, an
/// amber one (with a glow) when their porch light is on.
struct FriendAvatar: View {
    enum Ring { case none, live, porch, edge(Color) }

    var friend: Friend
    var size: CGFloat = 40
    var ring: Ring = .none
    /// The ground around it, for the gap between avatar and ring.
    var ground: Color = Palette.surface

    var body: some View {
        Text(friend.initial)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(friend.ink)
            .frame(width: size, height: size)
            .background(friend.color, in: .circle)
            .overlay { ringView }
            .accessibilityLabel(friend.name)
    }

    @ViewBuilder
    private var ringView: some View {
        switch ring {
        case .none:
            EmptyView()
        case .live:
            Circle().stroke(ground, lineWidth: 2).padding(-2)
                .overlay(Circle().stroke(Palette.live, lineWidth: 1.5).padding(-3.5))
        case .porch:
            Circle().stroke(ground, lineWidth: 2).padding(-2)
                .overlay(Circle().stroke(Palette.porchSoft, lineWidth: 1.5).padding(-3.5))
                .shadow(color: Palette.porchSoft.opacity(0.45), radius: 8)
        case .edge(let color):
            Circle().stroke(color, lineWidth: 2).padding(-1)
        }
    }
}

/// Overlapping avatars: "M T B L", then "You" if you're in.
struct AvatarStack: View {
    var friends: [Friend]
    var size: CGFloat = 24
    var includesYou = false
    var ground: Color = Palette.card
    var limit = 5

    var body: some View {
        HStack(spacing: -size * 0.25) {
            ForEach(friends.prefix(limit)) { f in
                FriendAvatar(friend: f, size: size, ring: .edge(ground))
            }
            if includesYou {
                Text("You")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Palette.me, in: .circle)
                    .overlay(Circle().stroke(ground, lineWidth: 2).padding(-1))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Crowd.names(friends) + (includesYou ? ", and you" : ""))
    }
}

/// A friend on the map: their avatar, drifting a little, with a glow for a porch light
/// and their name under it.
struct FriendPin: View {
    var friend: Friend
    var now: Date
    var showsName = true
    @State private var drift = false
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let porch = friend.porchOn(at: now) && friend.out == nil
        ZStack {
            if porch {
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0xFFBE6E, opacity: 0.45), .clear], center: .center, startRadius: 0, endRadius: 26))
                    .frame(width: 52, height: 52)
                    .scaleEffect(glow ? 1.15 : 1)
                    .opacity(glow ? 1 : 0.55)
            }
            FriendAvatar(friend: friend, size: 26, ring: porch ? .porch : .edge(Palette.card), ground: Palette.card)
                .shadow(color: .black.opacity(porch ? 0 : 0.18), radius: 3, y: 1)
        }
        .frame(width: 26, height: 26)
        .overlay(alignment: .top) {
            if showsName {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(porch ? Palette.porchSoft : Palette.ink)
                    .shadow(color: Palette.bg, radius: 1.5)
                    .shadow(color: Palette.bg, radius: 1.5)
                    .fixedSize()
                    .offset(y: 30)
            }
        }
        .offset(x: drift ? 5 : -4, y: drift ? -4 : 3)
        .onAppear {
            guard !reduceMotion else { return }
            let period = 7 + 2 * Art.unit(friend.name, 9)
            withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) { drift = true }
            if porch { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { glow = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(porch: porch))
    }

    private var label: String {
        if friend.porchOn(at: now) && friend.out == nil { return "Porch light" }
        return friend.firstName
    }

    private func accessibility(porch: Bool) -> String {
        var parts = [friend.name]
        if porch { parts.append("porch light on") }
        if let out = friend.out { parts.append(out.state == .there ? "at \(out.title)" : "heading to \(out.title)") }
        return parts.joined(separator: ", ")
    }
}
