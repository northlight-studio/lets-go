import SwiftUI

/// The lamppost poster, laid out at the paper's real size in points. Off-white paper, near-black ink,
/// the app's orange: when it's on, the big title, the line, the QR code, and tear-off tabs with the link.
struct PosterView: View {
    var content: PosterContent
    var paper: PosterPaper
    /// The preview shows the off-white paper; the PDF leaves the page unprinted so the paper is the paper.
    var fillsPaper = true

    static let paperColor = Color(hex: 0xF6F2EA)
    static let ink = Color(hex: 0x16141B)

    private var size: CGSize { paper.size }
    private let margin: CGFloat = 40
    private let tabHeight: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            sheet
                .frame(width: size.width, height: size.height - tabHeight, alignment: .topLeading)
            tabs
        }
        .frame(width: size.width, height: size.height)
        .background(fillsPaper ? Self.paperColor : .white)
        .environment(\.colorScheme, .light)
    }

    /// Everything above the tabs.
    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(content.when)
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(1.5)
                    .foregroundStyle(Palette.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(content.title)
                    .font(.poster(112))
                    .tracking(-1)
                    .foregroundStyle(Self.ink)
                    .lineLimit(3)
                    .minimumScaleFactor(0.35)
                    .fixedSize(horizontal: false, vertical: true)
                Text(content.line)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Self.ink)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 20)
            HStack(alignment: .center, spacing: 26) {
                QRCodeShape(text: content.url)
                    .fill(Self.ink)
                    .frame(width: 190, height: 190)
                VStack(alignment: .leading, spacing: 8) {
                    Text(PosterCopy.scanLead)
                        .font(.system(size: 26, weight: .heavy))
                    Text(PosterCopy.scanRest)
                        .font(.system(size: 18))
                    Text(content.shortText)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.top, 4)
                }
                .foregroundStyle(Self.ink)
            }
            HStack {
                Spacer()
                Text("Let's Go").font(.poster(14)).foregroundStyle(Self.ink.opacity(0.55))
            }
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .padding([.horizontal, .top], margin)
    }

    /// The tear-off row: a dashed cut line, then tabs each with the title and the link, sideways.
    private var tabs: some View {
        let width = size.width / CGFloat(content.tabs)
        return VStack(spacing: 0) {
            DashedLine().stroke(Self.ink.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .frame(height: 1)
            HStack(spacing: 0) {
                ForEach(0..<content.tabs, id: \.self) { i in
                    tab(width: width)
                    if i < content.tabs - 1 {
                        DashedLine(vertical: true).stroke(Self.ink.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .frame(width: 1)
                    }
                }
            }
        }
        .frame(width: size.width, height: tabHeight)
    }

    private func tab(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(content.title)
                .font(.system(size: 12, weight: .heavy))
                .lineLimit(1)
            Text(content.shortText)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .foregroundStyle(Self.ink)
        .frame(width: tabHeight - 16, height: width - 8, alignment: .leading)
        .rotationEffect(.degrees(-90))
        .frame(width: width - 1, height: tabHeight)
    }
}

/// A dashed cut line along one edge of its frame.
nonisolated struct DashedLine: Shape {
    var vertical = false

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if !vertical {
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        } else {
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        return p
    }
}

/// A QR code drawn as squares, so it prints sharp at any size.
nonisolated struct QRCodeShape: Shape {
    var modules: [[Bool]]

    init(text: String) {
        modules = QRMatrix.modules(for: text) ?? []
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let n = modules.count
        guard n > 0 else { return p }
        let side = min(rect.width, rect.height) / CGFloat(n)
        // One rectangle per run of dark modules in a row, so there are fewer seams between squares.
        for (y, row) in modules.enumerated() {
            var x = 0
            while x < row.count {
                guard row[x] else { x += 1; continue }
                let start = x
                while x < row.count, row[x] { x += 1 }
                p.addRect(CGRect(x: rect.minX + CGFloat(start) * side, y: rect.minY + CGFloat(y) * side,
                                 width: CGFloat(x - start) * side, height: side))
            }
        }
        return p
    }
}
