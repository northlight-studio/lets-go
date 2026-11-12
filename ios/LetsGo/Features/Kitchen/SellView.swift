import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// "Sell something": a batch on the map in about thirty seconds, photo first. What it is, the price,
/// how many, the pickup window, where (the address shows only after someone reserves) and, the first
/// time, the permit. With no kitchen yet, posting opens one in your name. Logic in `BatchDraft`.
struct SellView: View {
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Kitchen> { $0.isMine }) private var mine: [Kitchen]

    @State private var draft = BatchDraft.starting(now: .now)
    @State private var image: UIImage?
    @State private var picked: PhotosPickerItem?
    @State private var camera = false
    @State private var anotherDay = Date.now.addingTimeInterval(2 * 86_400)
    @State private var posting = false
    @State private var posted: Drop?
    /// Kept so a photo that didn't upload can be sent again without posting the batch twice.
    @State private var jpeg: Data?
    @State private var photoFailed = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var kitchen: Kitchen? { mine.first }
    private var needsAddress: Bool { kitchen?.address.isEmpty ?? true }
    private var needsPermit: Bool { !(kitchen.map { $0.permitConfirmed && $0.handlerCardConfirmed } ?? false) }

    var body: some View {
        NavigationStack {
            Group {
                if let posted {
                    postedView(posted)
                } else {
                    form
                }
            }
            .background(Palette.bg)
            .navigationTitle(posted == nil ? "New batch" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if posted == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Post") { post() }.disabled(posting)
                    }
                }
            }
            .errorAlert($problem)
        }
        .presentationBackground(Palette.bg)
        .onAppear {
            if draft.address.isEmpty, let k = kitchen { draft.address = k.address }
            if draft.pickupNote.isEmpty, let k = kitchen { draft.pickupNote = k.pickupNote }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) {
                    image = ui
                }
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { image = $0 }.ignoresSafeArea()
        }
    }

    // MARK: The form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                photo
                VStack(spacing: 0) {
                    row("What") {
                        TextField("Mango sticky rice ice cream", text: $draft.title)
                            .multilineTextAlignment(.trailing)
                            .focused($focused)
                    }
                    divider
                    row("Price") {
                        HStack(spacing: 6) {
                            TextField("$6", text: $draft.priceText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 70)
                                .focused($focused)
                            Text(draft.unit.isEmpty ? "each" : "a")
                                .foregroundStyle(Palette.muted)
                            TextField("pint", text: $draft.unit)
                                .frame(maxWidth: 80)
                                .focused($focused)
                        }
                    }
                    divider
                    row("How many") {
                        HStack(spacing: 10) {
                            Stepperish(count: draft.count, max: 500) { draft.count = max(1, $0) }
                            Text(BatchCopy.count(draft.count, draft.unit.trimmingCharacters(in: .whitespaces)))
                                .font(.system(size: 15, weight: .semibold))
                                .monospacedDigit()
                        }
                    }
                }
                .card()

                pickup
                whereCard
                tagsCard
                permitCard

                VStack(alignment: .leading, spacing: 8) {
                    Button(posting ? "Posting…" : "Put it on the map") { post() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(posting)
                    Text("Neighbors within a 15-minute walk see it first. People who follow your kitchen get a note.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
    }

    private var photo: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 18))
                HStack(spacing: 8) {
                    if CameraPicker.isAvailable {
                        Button("Retake") { camera = true }
                            .buttonStyle(.glass)
                    }
                    PhotosPicker(selection: $picked, matching: .images) { Text("Choose") }
                        .buttonStyle(.glass)
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(10)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Palette.muted)
                    Text("A photo is what people stop for.")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.muted)
                    HStack(spacing: 10) {
                        if CameraPicker.isAvailable {
                            Button { camera = true } label: { Label("Take a photo", systemImage: "camera.fill") }
                                .buttonStyle(.glassProminent)
                                .tint(Palette.prominent)
                        }
                        PhotosPicker(selection: $picked, matching: .images) {
                            Label("Choose one", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.glass)
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .background(Palette.raise, in: .rect(cornerRadius: 18))
            }
        }
    }

    private var pickup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pickup").eyebrow()
            HStack(spacing: 8) {
                dayChip(isEvening ? "Tonight" : "Today", selected: draft.day == .today) { draft.day = .today }
                dayChip("Tomorrow", selected: draft.day == .tomorrow) { draft.day = .tomorrow }
                dayChip("Another day", selected: isAnotherDay) { draft.day = .on(anotherDay) }
            }
            if isAnotherDay {
                DatePicker("Day", selection: $anotherDay, in: Date.now..., displayedComponents: .date)
                    .onChange(of: anotherDay) { _, d in draft.day = .on(d) }
            }
            Stepper(value: $draft.from, in: 6...22, step: 0.5) {
                Text("From \(BatchCopy.clock(draft.from))").monospacedDigit()
            }
            .onChange(of: draft.from) { _, from in if draft.to <= from { draft.to = min(23.5, from + 1) } }
            Stepper(value: $draft.to, in: 6.5...23.5, step: 0.5) {
                Text("Until \(BatchCopy.clock(draft.to))").monospacedDigit()
            }
            if let w = draft.window(now: .now) {
                Text(BatchCopy.window(w.start, w.end, now: .now))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
        }
        .font(.system(size: 15))
        .padding(14)
        .card()
    }

    private var whereCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where").eyebrow()
            Picker("Where", selection: $draft.spot) {
                ForEach(BatchDraft.Spot.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Your address", text: $draft.address)
                .textContentType(.fullStreetAddress)
                .focused($focused)
            TextField("How to find it, like \"blue door, lemon tree\"", text: $draft.pickupNote, axis: .vertical)
                .lineLimit(1...3)
                .focused($focused)
            Label("The address shows only after someone reserves.", systemImage: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
        .font(.system(size: 15))
        .padding(14)
        .card()
    }

    private var tagsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allergens and diet").eyebrow()
            FlowLayout(spacing: 6) {
                ForEach(BatchDraft.tagOptions, id: \.self) { t in
                    let on = draft.tags.contains(t)
                    Button {
                        if on { draft.tags.remove(t) } else { draft.tags.insert(t) }
                    } label: {
                        Text(t)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .foregroundStyle(on ? Palette.onProminent : Palette.ink)
                            .background(on ? Palette.prominent : Palette.raise, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private var permitCard: some View {
        if needsPermit {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $draft.permitConfirmed) {
                    Text("I have a home kitchen permit").font(.system(size: 15, weight: .semibold))
                }
                .tint(Palette.live)
                Text("Selling food from home needs a permit in most places. In California that's a MEHKO permit, where your county offers one; ice cream and full meals usually aren't covered by cottage-food rules. You're asked once; your listings then say \"Home kitchen permit on file\".")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .card()
        } else {
            Label("Home kitchen permit on file", systemImage: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.live)
                .padding(.horizontal, 4)
        }
    }

    // MARK: Posted

    private func postedView(_ drop: Drop) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            BatchPhoto(path: drop.photoPath, title: drop.title, height: 220, radius: 20)
            Text("It's on the map").display(30)
            Text("\(drop.title), \(BatchCopy.left(drop.left, of: drop.total, unit: drop.unit).lowercased()). \(BatchCopy.window(drop.start, drop.end, now: .now)).")
                .font(.system(size: 16))
                .foregroundStyle(Palette.soft)
            if photoFailed {
                HStack {
                    Text("The batch is up, but the photo didn't upload.")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                    Button("Try again") { retryPhoto(drop) }
                        .buttonStyle(.glass)
                        .disabled(posting)
                }
            }
            Text("You'll see each order and its pickup code in Your kitchen. Mark them picked up as people come by.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
    }

    // MARK: Parts

    private var isEvening: Bool { Calendar.current.component(.hour, from: .now) >= 15 }

    private var isAnotherDay: Bool {
        if case .on = draft.day { return true }
        return false
    }

    private var divider: some View { Divider().overlay(Palette.line).padding(.leading, 14) }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            content()
        }
        .font(.system(size: 15))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func dayChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Palette.onProminent : Palette.ink)
                .background(selected ? Palette.prominent : Palette.raise, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func post() {
        focused = false
        let now = Date.now
        if let p = draft.problem(now: now, needsAddress: needsAddress, needsPermit: needsPermit) {
            problem = p
            return
        }
        let photo = image.flatMap { PhotoJPEG.make($0) }
        jpeg = photo
        let here = location.center
        let k = kitchen
        posting = true
        Task {
            await attempt($problem) { () throws(APIError) in
                let drop = try await Sync.post(draft, at: here, mine: k, context: context, now: now)
                withAnimation { posted = drop }
            }
            // Posted: now the photo. If it fails, the batch stays up and the photo can be sent again.
            if let drop = posted, let photo {
                do {
                    try await Sync.upload(photo, for: drop, context: context)
                } catch {
                    photoFailed = true
                }
            }
            posting = false
        }
    }

    private func retryPhoto(_ drop: Drop) {
        guard let jpeg else { return }
        posting = true
        Task {
            await attempt($problem) { () throws(APIError) in
                try await Sync.upload(jpeg, for: drop, context: context)
                photoFailed = false
            }
            posting = false
        }
    }
}
