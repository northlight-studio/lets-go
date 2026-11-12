import SwiftUI
import SwiftData

/// What a check-in shows: you're here. A clock of how long you've been out tonight, who's
/// with you, how far you've walked and how little you've been on the phone, and a way to
/// go dark until later.
struct HereMoment: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var genre: Genre
    var checkedInAt: Date
    var friends: [Friend]
    var stamped: Bool
}

struct YouAreHereView: View {
    var moment: HereMoment
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(HomeModel.self) private var model
    @Query(sort: \Night.evening, order: .reverse) private var nights: [Night]
    @State private var breathe = false
    @State private var darkUntil: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = timeline.date
            let night = nights.first { $0.evening == NightMath.evening(of: now) }
            ZStack {
                Palette.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 12)
                    rings(now: now, night: night)
                    Text("Put it away. Wren\u{2019}s holding everything else.")
                        .font(.quiet(27))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.top, 18)
                    Spacer(minLength: 12)
                    tiles(night)
                    darkButton(now: now)
                        .padding(.top, 18)
                    Text("Lock the phone whenever you like. The clock keeps going.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .padding(.top, 12)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                if let darkUntil, darkUntil > now {
                    dark(until: darkUntil, now: now, night: night)
                        .transition(.opacity)
                }
            }
        }
        .statusBarHidden(darkUntil != nil)
        .onAppear {
            darkUntil = nights.first?.darkUntil.flatMap { $0 > .now ? $0 : nil }
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { breathe = true }
        }
        .onChange(of: darkUntil) { _, until in model.dark = until != nil }
        // When "Go dark" runs out, the screen comes all the way back (status bar too).
        .task(id: darkUntil) {
            guard let until = darkUntil else { return }
            do { try await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow))) } catch { return }
            withAnimation(.easeInOut(duration: 0.6)) { darkUntil = nil }
        }
        .onDisappear { model.dark = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: moment.genre.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(moment.genre.color)
                .frame(width: 38, height: 38)
                .background(moment.genre.color.opacity(0.1), in: .circle)
                .overlay(Circle().strokeBorder(moment.genre.color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                .rotationEffect(.degrees(-8))
            VStack(alignment: .leading, spacing: 1) {
                Text(moment.title).font(.system(size: 14, weight: .bold))
                Text("Checked in \(HomeLine.clock(moment.checkedInAt))\(moment.stamped ? " \u{00B7} stamp collected" : "")")
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.top, 8)
    }

    private func rings(now: Date, night: Night?) -> some View {
        let out = now.timeIntervalSince(night?.startedAt ?? moment.checkedInAt)
        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Palette.accent.opacity(0.22 + 0.19 * Double(i)), lineWidth: i == 2 ? 1.5 : 1)
                    .frame(width: CGFloat(300 - i * 56), height: CGFloat(300 - i * 56))
                    .scaleEffect(breathe ? 1.04 : 0.94)
                    .opacity(breathe ? 1 : 0.4)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 3).repeatForever(autoreverses: true).delay(Double(i) * 0.5), value: breathe)
            }
            Circle().fill(Palette.accent.opacity(0.06)).frame(width: 190, height: 190).blur(radius: 30)
            VStack(spacing: 6) {
                Text("You're here.").font(.system(size: 46, weight: .bold))
                Text(NightMath.clock(out))
                    .font(.system(size: 40, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(Palette.accentSoft)
                    .contentTransition(.numericText())
                Text("Out in the world tonight")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(height: 300)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You're here. Out for \(NightMath.duration(out)) tonight.")
    }

    private func tiles(_ night: Night?) -> some View {
        let first = night?.stops.first?.arrivedAt ?? moment.checkedInAt
        return HStack(spacing: 8) {
            tile {
                if moment.friends.isEmpty {
                    Image(systemName: "person.2").font(.system(size: 20)).foregroundStyle(Palette.muted).frame(height: 26)
                } else {
                    AvatarStack(friends: moment.friends, size: 26, ground: Palette.card)
                }
            } caption: {
                moment.friends.isEmpty ? "Say hi to whoever's here" : "\(Crowd.names(moment.friends))"
            }
            tile {
                number(NightMath.miles(night?.walkedMeters ?? 0), "mi")
            } caption: { "walked since \(NightPin.hour(first))" }
            tile {
                number("\(Int((night?.phoneSeconds ?? 0) / 60))", "min")
            } caption: { "in Let's Go tonight" }
        }
    }

    private func number(_ value: String, _ unit: String) -> some View {
        Text("\(Text(value).font(.system(size: 24, weight: .bold))) \(Text(unit).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted))")
            .monospacedDigit()
            .frame(height: 26)
    }

    private func tile<Top: View>(@ViewBuilder _ top: () -> Top, caption: () -> String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            top()
            Text(caption()).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Palette.card, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line))
    }

    private func darkButton(now: Date) -> some View {
        let until = NightMath.darkUntil(from: now)
        return Button { goDark(until) } label: {
            HStack(spacing: 12) {
                Image(systemName: "moon.fill").font(.system(size: 18)).foregroundStyle(Palette.accentSoft)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Go dark until \(NightPin.hour(until))").font(.system(size: 16, weight: .bold))
                    Text(moment.friends.isEmpty ? "Let's Go stays quiet till then" : "Let's Go stays quiet; \(Crowd.names(moment.friends)) can still find you here")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.onProminent)
                    .frame(width: 44, height: 44)
                    .background(Palette.prominent, in: .circle)
            }
            .padding(.leading, 22)
            .padding(.trailing, 10)
            .frame(height: 64)
            .background(Palette.accent.opacity(0.1), in: .capsule)
            .overlay(Capsule().stroke(Palette.accent.opacity(0.4)))
        }
        .buttonStyle(.plain)
    }

    private func dark(until: Date, now: Date, night: Night?) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 26) {
                ZStack {
                    Circle().stroke(Palette.accent.opacity(0.35), lineWidth: 1).frame(width: 200, height: 200)
                        .scaleEffect(breathe ? 1.04 : 0.94)
                    Text(NightMath.clock(now.timeIntervalSince(night?.startedAt ?? moment.checkedInAt)))
                        .font(.system(size: 30, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(Palette.accent.opacity(0.5))
                }
                Text("Dark until \(NightPin.hour(until))")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.faint)
                Button("Wake") { goDark(nil) }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .overlay(Capsule().stroke(Color.white.opacity(0.15)))
            }
        }
        // Black whatever the phone's appearance: this is the phone off.
        .environment(\.colorScheme, .dark)
    }

    private func goDark(_ until: Date?) {
        withAnimation(.easeInOut(duration: 0.6)) { darkUntil = until }
        Ledger.goDark(until: until, context: context)
    }
}
