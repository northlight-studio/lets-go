import SwiftUI
import SwiftData

/// The morning after: last night as a ribbon of where you were, with how little of it
/// was on the phone; hours out, who you were with, the walk, the stamps. Paper by day,
/// trail green if the phone is still dark; the hours out in yellow.
struct MorningAfterView: View {
    var night: Night
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var stamps: [Stamp]
    @Query(filter: #Predicate<Intro> { !$0.dismissed && !$0.saidHi }) private var intros: [Intro]
    @State private var openIntro: Intro?
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let paper = Palette.bg
    private let ink = Palette.ink
    private let gray = Palette.muted
    private let accent = Palette.accentSoft

    var body: some View {
        let end = max(night.lastActiveAt, (night.stops.map(\.arrivedAt).max() ?? night.startedAt).addingTimeInterval(3600))
        let out = end.timeIntervalSince(night.startedAt)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(Date.now.formatted(.dateTime.weekday(.wide))) \u{00B7} The morning after")
                            .eyebrow(accent)
                        Text("\(Text("\(night.evening.formatted(.dateTime.weekday(.wide))),\nlived"))\(Text(".").foregroundStyle(Palette.accent))")
                            .font(.system(size: 48, weight: .bold))
                            .tracking(-1)
                            .foregroundStyle(ink)
                    }
                    Spacer()
                    Button { close() } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(ink)
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Close")
                }
                ribbon(end: end, out: out).padding(.top, 22)
                tiles(out: out).padding(.top, 8)
                if let intro = intros.first {
                    ThirdTimeRow(intro: intro) { openIntro = intro }
                        .padding(.top, 8)
                }
                Text("\(Text("\u{2018}Live more.\u{2019}").foregroundStyle(accent)) Same time next week?")
                    .font(.quiet(21))
                    .foregroundStyle(Palette.soft)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 26)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(paper.ignoresSafeArea())
        .sheet(item: $openIntro) { ThirdTimeView(intro: $0).presentationBackground(Palette.bg) }
        .onAppear {
            if reduceMotion { grown = true } else { withAnimation(.timingCurve(0.3, 0.6, 0.2, 1, duration: 1.6).delay(0.2)) { grown = true } }
        }
    }

    private func ribbon(end: Date, out: TimeInterval) -> some View {
        let segments = NightMath.ribbon(stops: night.stops, start: night.startedAt, end: end)
        let glances = night.glances.map { max(0, min(1, $0.timeIntervalSince(night.startedAt) / max(out, 1))) }
        let places = Array(Set(night.stops.map(\.title))).sorted()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your night").font(.system(size: 13, weight: .semibold)).foregroundStyle(gray)
                Spacer()
                Text("\(Text("in Let's Go ").foregroundStyle(gray))\(Text("\(Int(night.phoneSeconds / 60)) min").fontWeight(.heavy).foregroundStyle(ink))\(Text(" of \(NightMath.duration(out))").foregroundStyle(gray))")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(Array(glances.enumerated()), id: \.offset) { _, g in
                        RoundedRectangle(cornerRadius: 1).fill(ink).frame(width: 2, height: 9).offset(x: w * g)
                    }
                    HStack(spacing: 2) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                            Rectangle()
                                .fill(seg.genre.map(\.color) ?? Palette.raise)
                                .frame(width: max(1, w * (seg.to - seg.from) - 2))
                        }
                    }
                    .frame(width: w, height: 20, alignment: .leading)
                    .clipShape(.rect(cornerRadius: 6))
                    .scaleEffect(x: grown ? 1 : 0, anchor: .leading)
                    .offset(y: 14)
                }
            }
            .frame(height: 34)
            .padding(.top, 22)
            HStack {
                Text(NightPin.hour(night.startedAt))
                Spacer()
                Text(HomeLine.clock(end))
            }
            .font(.system(size: 11.5, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(gray)
            .padding(.top, 8)
            FlowLayout(spacing: 14) {
                ForEach(places, id: \.self) { title in
                    let genre = night.stops.first(where: { $0.title == title })?.genre ?? .party
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(genre.color).frame(width: 8, height: 8)
                        Text(title)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.soft)
                }
            }
            .padding(.top, 10)
        }
        .padding(16)
        .card(radius: 24)
    }

    private func tiles(out: TimeInterval) -> some View {
        let people = Set(night.stops.flatMap(\.withNames))
        let tonightStamps = stamps.filter { night.startedAt <= $0.earnedAt && $0.earnedAt <= night.lastActiveAt.addingTimeInterval(3600) }.count
        let city = Spots.stamped(stamps).count
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            tile(NightMath.duration(out), "out in the world", dark: true)
            tile("\(people.count)", people.isEmpty ? "people you were with" : "with \(people.sorted().joined(separator: ", "))")
            tile("\(NightMath.miles(night.walkedMeters)) mi", "walked")
            tile("\(tonightStamps) stamp\(tonightStamps == 1 ? "" : "s")", "Know your city: now \(city) of \(Spots.all.count)")
        }
    }

    private func tile(_ value: String, _ caption: String, dark: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 36, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.system(size: 13)).foregroundStyle(dark ? Palette.onProminent.opacity(0.75) : gray).lineLimit(2)
        }
        .foregroundStyle(dark ? Palette.onProminent : ink)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(dark ? Palette.prominent : Palette.card, in: .rect(cornerRadius: 22))
    }

    private func close() {
        Ledger.sawRecap(night, context: context)
        dismiss()
    }
}
