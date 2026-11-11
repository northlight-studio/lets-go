import SwiftUI
import SwiftData

@main
struct LetsGoApp: App {
    @State private var location = LocationService()
    @State private var sync = SyncStatus()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(location)
                .environment(sync)
                // Light by day, dark after sunset: whatever the phone's appearance is.
                .tint(Palette.accent)
        }
        .modelContainer(for: [
            Gathering.self, Kitchen.self, MenuItem.self, Drop.self,
            Order.self, Review.self, Stamp.self, TasteNote.self, Person.self, Crew.self, SavedPlan.self, Night.self, Intro.self,
        ])
    }
}
