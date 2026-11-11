import SwiftUI

/// A ring that grows and fades out from a pin, over and over. Pass a shorter period
/// as the thing fills up; give the view an `.id(period)` so a new speed restarts it.
struct PulseRing: View {
    var color: Color
    var size: CGFloat
    var period: Double
    var delay: Double = 0
    var square = false
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ring
            .frame(width: size, height: size)
            .scaleEffect(on ? 2.6 : 1)
            .opacity(reduceMotion ? 0 : (on ? 0 : 0.8))
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.timingCurve(0.2, 0.6, 0.3, 1, duration: period).repeatForever(autoreverses: false).delay(delay)) {
                    on = true
                }
            }
    }

    @ViewBuilder
    private var ring: some View {
        if square {
            RoundedRectangle(cornerRadius: 5).stroke(color, lineWidth: 1.5)
        } else {
            Circle().stroke(color, lineWidth: 1.5)
        }
    }
}

/// A pin on the map: a small disc in its kind's colour with its glyph, a white rim and a
/// soft halo, a count on its shoulder, and for the top few, a caption underneath. It
/// pulses while it fills. Wren's pick is yellow with a flag.
struct NightPin: View {
    var pick: Candidate
    var size: CGFloat
    var now: Date
    var showsCaption: Bool
    var picked = false

    var body: some View {
        let color = picked ? Palette.accent : pick.category.color
        ZStack {
            if let period = HomeLine.pulsePeriod(pick) {
                PulseRing(color: color, size: size, period: period).id(period)
                if HomeLine.isFillingFast(pick) {
                    PulseRing(color: color, size: size, period: period, delay: period / 2).id(period + 0.001)
                }
            }
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: size * 1.5, height: size * 1.5)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Palette.card, lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            Image(systemName: picked ? "flag.fill" : pick.category.symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(picked ? Palette.accentInk : pick.category.ink)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if let badge = HomeLine.badge(pick) {
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(pick.category.light)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Palette.card, in: .capsule)
                    .overlay(Capsule().stroke(color, lineWidth: 1.5))
                    .fixedSize()
                    .offset(x: size * 0.55, y: -size * 0.55)
            }
        }
        .overlay(alignment: .top) {
            if showsCaption {
                HStack(spacing: 4) {
                    Text(HomeLine.caption(pick)).fontWeight(.semibold)
                    Text(timeLabel).fontWeight(.medium).foregroundStyle(Palette.muted)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Palette.card.opacity(0.92), in: .rect(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
                .fixedSize()
                .offset(y: size + 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var timeLabel: String {
        pick.start <= now ? "till \(Self.hour(pick.end))" : Self.hour(pick.start)
    }

    /// "8:00", "7:30": the map has no room for AM and PM.
    static func hour(_ d: Date) -> String {
        d.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
    }

    private var accessibility: String {
        var parts = [pick.title, pick.start <= now ? "on now" : "at \(HomeLine.clock(pick.start))"]
        if let badge = HomeLine.badge(pick) { parts.append(badge) }
        if picked { parts.append("Wren's pick") }
        if pick.isSample { parts.append("sample") }
        return parts.joined(separator: ", ")
    }
}

/// Signal's pin: a lime square with its rank, and the walk in minutes under it.
struct SignalPin: View {
    var number: Int
    var minutes: Int?
    var title: String

    var body: some View {
        ZStack {
            PulseRing(color: SignalPalette.lime, size: 24, period: 2.2, delay: Double(number - 1) * 0.7, square: true)
            RoundedRectangle(cornerRadius: 7)
                .fill(SignalPalette.lime)
                .frame(width: 26, height: 26)
            Text("\(number)")
                .font(.system(size: 14, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(SignalPalette.bg)
        }
        .frame(width: 26, height: 26)
        .overlay(alignment: .top) {
            if let minutes {
                Text("\(minutes) MIN")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.6)
                    .monospacedDigit()
                    .foregroundStyle(SignalPalette.lime)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SignalPalette.bg, in: .rect(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(SignalPalette.lime, lineWidth: 1))
                    .fixedSize()
                    .offset(y: 32)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number), \(title)\(minutes.map { ", \($0) minute walk" } ?? "")")
    }
}

/// Everything else in Signal: a small white square, hollow when it's later.
struct SignalDot: View {
    var later: Bool

    var body: some View {
        Rectangle()
            .fill(later ? SignalPalette.bg : SignalPalette.ink)
            .frame(width: 8, height: 8)
            .overlay(Rectangle().stroke(later ? SignalPalette.muted : SignalPalette.ink, lineWidth: 1.5))
            .padding(8)
            .contentShape(Rectangle())
    }
}

/// Wren's mark: a yellow disc with a four-point spark.
struct WrenOrb: View {
    var size: CGFloat = 26
    var glows = true

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(Palette.accentInk)
            .frame(width: size, height: size)
            .background(Palette.accent, in: .circle)
            .shadow(color: glows ? Palette.accent.opacity(0.35) : .clear, radius: size * 0.3)
            .accessibilityHidden(true)
    }
}
