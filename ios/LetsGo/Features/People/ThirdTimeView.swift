import SwiftUI
import SwiftData

/// Third time's a friend. After three real check-ins at the same things, Wren offers a
/// mutual intro: if you both say hi, you're friends. If not, nobody hears a thing.
struct ThirdTimeView: View {
    @Bindable var intro: Intro
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false
    @State private var busy = false
    @State private var problem: String?
    @State private var connected = false
    @State private var pulse = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    WrenOrb(size: 22, glows: false)
                    Text("Something Wren noticed").eyebrow(Palette.accentSoft)
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

                bond.frame(height: 140).padding(.top, 28)

                Text("\(Text("Third time's\na friend"))\(Text(".").foregroundStyle(Palette.accent))")
                    .font(.system(size: 44, weight: .bold))
                    .tracking(-1)
                    .padding(.top, 24)
                Text(lead)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Palette.soft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)

                VStack(alignment: .leading, spacing: 12) {
                    rule("person.2", "\(intro.name) gets this same card. If you both say hi, you're connected and Wren finds you a fourth time. If not, nobody hears a thing.")
                    rule("checkmark.seal", "Only real check-ins count, in person. Never likes, follows or scrolling.")
                }
                .padding(16)
                .card(radius: 22)
                .padding(.top, 22)

                actions.padding(.top, 26)
                if intro.isSample {
                    Text("Sample. \(intro.name) is a stand-in for someone you keep running into.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Palette.bg.ignoresSafeArea())
        .errorAlert($problem)
        .onAppear {
            if reduceMotion { drawn = true; return }
            withAnimation(.timingCurve(0.4, 0.1, 0.2, 1, duration: 1.8).delay(0.2)) { drawn = true }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var lead: String {
        let count = intro.together.count
        let titles = Set(intro.together.map(\.title))
        let what = titles.count == 1 ? (titles.first ?? "the same things").lowercasedFirst : "the same things"
        let days = Set(intro.together.map { $0.startsAt.formatted(.dateTime.weekday(.wide)) })
        let when = days.count == 1 ? " \(HomeLine.number(count)) \(days.first ?? "")s running" : ", \(HomeLine.number(count)) times now"
        return "You and \(intro.name) have been at \(what)\(when). Want to actually meet?"
    }

    /// You, them, and the nights between you, stamped along a line.
    private var bond: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let a = CGPoint(x: 38, y: 70), b = CGPoint(x: w - 38, y: 70)
            let curve = Path { p in
                p.move(to: a)
                p.addCurve(to: b, control1: CGPoint(x: w * 0.4, y: 10), control2: CGPoint(x: w * 0.6, y: 130))
            }
            ZStack {
                curve.stroke(Palette.line, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
                curve.trim(from: 0, to: drawn ? 1 : 0).stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                circle(Text("You").font(.system(size: 20, weight: .bold)).foregroundStyle(.white), fill: Palette.me).position(a)
                circle(Text(String(intro.name.prefix(1))).font(.system(size: 26, weight: .bold)).foregroundStyle(intro.friend.ink),
                       fill: intro.friend.color).position(b)
                ForEach(Array(intro.together.suffix(3).enumerated()), id: \.offset) { i, night in
                    seal(night.startsAt)
                        .rotationEffect(.degrees([-8.0, 5, -4][i % 3]))
                        .position(x: w * (0.32 + 0.18 * CGFloat(i)), y: 52 + 18 * CGFloat(i))
                        .scaleEffect(drawn ? 1 : 0.2)
                        .opacity(drawn ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6).delay(0.6 + 0.5 * Double(i)), value: drawn)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You and \(intro.name), \(intro.together.count) nights at the same place")
    }

    private func circle(_ label: some View, fill: Color) -> some View {
        label
            .frame(width: 76, height: 76)
            .background(fill, in: .circle)
            .overlay(Circle().stroke(Palette.bg, lineWidth: 4).padding(-4))
            .overlay(Circle().stroke(Palette.line, lineWidth: 1.5).padding(-5.5))
    }

    private func seal(_ d: Date) -> some View {
        VStack(spacing: 0) {
            Text(d.formatted(.dateTime.month(.abbreviated)).uppercased()).font(.system(size: 7, weight: .heavy)).tracking(0.6)
            Text(d.formatted(.dateTime.day())).font(.system(size: 14, weight: .heavy)).monospacedDigit()
        }
        .foregroundStyle(Palette.accentSoft)
        .frame(width: 40, height: 40)
        .background(Palette.card, in: .circle)
        .overlay(Circle().stroke(Palette.accent, lineWidth: 1.5))
    }

    private func rule(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Palette.muted).frame(width: 20)
            Text(text).font(.system(size: 14)).foregroundStyle(Palette.soft).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if connected {
            Label("You and \(intro.name) are friends now.", systemImage: "person.2.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Palette.live)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
        } else if intro.saidHi {
            HStack(spacing: 10) {
                Circle().fill(Palette.accent).frame(width: 8, height: 8).opacity(pulse ? 1 : 0.4)
                Text("Hi sent. Waiting on \(intro.name).")
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Palette.accentSoft)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Palette.accent.opacity(0.12), in: .capsule)
            .overlay(Capsule().stroke(Palette.accent.opacity(0.4)))
        } else {
            HStack(spacing: 10) {
                Button("Say hi") { sayHi() }.buttonStyle(PrimaryButtonStyle())
                Button("Not now") { notNow() }.buttonStyle(SecondaryButtonStyle())
            }
            .disabled(busy)
        }
    }

    private func sayHi() {
        let here = location.center
        busy = true
        Task {
            await attempt($problem) { () throws(APIError) in
                connected = try await Sync.sayHi(intro, around: here, context: context)
            }
            busy = false
        }
    }

    private func notNow() {
        busy = true
        Task {
            await attempt($problem) { () throws(APIError) in
                try await Sync.notNow(intro, context: context)
                dismiss()
            }
            busy = false
        }
    }
}

/// The card on People (and the morning after) that opens it.
struct ThirdTimeRow: View {
    var intro: Intro
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                FriendAvatar(friend: intro.friend, size: 40, ring: .edge(Palette.accent), ground: Palette.card)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Third time's a friend").font(.system(size: 15, weight: .bold))
                        if intro.isSample { SampleTag() }
                    }
                    Text(intro.saidHi ? "Hi sent to \(intro.name). Waiting." : "You and \(intro.name) keep ending up at the same things.")
                        .font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .foregroundStyle(Palette.ink)
            .padding(14)
            .background(Palette.accent.opacity(0.08), in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.accent.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }
}
