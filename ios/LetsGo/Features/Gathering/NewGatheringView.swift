import SwiftUI
import SwiftData
import MapKit

/// Host something. Tap the map to move the pin; it starts where you are.
struct NewGatheringView: View {
    var draft: GatheringDraft?

    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var category: Genre = .play
    @State private var start = Date.now.addingTimeInterval(3600)
    @State private var end = Date.now.addingTimeInterval(3 * 3600)
    @State private var weekly = false
    @State private var placeName = ""
    @State private var capacity = 0
    @State private var bring = ""
    @State private var details = ""
    @State private var pin: CLLocationCoordinate2D?
    @State private var loaded = false
    @State private var posting = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What is it?", text: $title)
                        .font(.system(size: 18, weight: .semibold))
                        .onChange(of: title) { _, v in title = KitchenLimits.clip(v, 120) }
                    Picker("Kind", selection: $category) {
                        ForEach(Genre.allCases.filter { $0 != .food }) { c in
                            Label(c.label, systemImage: c.symbol).tag(c)
                        }
                    }
                }
                Section("When") {
                    DatePicker("Starts", selection: $start, in: Date.now.addingTimeInterval(-3600)...)
                    DatePicker("Ends", selection: $end, in: start...)
                    Toggle(weekly ? PosterCopy.weekly(from: start) : "Every week", isOn: $weekly)
                }
                Section {
                    TextField("Place name, like \"The big field\"", text: $placeName)
                        .onChange(of: placeName) { _, v in placeName = KitchenLimits.clip(v, 120) }
                    placePicker
                } header: {
                    Text("Where")
                } footer: {
                    Text("Tap the map to move the pin.")
                }
                Section("Details") {
                    Stepper(capacity == 0 ? "Open to anyone" : "Up to \(capacity) people", value: $capacity, in: 0...200)
                    TextField("What to bring", text: $bring)
                        .onChange(of: bring) { _, v in bring = KitchenLimits.clip(v, 200) }
                    TextField("Anything else people should know", text: $details, axis: .vertical)
                        .lineLimit(2...5)
                        .onChange(of: details) { _, v in details = KitchenLimits.clip(v, 2000) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle("Host something")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { post() }
                        .fontWeight(.bold)
                        .disabled(!canPost || posting)
                }
            }
            .onAppear(perform: load)
            .errorAlert($problem)
            .onChange(of: start) { _, new in
                if end <= new { end = new.addingTimeInterval(2 * 3600) }
            }
        }
    }

    private var placePicker: some View {
        MapReader { proxy in
            Map(initialPosition: .camera(MapCamera(centerCoordinate: pin ?? location.center, distance: 1500))) {
                UserAnnotation()
                if let pin {
                    Annotation("", coordinate: pin) { MapMarker(genre: category, caption: placeName.isEmpty ? "Here" : placeName, selected: true) }
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .onTapGesture { point in
                if let c = proxy.convert(point, from: .local) { pin = c }
            }
        }
        // Rebuilt once the draft is loaded, so the map starts on the draft's pin.
        .id(loaded)
        .frame(height: 190)
        .clipShape(.rect(cornerRadius: 12))
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
    }

    private var canPost: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !placeName.trimmingCharacters(in: .whitespaces).isEmpty
            && end > start
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        pin = location.center
        guard let draft else { return }
        title = draft.title
        category = draft.category == .food ? .party : draft.category
        start = draft.start
        end = draft.end
        placeName = draft.placeName
        capacity = draft.capacity
        if let lat = draft.latitude, let lon = draft.longitude {
            pin = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    private func post() {
        let g = Gathering(
            title: title.trimmingCharacters(in: .whitespaces),
            category: category,
            details: details,
            placeName: placeName.trimmingCharacters(in: .whitespaces),
            coordinate: pin ?? location.center,
            start: start, end: end,
            capacity: capacity,
            hostName: "You",
            bring: bring,
            recurring: weekly ? PosterCopy.weekly(from: start) : "",
            isMine: true
        )
        posting = true
        Task {
            await attempt($problem) { () throws(APIError) in
                try await Sync.host(g, context: context)
                dismiss()
            }
            posting = false
        }
    }
}
