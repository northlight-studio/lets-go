import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// Host a supper: a photo, what it is, when, how many seats at what price, the menu course by
/// course, diet and allergen notes, house notes, and (the first time) the address and the permit.
/// The address goes only to guests you say yes to. With no kitchen yet, hosting opens one in your
/// name. Logic in `SupperDraft`.
struct HostSupperView: View {
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Kitchen> { $0.isMine }) private var mine: [Kitchen]

    @State private var draft = SupperDraft.starting(now: .now)
    @State private var image: UIImage?
    @State private var picked: PhotosPickerItem?
    @State private var camera = false
    @State private var posting = false
    @State private var hosted: SupperDTO?
    @State private var photoFailed = false
    @State private var jpeg: Data?
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var kitchen: Kitchen? { mine.first }
    private var serverReady: Bool { ServerFeatures.shared.has(.suppers) }
    private var needsAddress: Bool { kitchen?.address.isEmpty ?? true }
    private var needsPermit: Bool { !(kitchen.map { $0.permitConfirmed && $0.handlerCardConfirmed } ?? false) }

    var body: some View {
        NavigationStack {
            Group {
                if let hosted {
                    done(hosted)
                } else {
                    form
                }
            }
            .background(Palette.bg)
            .navigationTitle(hosted == nil ? "Host a supper" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if hosted == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
            .errorAlert($problem)
        }
        .presentationBackground(Palette.bg)
        .onAppear {
            if draft.address.isEmpty, let k = kitchen { draft.address = k.address }
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
                if !serverReady { TipNote(text: ServerFeatures.Feature.suppers.comingSoon) }
                photo
                VStack(spacing: 0) {
                    row("What") {
                        TextField("Oaxacan night", text: $draft.title)
                            .multilineTextAlignment(.trailing)
                            .focused($focused)
                    }
                    divider
                    row("Seats") {
                        HStack(spacing: 10) {
                            Stepperish(count: draft.seats, max: SupperDraft.maxSeats) { draft.seats = max(1, $0) }
                            Text("\(draft.seats)").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        }
                    }
                    divider
                    row("A seat") {
                        TextField("$18", text: $draft.priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                            .focused($focused)
                    }
                }
                .card()
                Text("Set it to cover the food. Guests pay it when you say yes.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 4)

                when
                courses
                tagsCard
                house
                permitCard

                Button(posting ? "One moment…" : "Put it on the map") { host() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(posting || !serverReady)
                    .padding(.top, 4)
                Text("Neighbors within a walk see it and ask for a seat. You choose who comes.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 18))
                PhotosPicker(selection: $picked, matching: .images) { Text("Change") }
                    .buttonStyle(.glass)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(10)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Palette.muted)
                    Text("Your table, or a dish you'll make.")
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
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .background(Palette.raise, in: .rect(cornerRadius: 18))
            }
        }
    }

    private var when: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("When").eyebrow()
            DatePicker("Day", selection: $draft.day, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
            Stepper(value: $draft.from, in: 7...22, step: 0.5) {
                Text("Starts \(BatchCopy.clock(draft.from))").monospacedDigit()
            }
            Stepper(value: $draft.hours, in: 1...6, step: 0.5) {
                Text("For \(draft.hours.formatted()) hours").monospacedDigit()
            }
            Text(SupperCopy.when(draft.window().start, now: .now))
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
        }
        .font(.system(size: 15))
        .padding(14)
        .card()
    }

    private var courses: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The menu").eyebrow()
            ForEach($draft.courses) { $course in
                VStack(alignment: .leading, spacing: 4) {
                    TextField("A course, like \"Mole negro\"", text: $course.name)
                        .font(.system(size: 15, weight: .semibold))
                        .focused($focused)
                    TextField("A line on it, like \"chicken or squash\"", text: $course.note)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.soft)
                        .focused($focused)
                }
                Divider().overlay(Palette.line)
            }
            if draft.courses.count < 8 {
                Button { draft.courses.append(.init()) } label: { Label("Another course", systemImage: "plus") }
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .padding(14)
        .card()
    }

    private var tagsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diet and allergens").eyebrow()
            FlowLayout(spacing: 6) {
                ForEach(SupperDraft.tagOptions, id: \.self) { t in
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

    private var house: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your place").eyebrow()
            TextField("House notes, like \"shoes off, we have a cat\"", text: $draft.houseNotes, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
            TextField("Your address", text: $draft.address)
                .textContentType(.fullStreetAddress)
                .focused($focused)
            Label("The address goes only to guests you say yes to.", systemImage: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
        .font(.system(size: 15))
        .padding(14)
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
                Text("Selling meals from home needs a permit in most places. In California that's a MEHKO permit, where your county offers one. You're asked once.")
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

    // MARK: Hosted

    private func done(_ s: SupperDTO) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            BatchPhoto(path: s.photoUrl, title: s.title, height: 220, radius: 20)
            Text("It's on the map").display(30)
            Text("\(s.title), \(SupperCopy.when(s.startsAt, now: .now)). \(SupperCopy.seatsLine(taken: 0, seats: s.seats, priceCents: s.priceCents)).")
                .font(.system(size: 16))
                .foregroundStyle(Palette.soft)
            if photoFailed {
                HStack {
                    Text("The supper is up, but the photo didn't upload.")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                    Button("Try again") { retryPhoto(s) }
                        .buttonStyle(.glass)
                        .disabled(posting)
                }
            }
            Text("When neighbors ask for a seat, you'll see each one on the supper's page with their reviews from other hosts. Say yes to the ones you'd like at your table.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
    }

    // MARK: Parts

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

    private func host() {
        focused = false
        if let p = draft.problem(now: .now, needsAddress: needsAddress, needsPermit: needsPermit) {
            problem = p
            return
        }
        let photo = image.flatMap { PhotoJPEG.make($0) }
        jpeg = photo
        let here = location.center
        posting = true
        Task {
            await attempt($problem) { () throws(APIError) in
                let s = try await Sync.host(draft, at: here, context: context)
                withAnimation { hosted = s }
            }
            // Hosted: now the photo. If it fails, the supper stays up and the photo can be sent again.
            if let s = hosted, let photo {
                do {
                    try await Sync.upload(photo, forSupper: s.id, from: here)
                    hosted = SupperBook.shared.supper(s.id) ?? s
                } catch {
                    photoFailed = true
                }
            }
            posting = false
        }
    }

    private func retryPhoto(_ s: SupperDTO) {
        guard let jpeg else { return }
        let here = location.center
        posting = true
        Task {
            await attempt($problem) { () throws(APIError) in
                try await Sync.upload(jpeg, forSupper: s.id, from: here)
                hosted = SupperBook.shared.supper(s.id) ?? s
                photoFailed = false
            }
            posting = false
        }
    }
}
