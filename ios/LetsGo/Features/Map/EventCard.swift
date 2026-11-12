import SwiftUI

/// What you tapped, on a small glass card over the bottom of the map: the start time large in
/// the accent, the title, where and the walk and the price, "Then nearby" (the next thing
/// starting close by), and "I'm in" (ink, the one prominent button) with "Directions".
/// Flick it down to put it away. The words come from `Timetable`.
struct EventCard: View {
    var item: Candidate
    var now: Date
    /// The walk from a real route, when there is one.
    var walkMinutes: Int?
    var next: Candidate?
    var busy: Bool
    var onOpen: () -> Void
    var onJoin: () -> Void
    var onDirections: () -> Void
    var onNext: (Candidate) -> Void
    var onDismiss: () -> Void

    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Palette.muted.opacity(0.45))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 7)
                .padding(.bottom, 10)
                .accessibilityHidden(true)
            Button(action: onOpen) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Timetable.tag(item, now: now))
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                        .tracking(-0.6)
                        .foregroundStyle(Palette.accentSoft)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.headline)
                            .foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Timetable.cardLine(item, now: now, walkMinutes: walkMinutes))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens its page")

            if let next {
                Rectangle().fill(Palette.line).frame(height: 1).padding(.top, 12)
                Button { onNext(next) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Then nearby").foregroundStyle(Palette.muted)
                        Text(Timetable.tag(next, now: now))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(Palette.ink)
                        Text(Timetable.nearbyLine(next, from: item))
                            .foregroundStyle(Palette.soft)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.footnote)
                    .padding(.top, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                primary
                Button(action: onDirections) {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
                        .labelStyle(.titleOnly)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .foregroundStyle(Palette.ink)
            }
            .font(.body.weight(.semibold))
            .controlSize(.large)
            .padding(.top, 14)
            .sensoryFeedback(.success, trigger: item.isJoined)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
        .offset(y: drag)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { v in drag = max(0, v.translation.height) }
                .onEnded { v in
                    if v.translation.height > 60 || v.predictedEndTranslation.height > 160 {
                        onDismiss()
                    } else {
                        withAnimation(reduceMotion ? nil : .snappy) { drag = 0 }
                    }
                }
        )
        .onChange(of: item.id) { drag = 0 }
        .accessibilityAction(named: "Close") { onDismiss() }
    }

    @ViewBuilder
    private var primary: some View {
        switch item.kind {
        case .gathering:
            if item.isJoined {
                Button(action: onOpen) { Text("You're in").frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
                    .foregroundStyle(Palette.ink)
            } else {
                Button(action: onJoin) { Text(item.spotsLeft == 0 ? "Full" : "I'm in").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.prominent)
                    .foregroundStyle(Palette.onProminent)
                    .disabled(item.spotsLeft == 0 || busy)
            }
        case .drop:
            Button(action: onOpen) { Text("Reserve").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent)
                .tint(Palette.prominent)
                .foregroundStyle(Palette.onProminent)
        }
    }
}
