import SwiftUI

/// The first thing you see, once: Dostoevsky's wish, a clause at a time, then
/// LIVE. MORE. and the way in. Passport → "Read the quote again" brings it back.
struct QuoteSplash: View {
    var onDone: () -> Void
    /// Shown as "A friend sent me an invite" when set.
    var onInvite: (() -> Void)? = nil

    /// How much is showing: 0 is nothing, then each clause, the attribution, the mark, the button.
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.bg.ignoresSafeArea()
            RadialGradient(
                colors: [Palette.accent.opacity(0.12), .clear],
                center: UnitPoint(x: 0.5, y: 0.95), startRadius: 10, endRadius: 520
            )
            .ignoresSafeArea()
            .opacity(step >= QuoteText.markStep ? 1 : 0)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 8, height: 8)
                        .shadow(color: Palette.accent.opacity(0.8), radius: 5)
                    Text("Let's Go")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.soft)
                }
                .padding(.top, 8)

                ZStack(alignment: .topLeading) {
                    Text("\u{201C}")
                        .font(.quiet(110))
                        .foregroundStyle(Palette.accent.opacity(0.9))
                        .offset(x: -6, y: -40)
                        .accessibilityHidden(true)
                    quote
                        .padding(.top, 34)
                }
                .padding(.top, 44)

                attribution
                    .padding(.top, 22)
                    .opacity(step >= QuoteText.attributionStep ? 1 : 0)

                Spacer(minLength: 20)

                LiveMoreMark(size: 76)
                    .opacity(step >= QuoteText.markStep ? 1 : 0)
                    .offset(y: step >= QuoteText.markStep ? 0 : 14)

                VStack(spacing: 14) {
                    Button("Let's go", action: onDone)
                        .buttonStyle(PrimaryButtonStyle())
                        .shadow(color: Palette.accent.opacity(0.35), radius: 15, y: 10)
                    if let onInvite {
                        Button("A friend sent me an invite", action: onInvite)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.soft)
                    }
                }
                .padding(.top, 22)
                .opacity(step >= QuoteText.buttonStep ? 1 : 0)
                .offset(y: step >= QuoteText.buttonStep ? 0 : 14)
                .allowsHitTesting(step >= QuoteText.buttonStep)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .contentShape(Rectangle())
        // A tap shows the rest at once, for anyone who's read it before.
        .onTapGesture { if step < QuoteText.buttonStep { withAnimation(.easeOut(duration: 0.4)) { step = QuoteText.buttonStep } } }
        .task { await reveal() }
    }

    private var quote: some View {
        let parts = QuoteText.clauses.enumerated().map { i, clause in
            Text(clause.text)
                .foregroundStyle((clause.isWish ? Palette.accentSoft : Palette.ink).opacity(step > i ? 1 : 0))
        }
        return parts.reduce(Text(verbatim: "")) { Text("\($0)\($1)") }
            .font(.quiet(29))
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.interpolate)
            .accessibilityLabel(QuoteText.full)
    }

    private var attribution: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Palette.soft).frame(width: 22, height: 1)
            Text("Fyodor Dostoevsky,")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.muted)
            Text("Demons")
                .font(.quiet(17))
                .foregroundStyle(Palette.soft)
        }
        .accessibilityElement(children: .combine)
    }

    private func reveal() async {
        if reduceMotion {
            step = QuoteText.buttonStep
            return
        }
        var elapsed = 0.0
        for (i, at) in QuoteText.times.enumerated() {
            try? await Task.sleep(for: .seconds(at - elapsed))
            elapsed = at
            if Task.isCancelled || step > i { continue }
            withAnimation(.easeOut(duration: i < QuoteText.clauses.count ? 1.2 : 0.9)) { step = i + 1 }
        }
    }
}

/// The words, exactly, and when each part appears.
enum QuoteText {
    struct Clause: Equatable, Sendable {
        var text: String
        var isWish = false
    }

    static let clauses: [Clause] = [
        Clause(text: "I do not wish you much happiness\u{2014}it would bore you; "),
        Clause(text: "I do not wish you trouble either; "),
        Clause(text: "but, following the people\u{2019}s philosophy, I will simply repeat: "),
        Clause(text: "\u{2018}Live more\u{2019} ", isWish: true),
        Clause(text: "and try somehow not to be too bored; "),
        Clause(text: "this useless wish I am adding on my own."),
    ]

    static let author = "Fyodor Dostoevsky"
    static let source = "Demons"

    /// Seconds after the splash opens: each clause, then the attribution, the mark, the button.
    static let times: [Double] = [0.5, 1.5, 2.5, 3.7, 4.6, 5.5, 6.4, 7.0, 7.5]

    static var attributionStep: Int { clauses.count + 1 }
    static var markStep: Int { clauses.count + 2 }
    static var buttonStep: Int { clauses.count + 3 }

    static var full: String { clauses.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
}
