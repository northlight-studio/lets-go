import Foundation
import SwiftData

/// Older versions placed a made-up "sample neighborhood" around you: gatherings, kitchens,
/// friends, a crew and an intro, each marked `isSample`. That's gone. On the first launch of a
/// version without it, everything it left in the store is deleted once (`Ledger.clearSamples`),
/// so a phone that had samples ends up with only real things.
enum SamplePurge {
    static let doneKey = "samples.purged.v1"
    /// What the sample neighborhood kept in UserDefaults.
    private static let leftoverKeys = ["sample.center", "sample.seededAt", "sample.version", "sample.enabled"]

    static func runOnce(context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        // Tried again next launch if it didn't go through.
        guard Ledger.clearSamples(context: context) else { return }
        leftoverKeys.forEach(defaults.removeObject(forKey:))
        defaults.set(true, forKey: doneKey)
    }
}
