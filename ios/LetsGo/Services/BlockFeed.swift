import Foundation
import CoreLocation
import Observation
import OSLog
import UserNotifications

/// Your block, kept for the whole app: the latest list from the server, the area's name, what
/// you've seen, and the one evening digest. `Block` decides; this fetches, remembers and schedules.
///
/// The digest is a local notification built from the last pull, set for early evening (one pending
/// at a time, so never more than one a day) and only when something is new. Opening Your block
/// takes back a digest that has nothing left to say. Push from the server isn't set up yet.
@Observable
final class BlockFeed {
    static let shared = BlockFeed()

    nonisolated static let digestID = "block.digest"
    static let memoryKey = "block.memory"
    static let digestKey = "block.digest.on"

    private(set) var items: [BlockItemDTO] = []
    private(set) var memory: Block.Memory
    /// "24th Street and around".
    private(set) var area = "Around you"
    private(set) var loaded = false
    /// A digest was tapped: People opens Your block.
    var openRequested = false
    /// Whether notifications are turned off for the app in Settings (the digest can't come).
    private(set) var notificationsDenied = false

    /// The evening digest, on unless you turn it off.
    var digestOn: Bool {
        didSet {
            defaults.set(digestOn, forKey: Self.digestKey)
            Task { await scheduleDigest() }
        }
    }

    private let defaults: UserDefaults
    private var namedKey: String?
    private let log = Logger(subsystem: "com.yasser100ali.letsgo", category: "block")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        digestOn = defaults.object(forKey: Self.digestKey) as? Bool ?? true
        if let data = defaults.data(forKey: Self.memoryKey),
           let m = try? JSONDecoder().decode(Block.Memory.self, from: data) {
            memory = m
        } else {
            memory = Block.Memory()
        }
    }

    /// Something you haven't seen yet: the dot on the bell.
    var hasNew: Bool { !Block.unseen(items, memory: memory).isEmpty }

    func today(now: Date = .now) -> [BlockItemDTO] { Block.today(items, memory: memory, now: now) }

    /// Pulls the list for around `center`, names the area, and sets (or takes back) the digest.
    func refresh(around center: CLLocationCoordinate2D) async {
        guard APIConfig.isConfigured, ServerFeatures.shared.has(.block) else { return }
        do {
            items = try await Sync.block(around: center)
            loaded = true
        } catch {
            log.error("Couldn't load your block: \(error.localizedDescription, privacy: .public)")
        }
        await name(center)
        await scheduleDigest()
    }

    /// You've looked: these won't come back on another day, and the digest drops them.
    func see(_ shown: [BlockItemDTO], now: Date = .now) {
        let next = Block.seeing(shown, in: memory, now: now)
        guard next != memory else { return }
        memory = next
        Ledger.sawBlock(memory, defaults: defaults)
        Task { await scheduleDigest() }
    }

    // MARK: The area's name

    private func name(_ center: CLLocationCoordinate2D) async {
        // Once per few hundred meters, not every pull.
        let key = String(format: "%.3f,%.3f", center.latitude, center.longitude)
        guard key != namedKey else { return }
        let place = CLLocation(latitude: center.latitude, longitude: center.longitude)
        // The street and neighborhood as plain strings; the geocoder answers on the main queue.
        let names: (street: String?, neighborhood: String?)? = await withCheckedContinuation { done in
            CLGeocoder().reverseGeocodeLocation(place) { marks, error in
                if let error {
                    Logger(subsystem: "com.yasser100ali.letsgo", category: "block")
                        .error("Couldn't name the area: \(error.localizedDescription, privacy: .public)")
                }
                done.resume(returning: marks?.first.map { (street: $0.thoroughfare, neighborhood: $0.subLocality) })
            }
        }
        guard let names else { return }
        area = Block.area(street: names.street, neighborhood: names.neighborhood)
        namedKey = key
    }

    // MARK: The evening digest

    func scheduleDigest(now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        guard digestOn else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.digestID])
            return
        }
        let fire = Block.nextDigest(after: now)
        let picks = Block.digestItems(items, memory: memory, fire: fire)
        guard let body = Block.digestBody(picks, fire: fire) else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.digestID])
            return
        }
        // Quiet at first (no prompt): it lands in Notification Center, and you choose to keep it.
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .provisional])
        }
        let status = await center.notificationSettings().authorizationStatus
        notificationsDenied = status == .denied
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }

        let content = UNMutableNotificationContent()
        content.title = area == "Around you" ? "Your block" : area
        content.body = body
        content.threadIdentifier = "block"
        let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let request = UNNotificationRequest(
            identifier: Self.digestID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        )
        do {
            try await center.add(request)
            var m = memory
            for i in picks { m.told[i.key] = fire }
            if m != memory {
                memory = m
                Ledger.sawBlock(memory, defaults: defaults)
            }
        } catch {
            log.error("Couldn't set the digest: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Opens Your block when a digest is tapped, and shows a digest that arrives while the app is open.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == BlockFeed.digestID else { return }
        await MainActor.run { BlockFeed.shared.openRequested = true }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
