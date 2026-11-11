import SwiftUI

/// Drawn stand-ins for photos: a little scene per kind of place, and a ringed
/// badge per kind of gathering. Seeded by name, so the same thing always looks the same.
enum Art {
    /// 0..<1 from a string, stable across launches (unlike `hashValue`).
    static func unit(_ s: String, _ salt: Int) -> Double {
        var h: UInt64 = 14_695_981_039_346_656_037 &+ UInt64(salt)
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        return Double(h % 1000) / 1000
    }

    /// The ground under a gathering's art: a pale wash of its colour by day, deep after dark.
    static func ground(_ genre: Genre) -> Color {
        switch genre {
        case .music: Color(light: 0xF8E3D6, dark: 0x3A2418)
        case .food: Color(light: 0xDDEFE3, dark: 0x16301F)
        case .play, .move, .party: Color(light: 0xDDE7F5, dark: 0x16283A)
        }
    }

    static func ground(_ kind: Spot.Kind) -> Color {
        switch kind {
        case .hike: Color(hex: 0x173230)
        case .view: Color(hex: 0x2B3A52)
        case .water: Color(hex: 0x1C2C44)
        case .park: Color(hex: 0x1A2C22)
        case .landmark: Color(hex: 0x2A2236)
        case .culture: Color(hex: 0x2E2032)
        case .food: Color(hex: 0x3A2418)
        case .night: Color(hex: 0x1B1F3A)
        }
    }
}

/// A gathering's art: its symbol in rings, off to one side.
struct GenreArt: View {
    var genre: Genre
    var seed: String = ""

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let x = w * (0.55 + 0.3 * Art.unit(seed, 1)), y = h * (0.4 + 0.2 * Art.unit(seed, 2))
            ZStack {
                Art.ground(genre)
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .stroke(genre.color.opacity(0.4 - Double(i) * 0.08), lineWidth: 1.5)
                        .frame(width: CGFloat(70 + i * 60), height: CGFloat(70 + i * 60))
                        .position(x: x, y: y)
                }
                Circle().fill(genre.color).frame(width: 56, height: 56).position(x: x, y: y)
                Image(systemName: genre.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .position(x: x, y: y)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// A place's art: a trail over contour lines, a sun on the water, a skyline, a plate, a night sky.
struct SpotArt: View {
    var spot: Spot

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Art.ground(spot.kind)
                switch spot.kind {
                case .hike, .park: trail(w, h)
                case .view, .water: horizon(w, h)
                case .landmark, .culture: skyline(w, h)
                case .food: plate(w, h)
                case .night: night(w, h)
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func k(_ salt: Int) -> CGFloat { CGFloat(Art.unit(spot.id, salt)) }

    private func trail(_ w: CGFloat, _ h: CGFloat) -> some View {
        let line = spot.kind.color
        return ZStack {
            ForEach(0..<4, id: \.self) { i in
                Ellipse()
                    .stroke(line.opacity(0.25), lineWidth: 1.5)
                    .frame(width: w * (0.35 + 0.25 * CGFloat(i)), height: h * (0.3 + 0.22 * CGFloat(i)))
                    .position(x: w * (0.4 + 0.2 * k(1)), y: h * 0.55)
            }
            Path { p in
                p.move(to: CGPoint(x: w * 0.08, y: h * 0.9))
                p.addCurve(
                    to: CGPoint(x: w * 0.86, y: h * 0.24),
                    control1: CGPoint(x: w * 0.4, y: h * (0.5 + 0.4 * k(2))),
                    control2: CGPoint(x: w * 0.55, y: h * (0.1 + 0.3 * k(3)))
                )
            }
            .stroke(line, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 7]))
            Circle().fill(line).frame(width: 10, height: 10).position(x: w * 0.86, y: h * 0.24)
        }
    }

    private func horizon(_ w: CGFloat, _ h: CGFloat) -> some View {
        let sun = Palette.star
        let sea = h * 0.62
        return ZStack {
            Circle().fill(sun.opacity(0.14)).frame(width: h * 0.62, height: h * 0.62).position(x: w * (0.5 + 0.25 * k(1)), y: sea)
            Circle().fill(sun).frame(width: h * 0.38, height: h * 0.38).position(x: w * (0.5 + 0.25 * k(1)), y: sea)
            Rectangle()
                .fill(Color(hex: 0x1C2C44))
                .frame(width: w, height: h - sea)
                .position(x: w / 2, y: sea + (h - sea) / 2)
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(sun.opacity(0.45 - Double(i) * 0.08))
                    .frame(width: w * (0.42 - 0.08 * CGFloat(i)), height: 2)
                    .position(x: w * (0.5 + 0.25 * k(1)), y: sea + 10 + CGFloat(i) * 11)
            }
            Path { p in
                p.move(to: CGPoint(x: 0, y: h * (0.55 + 0.1 * k(2))))
                p.addQuadCurve(to: CGPoint(x: w * 0.38, y: h), control: CGPoint(x: w * 0.2, y: h * 0.6))
                p.addLine(to: CGPoint(x: 0, y: h))
                p.closeSubpath()
            }
            .fill(Color(hex: 0x0E1318))
        }
    }

    private func skyline(_ w: CGFloat, _ h: CGFloat) -> some View {
        let tint = spot.kind.color
        return ZStack(alignment: .bottom) {
            Circle().fill(tint.opacity(0.5)).frame(width: h * 0.22, height: h * 0.22).position(x: w * (0.15 + 0.7 * k(9)), y: h * 0.26)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<7, id: \.self) { i in
                    UnevenRoundedRectangle(topLeadingRadius: i % 2 == 0 ? 14 : 3, topTrailingRadius: i % 2 == 0 ? 14 : 3)
                        .fill(tint.opacity(0.22 + 0.1 * Double(i % 3)))
                        .frame(height: h * (0.3 + 0.45 * k(i + 10)))
                }
            }
            .padding(.horizontal, 10)
            .frame(width: w, height: h, alignment: .bottom)
        }
    }

    private func plate(_ w: CGFloat, _ h: CGFloat) -> some View {
        let tint = spot.kind.color
        let x = w * (0.45 + 0.2 * k(1)), y = h * 0.55
        return ZStack {
            Circle().fill(Color(hex: 0xE3A15B)).frame(width: h * 0.7, height: h * 0.7).position(x: x, y: y)
            Circle().fill(tint).frame(width: h * 0.54, height: h * 0.54).position(x: x, y: y)
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(Color(hex: 0xF3E3C3))
                    .frame(width: h * 0.08, height: h * 0.08)
                    .position(x: x + h * 0.18 * (k(i + 2) - 0.5) * 2, y: y + h * 0.18 * (k(i + 7) - 0.5) * 2)
            }
        }
    }

    private func night(_ w: CGFloat, _ h: CGFloat) -> some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(0.5 + 0.4 * Double(k(i + 20))))
                    .frame(width: 2.5, height: 2.5)
                    .position(x: w * k(i + 1), y: h * 0.6 * k(i + 40))
            }
            Circle().fill(Palette.star).frame(width: h * 0.26, height: h * 0.26).position(x: w * 0.72, y: h * 0.3)
            Circle().fill(Art.ground(.night)).frame(width: h * 0.24, height: h * 0.24).position(x: w * 0.76, y: h * 0.27)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<9, id: \.self) { i in
                    Rectangle()
                        .fill(Color(hex: 0x11142A))
                        .frame(height: h * (0.15 + 0.3 * k(i + 60)))
                        .overlay(alignment: .top) {
                            Rectangle().fill(Palette.star.opacity(0.6)).frame(width: 3, height: 3).padding(.top, 6)
                        }
                }
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
    }
}
