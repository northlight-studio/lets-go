import SwiftUI

/// The slim glass bar at the bottom of the map: how many things are in the window and how
/// late it looks ("14 things", "Today · until 8"), over the hours from now to late, with a
/// thumb you drag. Tap the header to look at tomorrow or the weekend. The map shows only
/// what starts before the thumb. Everything it shows is worked out by `Timetable`.
struct TimeRail: View {
    struct Option: Hashable {
        var day: Date
        var label: String
    }

    var count: Int
    var span: ClosedRange<Date>
    var until: Date
    var ticks: [Timetable.Tick]
    /// The days you can switch to, with their names ("Today", "Tomorrow", "Saturday").
    var days: [Option]
    var day: Date
    var onDay: (Date) -> Void
    var onUntil: (Date) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dayLabel: String { days.first { $0.day == day }?.label ?? "Today" }
    private var fraction: Double { Timetable.fraction(of: until, in: span) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            GeometryReader { geo in
                let w = max(1, geo.size.width)
                VStack(alignment: .leading, spacing: 5) {
                    tickLabels(width: w)
                    track(width: w)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let next = Timetable.until(at: Double(v.location.x / w), in: span)
                    if next != until { onUntil(next) }
                })
            }
            .frame(height: tickHeight + 5 + 18)
            .accessibilityElement()
            .accessibilityLabel("How late to look")
            .accessibilityValue(Timetable.untilLine(until, span: span))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onUntil(min(span.upperBound, until.addingTimeInterval(Timetable.step)))
                case .decrement: onUntil(max(span.lowerBound.addingTimeInterval(Timetable.step), until.addingTimeInterval(-Timetable.step)))
                @unknown default: break
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .sensoryFeedback(.selection, trigger: until)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    @ScaledMetric(relativeTo: .caption2) private var tickHeight: CGFloat = 13

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Timetable.countLine(count))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
            Spacer(minLength: 4)
            Menu {
                Picker("Day", selection: Binding(get: { day }, set: { onDay($0) })) {
                    ForEach(days, id: \.day) { d in Text(d.label).tag(d.day) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(dayLabel) \u{00B7} \(Timetable.untilLine(until, span: span))")
                        .monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .imageScale(.small)
                }
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Day: \(dayLabel)")
            .accessibilityHint("Look at another day")
        }
    }

    private func tickLabels(width w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(ticks.filter { $0.label != nil }, id: \.date) { t in
                let f = CGFloat(t.fraction)
                let isFirst = f == 0
                let isLast = f >= 0.999
                Text(t.label ?? "")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(t.date <= until ? Palette.ink : Palette.faint)
                    .fixedSize()
                    .frame(width: 44, alignment: isFirst ? .leading : isLast ? .trailing : .center)
                    .offset(x: isFirst ? 0 : (isLast ? w - 44 : w * f - 22))
            }
        }
        .frame(width: w, height: tickHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func track(width w: CGFloat) -> some View {
        let x = w * CGFloat(fraction)
        return ZStack(alignment: .leading) {
            Capsule().fill(Palette.ink.opacity(0.12)).frame(height: 3)
            Capsule().fill(Palette.ink).frame(width: max(3, x), height: 3)
            ForEach(ticks, id: \.date) { t in
                Rectangle()
                    .fill(Palette.ink.opacity(t.date <= until ? 0 : 0.18))
                    .frame(width: 1, height: 5)
                    .offset(x: w * CGFloat(t.fraction) - 0.5)
            }
            Circle()
                .fill(Palette.knob)
                .frame(width: 18, height: 18)
                .shadow(color: Palette.shadow, radius: 2, y: 1)
                .overlay(Circle().stroke(Palette.line, lineWidth: 0.5))
                .offset(x: min(w - 18, max(0, x - 9)))
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: until)
        }
        .frame(width: w, height: 18)
        .accessibilityHidden(true)
    }
}
