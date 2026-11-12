import SwiftUI
import SwiftData

/// Map first. Then People, Plans and Passport, and Wren in the round button at the end
/// of the tab bar. The quote opens the app the first time.
struct RootView: View {
    @Environment(LocationService.self) private var location
    @Environment(SyncStatus.self) private var sync
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = HomeModel()
    @AppStorage("splash.seen") private var seenQuote = false
    @Query(sort: \Night.evening, order: .reverse) private var nights: [Night]
    /// When Let's Go was last brought up (and lit), for the night's phone time.
    @State private var litSince: Date?
    /// Steps not yet written to tonight's night, so it isn't saved every few meters.
    @State private var pendingWalk: Double = 0
    /// The day the listings were last laid out for, so they roll on at midnight.
    @State private var listedDay: Date?

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Map", systemImage: "map", value: AppTab.map) {
                HomeView()
            }
            Tab("People", systemImage: "person.2", value: AppTab.people) {
                PeopleView()
            }
            Tab("Plans", systemImage: "calendar", value: AppTab.plans) {
                PlansView()
            }
            Tab("Passport", systemImage: "person.text.rectangle", value: AppTab.passport) {
                PassportTab()
            }
            Tab("Wren", systemImage: "sparkle", value: AppTab.wren, role: .search) {
                WrenView()
            }
        }
        .tint(Palette.ink)
        .environment(model)
        .fullScreenCover(isPresented: $model.showQuote) {
            QuoteSplash(onDone: {
                seenQuote = true
                model.showQuote = false
            }, onInvite: inviteAction)
        }
        .fullScreenCover(item: $model.recap) { MorningAfterView(night: $0) }
        .onAppear {
            if !seenQuote { model.showQuote = true }
            litSince = .now
            checkRecap()
        }
        .onChange(of: location.odometer) { old, new in
            pendingWalk += max(0, new - old)
            if pendingWalk >= 50 {
                Ledger.walked(pendingWalk, context: context)
                pendingWalk = 0
            }
        }
        // A dark screen (gone dark, or a pocketed walk) isn't time on the phone.
        .onChange(of: model.dark) { _, dark in
            if dark { flushPhoneTime() } else { litSince = .now }
        }
        .task {
            SamplePurge.runOnce(context: context)
            location.start()
        }
        // Lay out the listings and pull from the server when the neighborhood changes,
        // and whenever the app comes back.
        .task(id: location.center.roundedKey) {
            prune(relist: true)
            await pull()
        }
        // While the app is open, things leave the map as they end, and weekly listings roll on at midnight.
        .task { await keepPruning() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushPhoneTime() }
            if phase == .active {
                if !model.dark { litSince = .now }
                checkRecap()
                prune(relist: true)
                Task { await pull() }
            }
        }
    }

    /// "A friend sent me an invite" on the quote: only when there's a server that keeps friends.
    private var inviteAction: (() -> Void)? {
        guard APIConfig.isConfigured, ServerFeatures.shared.has(.people) else { return nil }
        return {
            seenQuote = true
            model.showQuote = false
            model.tab = .people
            Task {
                // Let the cover go before the sheet comes up.
                try? await Task.sleep(for: .milliseconds(500))
                model.addingFriend = true
            }
        }
    }

    /// Takes off what has ended (`Upcoming`), and in the city lays the listings out again when asked
    /// or when the day has changed. Returns when to prune next.
    @discardableResult
    private func prune(relist: Bool = false, now: Date = .now) -> Date {
        let today = Calendar.current.startOfDay(for: now)
        if CityListings.covers(location.center), relist || listedDay != today {
            CityListings.refresh(context: context, now: now)
            listedDay = today
        }
        return Ledger.pruneEnded(context: context, now: now)
    }

    /// Wakes when the next thing on show ends, or at midnight. New things can arrive from the server
    /// meanwhile, so it looks again at least every five minutes.
    private func keepPruning() async {
        while !Task.isCancelled {
            let next = prune()
            let wait = min(max(1, next.timeIntervalSinceNow + 1), 5 * 60)
            do {
                try await Task.sleep(for: .seconds(wait))
            } catch {
                return
            }
        }
    }

    private func flushPhoneTime() {
        guard let since = litSince else { return }
        litSince = nil
        Ledger.phoneTime(since: since, context: context)
    }

    /// The morning after a night out, once.
    private func checkRecap() {
        guard !model.showQuote, model.recap == nil else { return }
        let now = Date.now
        model.recap = nights.first { NightMath.wantsRecap(evening: $0.evening, stops: $0.stops.count, seen: $0.recapSeenAt != nil, now: now) }
    }

    private func pull() async {
        let center = location.center
        let server = ServerFeatures.shared
        await server.check()
        if CityListings.covers(center), server.has(.listings), await CityListings.update() { prune(relist: true) }
        await sync.run { () throws(APIError) in
            try await Sync.refresh(around: center, context: context)
            if server.has(.people) { try await Sync.refreshPeople(around: center, context: context) }
        }
        prune()
    }
}
