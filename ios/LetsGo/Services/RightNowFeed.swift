import Foundation
import CoreLocation
import Observation
import OSLog

/// How well each nearby thing fits you, kept for the map and its list: asked of the server when
/// what's near changes, and at most every ten minutes otherwise. `RightNow` does the ranking.
@Observable
final class RightNowFeed {
    static let shared = RightNowFeed()

    private(set) var fits: [UUID: Double] = [:]
    private var askedFor: Set<UUID> = []
    private var askedAt: Date?
    private var asking = false
    private let log = Logger(subsystem: "com.yasser100ali.letsgo", category: "rightnow")

    /// How long an answer for the same things stands.
    static let fresh: TimeInterval = 600

    /// Scores what's near, from what the store holds. Does nothing when the server can't, when
    /// nothing is near, or when the same things were scored in the last ten minutes.
    func refresh(gatherings: [Gathering], kitchens: [Kitchen], notes: [TasteNote], around center: CLLocationCoordinate2D, now: Date = .now) async {
        guard APIConfig.isConfigured, ServerFeatures.shared.has(.rightNow), !asking else { return }
        let all = Nearby.candidates(gatherings: gatherings, kitchens: kitchens, from: center, now: now)
            + SupperBook.shared.candidates(from: center, now: now)
        let taste = Nearby.taste(notes: notes, gatherings: gatherings, kitchens: kitchens)
        let things = RightNow.eligible(all, now: now, taste: taste)
        guard !things.isEmpty else { return }
        let ids = Set(things.map(\.id))
        if ids == askedFor, let askedAt, now.timeIntervalSince(askedAt) < Self.fresh { return }

        let wentTo = gatherings
            .filter { $0.isJoined || $0.checkedInAt != nil }
            .sorted { $0.start > $1.start }
            .map(\.title)
        let body = RightNow.body(
            for: things,
            localTime: RightNow.localTime(now),
            notes: notes.filter { !$0.isHidden }.map(\.text),
            wentTo: wentTo
        )
        asking = true
        defer { asking = false }
        do {
            let dto = try await Sync.rightNow(body)
            // Asked either way, so a server that can't score isn't asked again every thirty seconds.
            askedFor = ids
            askedAt = now
            if dto.scored { fits = RightNow.fits(from: dto) }
        } catch {
            log.error("Couldn't score what's near: \(error.localizedDescription, privacy: .public)")
        }
    }
}
