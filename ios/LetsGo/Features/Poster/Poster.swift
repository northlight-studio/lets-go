import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Paper the poster prints on, in PDF points (1/72 inch).
enum PosterPaper: String, CaseIterable, Identifiable {
    case letter, a4

    var id: String { rawValue }
    var label: String { self == .letter ? "Letter" : "A4" }
    var size: CGSize { self == .letter ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89) }

    /// Letter where people use inches, A4 everywhere else.
    static func local(_ locale: Locale = .current) -> PosterPaper {
        locale.measurementSystem == .us ? .letter : .a4
    }
}

/// What goes on the paper, worked out from a gathering so the view only lays it out.
struct PosterContent: Equatable {
    var when: String
    var title: String
    var line: String
    var url: String
    var shortText: String
    var tabs: Int = 8
}

/// The poster's words and rules. A poster is only for a real gathering you host:
/// never someone else's, never a listing, and only one the server knows (the link lives there).
enum PosterCopy {
    static let scanLead = "Scan to say you're in."
    static let scanRest = "No app needed. See who's coming and how many spots are left."

    /// Why there's no poster for this, or nil when there can be one.
    static func unavailable(_ g: Gathering, now: Date) -> String? {
        if g.isListing || !g.isMine { return "Only the host can make its poster." }
        if g.hasEnded(at: now) { return "It's over." }
        if g.remoteID == nil { return "Posters need the server, and this one is only on your phone." }
        return nil
    }

    /// "Every Thursday" (any case, a trailing s) — the same rule the server uses to carry the
    /// poster's link on to next week's.
    static func isWeekly(_ recurring: String) -> Bool {
        let words = recurring.lowercased().split(separator: " ")
        guard words.count == 2, words[0] == "every" else { return false }
        let day = words[1].hasSuffix("s") ? String(words[1].dropLast()) : String(words[1])
        return englishWeekdays.map { $0.lowercased() }.contains(day)
    }

    /// "Every Thursday" for a start date, in English like the server expects.
    static func weekly(from start: Date, calendar: Calendar = .current) -> String {
        "Every \(englishWeekdays[calendar.component(.weekday, from: start) - 1])"
    }

    /// The accent line on top: "EVERY THURSDAY · 6:30" or "SAT, NOV 14 · 8:00 AM".
    static func when(_ g: Gathering, calendar: Calendar = .current) -> String {
        let time = clock(g.start, calendar: calendar)
        if isWeekly(g.recurring) {
            return "Every \(englishWeekdays[calendar.component(.weekday, from: g.start) - 1]) · \(time)".uppercased()
        }
        let c = calendar.dateComponents([.weekday, .month, .day], from: g.start)
        let day = String(englishWeekdays[(c.weekday ?? 1) - 1].prefix(3))
        let month = String(englishMonths[(c.month ?? 1) - 1].prefix(3))
        return "\(day), \(month) \(c.day ?? 1) · \(time)".uppercased()
    }

    /// "6:30" in the evening (a poster's default), "8:00 AM" in the morning.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let h24 = c.hour ?? 0
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        let base = "\(h12):" + String(format: "%02d", c.minute ?? 0)
        return h24 < 12 ? "\(base) AM" : base
    }

    /// The line under the title: "The park on Elm St. Bring water. All levels."
    static func line(_ g: Gathering, limit: Int = 140) -> String {
        let parts = [g.placeName, g.bring.isEmpty ? "" : "Bring \(g.bring)", g.details]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ") }
            .filter { !$0.isEmpty }
            .map { (part: String) -> String in
                guard let last = part.last, ".!?".contains(last) else { return part + "." }
                return part
            }
        let text = parts.joined(separator: " ")
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let lastSpace = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<lastSpace]) + "…"
    }

    /// Everything on the paper. Nil until the poster has a link.
    static func content(_ g: Gathering, calendar: Calendar = .current) -> PosterContent? {
        guard let url = g.posterURL, let short = g.posterShortText else { return nil }
        return PosterContent(when: when(g, calendar: calendar), title: g.title, line: line(g), url: url, shortText: short)
    }

    private static let posix: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    static let englishWeekdays = posix.weekdaySymbols
    static let englishMonths = posix.monthSymbols
}

/// A QR code as a grid of dark modules, so it can be drawn as vector squares that stay sharp on paper.
nonisolated enum QRMatrix {
    /// Rows top to bottom, `true` for a dark module. Includes the generator's quiet-zone border.
    static func modules(for text: String) -> [[Bool]]? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0, let image = CIContext().createCGImage(output, from: extent) else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // A bitmap context's memory starts at the top row of what was drawn.
        return (0..<h).map { y in (0..<w).map { x in pixels[y * w + x] < 128 } }
    }
}
