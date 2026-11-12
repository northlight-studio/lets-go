import SwiftUI

/// Signal's panel: the three things worth leaving for, when to leave for each, and a
/// ruler of the next five hours. Drag along the ruler to see what's on later.
struct SignalPanel: View {
    var top: [Candidate]
    var total: Int
    /// The real time, for the ruler.
    var now: Date
    /// The time the map is showing (now, or later along the ruler).
    var at: Date
    var walkMinutes: [UUID: Int]
    @Binding var ahead: Double
    var onOpen: (Candidate) -> Void
    var onList: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("WORTH LEAVING FOR")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.8)
                    .foregroundStyle(SignalPalette.muted)
                Spacer()
                Button("All \(total)", action: onList)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SignalPalette.ink)
            }
            if top.isEmpty {
                Text(ahead > 0 ? "Nothing worth the walk around then." : "Nothing worth the walk in the next few hours.")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SignalPalette.ink)
                    .padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { i, c in
                        row(i, c)
                        if i < top.count - 1 { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }
                    }
                }
                .padding(.top, 6)
            }
            SignalRuler(top: top, now: now, ahead: $ahead)
                .padding(.top, 10)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .glassEffect(.regular.tint(SignalPalette.panel), in: .rect(cornerRadius: 30))
    }

    private func row(_ i: Int, _ c: Candidate) -> some View {
        let minutes = walkMinutes[c.id] ?? c.walkMinutes
        let leave = HomeLine.leaveBy(c, now: at, walkMinutes: minutes)
        return Button { onOpen(c) } label: {
            HStack(spacing: 12) {
                Text("\(i + 1)")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(SignalPalette.bg)
                    .frame(width: 24, height: 24)
                    .background(SignalPalette.lime, in: .rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.title)
                        .font(.system(size: 16, weight: .bold))
                        .tracking(-0.2)
                        .lineLimit(1)
                    Text(Signal.detail(c, now: at))
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(SignalPalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(leave <= at ? "LEAVE" : "LEAVE BY")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(SignalPalette.muted)
                    Text(leave <= at ? "NOW" : NightPin.hour(leave))
                        .font(.system(size: 20, weight: .heavy))
                        .tracking(-0.4)
                        .monospacedDigit()
                        .foregroundStyle(i == 0 ? SignalPalette.lime : SignalPalette.ink)
                }
            }
            .foregroundStyle(SignalPalette.ink)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(i + 1), \(c.title). \(leave <= at ? "Leave now" : "Leave by \(HomeLine.clock(leave))").")
    }
}

/// Now to five hours on, with a tick per hour and a mark per pick. Drag to look ahead.
struct SignalRuler: View {
    var top: [Candidate]
    var now: Date
    @Binding var ahead: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 8
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white.opacity(0.22)).frame(width: w, height: 1).offset(x: 4, y: 14)
                ForEach(Signal.hourTicks(now: now), id: \.self) { tick in
                    if let p = Signal.position(of: tick, now: now) {
                        Rectangle().fill(Color.white.opacity(0.4)).frame(width: 1, height: 10).offset(x: 4 + w * p, y: 9)
                        // Leave room for the NOW label at the left end.
                        Text(p < 0.1 ? "" : label(tick))
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(SignalPalette.muted)
                            .fixedSize()
                            .offset(x: max(0, 4 + w * p - 4), y: 24)
                    }
                }
                ForEach(top) { c in
                    if let p = Signal.position(of: c.start, now: now) {
                        let later = c.start.timeIntervalSince(now) > 90 * 60
                        RoundedRectangle(cornerRadius: 2)
                            .fill(later ? Color(hex: 0x121212) : SignalPalette.lime)
                            .frame(width: 6, height: 6)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(later ? SignalPalette.muted : SignalPalette.lime, lineWidth: 1.5))
                            .offset(x: 4 + w * p - 3, y: 11)
                    }
                }
                // Where the map is looking: now, or later.
                RoundedRectangle(cornerRadius: 1)
                    .fill(SignalPalette.lime)
                    .frame(width: 2, height: 22)
                    .offset(x: 4 + w * CGFloat(ahead / Signal.span) - 1, y: 4)
                Text(ahead == 0 ? "NOW" : "+\(aheadLabel)")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(SignalPalette.lime)
                    .fixedSize()
                    .offset(x: min(w - 30, max(0, 4 + w * CGFloat(ahead / Signal.span) - 8)), y: 24)
            }
            .frame(width: geo.size.width, height: 44, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = min(1, max(0, (v.location.x - 4) / max(w, 1)))
                // Quarter hours, so the pins don't flicker while you drag.
                ahead = (Double(f) * Signal.span * 4).rounded() / 4
            })
        }
        .frame(height: 44)
        .sensoryFeedback(.selection, trigger: ahead)
        .accessibilityElement()
        .accessibilityLabel("Look ahead")
        .accessibilityValue(ahead == 0 ? "Now" : "\(aheadLabel) from now")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: ahead = min(Signal.span, ahead + 0.5)
            case .decrement: ahead = max(0, ahead - 0.5)
            @unknown default: break
            }
        }
    }

    private var aheadLabel: String {
        let minutes = Int(ahead * 60)
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    private func label(_ d: Date) -> String {
        let hour = Calendar.current.component(.hour, from: d)
        if hour == 0 { return "12 AM" }
        return d.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)))
    }
}
