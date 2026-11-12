import SwiftUI
import SwiftData
import MapKit

/// A supper's page. What a neighbor sees: the photo, when and "at Ana's" (the address only once Ana
/// says yes), the host with suppers hosted, rating and walk, the menu, diet and allergen notes, the
/// house notes, the seats with friends' faces, the price a seat, and **Ask for a seat**. The host
/// sees the same page with who's asking (each with their reviews and suppers) to say yes or no to.
/// Afterwards, everyone at the table can review and add each other. Words in `SupperCopy`, where you
/// stand in `SeatStage`.
struct SupperView: View {
    var id: UUID
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var supper: SupperDTO?
    @State private var guests: [GuestDTO] = []
    @State private var asking = false
    @State private var working = false
    @State private var problem: String?
    @State private var checkout = PayFlow()
    @State private var backingOut = false
    @State private var calling = false
    @State private var reviewing: TableMateDTO?
    @State private var missing = false

    private var current: SupperDTO? { supper ?? SupperBook.shared.supper(id) }

    var body: some View {
        Group {
            if let s = current {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    page(s, now: timeline.date)
                }
            } else if missing {
                ContentUnavailableView("This supper isn't here anymore", systemImage: "fork.knife",
                                       description: Text("The host may have called it off."))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.bg)
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($problem)
        .errorAlert($checkout.problem)
        .checkoutSheet(checkout, context: context)
        .sheet(isPresented: $asking) {
            if let s = current {
                AskSeatView(supper: s) { note in ask(s, note: note) }
            }
        }
        .sheet(item: $reviewing) { mate in
            if let s = current {
                SupperReviewView(mate: mate, isHost: mate.isHost) { stars, text in review(mate, stars: stars, text: text, at: s) }
            }
        }
        .task { await load() }
    }

    // MARK: The page

    private func page(_ s: SupperDTO, now: Date) -> some View {
        let stage = SeatStage.of(s, now: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BatchPhoto(path: s.photoUrl, title: s.title, height: 280)
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(SupperCopy.when(s.startsAt, now: now)) · \(SupperCopy.at(s.host.displayName))")
                            .eyebrow()
                        Text(s.title).display(28)
                    }
                    hostRow(s)
                    menu(s)
                    if !s.tags.isEmpty || !s.houseNotes.isEmpty { notes(s) }
                    seats(s)
                    place(s, stage: stage)
                    if s.isMine && !s.canceled && s.startsAt > now { requests(s) }
                    if stage == .after && !s.table.isEmpty { table(s) }
                    if s.isMine && !s.canceled && s.startsAt > now {
                        Button("Call off this supper", role: .destructive) { calling = true }
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) { action(s, stage: stage, now: now) }
        .confirmationDialog("Give back your seat?", isPresented: $backingOut, titleVisibility: .visible) {
            Button("Give it back", role: .destructive) { backOut(s) }
        } message: {
            Text(s.inApp ? SupperCopy.refundRule(s.refundUntil, now: now) : "\(SupperCopy.firstName(s.host.displayName)) can give it to someone else.")
        }
        .confirmationDialog("Call off this supper?", isPresented: $calling, titleVisibility: .visible) {
            Button("Call it off", role: .destructive) { cancel(s) }
        } message: {
            Text("Everyone who asked hears it's off, and everyone who paid gets all of it back.")
        }
    }

    private func hostRow(_ s: SupperDTO) -> some View {
        HStack(spacing: 12) {
            Initials(name: s.host.displayName, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.isMine ? "You're hosting" : SupperCopy.firstName(s.host.displayName))
                    .font(.system(size: 16, weight: .semibold))
                Text(SupperCopy.hostLine(
                    hosted: s.suppersHosted, rating: s.hostRating, reviews: s.hostReviewCount,
                    walkMinutes: s.isMine ? nil : Walk.minutes(location.center.distance(to: s.coordinate))
                ))
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private func menu(_ s: SupperDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The menu").eyebrow()
            ForEach(Array(s.menu.enumerated()), id: \.offset) { _, course in
                VStack(alignment: .leading, spacing: 1) {
                    Text(course.name).font(.system(size: 16, weight: .semibold))
                    if !course.note.isEmpty {
                        Text(course.note).font(.system(size: 14)).foregroundStyle(Palette.muted)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func notes(_ s: SupperDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !s.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(s.tags, id: \.self) { t in
                        Text(t)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundStyle(Palette.soft)
                            .background(Palette.raise, in: .capsule)
                    }
                }
            }
            if !s.houseNotes.isEmpty {
                Label(s.houseNotes, systemImage: "house")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A circle a seat: friends going by their initials, other guests filled, open seats empty.
    private func seats(_ s: SupperDTO) -> some View {
        let others = max(0, s.taken - s.friendsGoing.count)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(s.friendsGoing, id: \.id) { f in Initials(name: f.displayName, size: 32) }
                ForEach(0..<others, id: \.self) { _ in
                    Circle().fill(Palette.soft).frame(width: 32, height: 32)
                }
                ForEach(0..<s.seatsLeft, id: \.self) { _ in
                    Circle().strokeBorder(Palette.faint, lineWidth: 1.5).frame(width: 32, height: 32)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(s.taken) of \(s.seats) seats taken")
            Text(s.isMine
                 ? SupperCopy.hostSeats(taken: s.taken, seats: s.seats, waiting: s.waiting)
                 : SupperCopy.seatsLine(taken: s.taken, seats: s.seats, priceCents: s.priceCents))
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
            if !s.friendsGoing.isEmpty {
                Text(SupperCopy.friendsGoing(s.friendsGoing.map(\.displayName)))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    @ViewBuilder
    private func place(_ s: SupperDTO, stage: SeatStage) -> some View {
        if let address = s.address, s.exact {
            HStack(spacing: 10) {
                Label(address, systemImage: "lock.open.fill")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 6)
                if !s.isMine {
                    Button("Walk there") { directions(s) }
                        .buttonStyle(.glass)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
        } else if !s.isMine && stage != .over && stage != .canceled {
            Label("The exact address shows once \(SupperCopy.firstName(s.host.displayName)) says yes.", systemImage: "lock.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
        }
    }

    // MARK: The host choosing

    @ViewBuilder
    private func requests(_ s: SupperDTO) -> some View {
        let waiting = guests.filter { $0.status == SeatStatus.asked.rawValue }
        let coming = guests.filter { $0.status == SeatStatus.accepted.rawValue }
        VStack(alignment: .leading, spacing: 10) {
            Text(waiting.isEmpty ? "Nobody's asking yet" : "Asking for a seat").eyebrow()
            if waiting.isEmpty {
                Text("Neighbors within a walk see it on the map. You choose who comes.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
            }
            ForEach(waiting) { g in
                GuestRow(guest: g) {
                    HStack(spacing: 8) {
                        Button("No") { answer(g, yes: false) }
                            .buttonStyle(.glass)
                        Button("Yes") { answer(g, yes: true) }
                            .buttonStyle(.glassProminent)
                            .tint(Palette.prominent)
                            .foregroundStyle(Palette.onProminent)
                            .disabled(s.seatsLeft == 0)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .disabled(working)
                }
            }
            if !coming.isEmpty {
                Text("Coming").eyebrow().padding(.top, 6)
                ForEach(coming) { g in
                    GuestRow(guest: g) {
                        Text(g.payment == SeatPayment.unpaid.rawValue ? "Paying" : g.payment == SeatPayment.paid.rawValue ? "Paid" : "At the door")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(g.payment == SeatPayment.unpaid.rawValue ? Palette.muted : Palette.live)
                    }
                }
            }
        }
    }

    // MARK: Afterwards

    private func table(_ s: SupperDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("At the table").eyebrow()
            ForEach(s.table) { mate in
                HStack(spacing: 10) {
                    Initials(name: mate.displayName, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mate.displayName).font(.system(size: 15, weight: .semibold))
                        Text(mate.isHost ? "Host" : mate.isFriend ? "Friend" : mate.saidHi ? "You said hi" : "Guest")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 6)
                    if (s.isMine || mate.isHost) && !mate.reviewed {
                        Button("Review") { reviewing = mate }
                            .buttonStyle(.glass)
                    }
                    if !mate.isFriend && !mate.saidHi {
                        Button("Add") { add(mate, at: s) }
                            .buttonStyle(.glassProminent)
                            .tint(Palette.prominent)
                            .foregroundStyle(Palette.onProminent)
                            .disabled(working)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
            }
            Text("Add someone and you're friends once they add you too.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
        }
        .padding(14)
        .card()
    }

    // MARK: The button

    @ViewBuilder
    private func action(_ s: SupperDTO, stage: SeatStage, now: Date) -> some View {
        VStack(spacing: 8) {
            if let line = SupperCopy.stageLine(stage, host: s.host.displayName, waiting: s.waiting) {
                Text(line)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.soft)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch stage {
            case .open:
                Button("Ask for a seat · \(Pricing.format(s.seatTotalCents))") { asking = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(working)
            case .asked:
                Button("Stop asking") { backOut(s) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(working)
            case .toPay(let by):
                Button(checkout.working ? "One moment…" : "Pay \(Pricing.format(s.mySeat?.totalCents ?? s.seatTotalCents))") { pay(s) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(checkout.working)
                if let line = SupperCopy.payBy(by, now: now) {
                    Text(line).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            case .going:
                Button("Give back my seat") { backingOut = true }
                    .font(.system(size: 14, weight: .semibold))
                    .disabled(working)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    // MARK: Doing things

    private func load() async {
        do {
            let s = try await Sync.supper(id, from: location.center)
            supper = s
            if s.isMine { guests = (try? await Sync.requests(for: s)) ?? guests }
            if SeatStage.of(s, now: .now) == .after, !s.isMine {
                Ledger.satAtSupper(host: SupperCopy.firstName(s.host.displayName), context: context)
            }
        } catch {
            if current == nil { missing = true }
        }
    }

    private func run(_ work: @escaping () async throws(APIError) -> Void) {
        working = true
        Task {
            await attempt($problem) { () throws(APIError) in try await work() }
            working = false
        }
    }

    private func ask(_ s: SupperDTO, note: String) {
        run { () throws(APIError) in
            supper = try await Sync.askForSeat(at: s, note: note, context: context)
        }
    }

    private func backOut(_ s: SupperDTO) {
        run { () throws(APIError) in supper = try await Sync.giveBackSeat(at: s) }
    }

    private func cancel(_ s: SupperDTO) {
        run { () throws(APIError) in
            supper = try await Sync.cancel(s)
            guests = []
        }
    }

    private func answer(_ g: GuestDTO, yes: Bool) {
        run { () throws(APIError) in
            guests = try await Sync.answer(g, yes: yes)
            supper = try await Sync.supper(id, from: location.center)
        }
    }

    private func pay(_ s: SupperDTO) {
        guard let seat = s.mySeat else { return }
        Task {
            await checkout.pay(
                start: { try await Sync.checkout(seat: seat.id) },
                settle: { await refreshPaid() }
            )
        }
    }

    /// Reads the supper back; true once your seat is paid.
    private func refreshPaid() async -> Bool {
        guard let fresh = try? await Sync.supper(id, from: location.center) else { return false }
        supper = fresh
        return fresh.mySeat?.payment == SeatPayment.paid.rawValue
    }

    private func review(_ mate: TableMateDTO, stars: Int, text: String, at s: SupperDTO) {
        run { () throws(APIError) in supper = try await Sync.review(mate, stars: stars, text: text, at: s) }
    }

    private func add(_ mate: TableMateDTO, at s: SupperDTO) {
        let here = location.center
        run { () throws(APIError) in
            _ = try await Sync.addFromTable(mate, at: s, around: here, context: context)
            supper = SupperBook.shared.supper(s.id) ?? supper
        }
    }

    private func directions(_ s: SupperDTO) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: s.coordinate))
        item.name = s.address ?? s.title
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

/// Someone's initials in a soft circle.
struct Initials: View {
    var name: String
    var size: CGFloat

    var body: some View {
        Text(Pins.initials(name))
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(Palette.onProminent)
            .frame(width: size, height: size)
            .background(Palette.prominent, in: .circle)
            .accessibilityLabel(name)
    }
}

/// A neighbor asking for a seat, as the host sees them: their line, suppers and reviews, and the buttons.
struct GuestRow<Trailing: View>: View {
    var guest: GuestDTO
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Initials(name: guest.guest.displayName, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(guest.guest.displayName + (guest.isFriend ? " · friend" : ""))
                        .font(.system(size: 15, weight: .semibold))
                    Text(SupperCopy.guestLine(attended: guest.suppersAttended, rating: guest.rating, reviews: guest.reviewCount))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 6)
                trailing
            }
            if !guest.note.isEmpty {
                Text("\u{201C}\(guest.note)\u{201D}")
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(guest.reviews.prefix(2).enumerated()), id: \.offset) { _, words in
                Text("From a host: \u{201C}\(words)\u{201D}")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .card(radius: 16)
    }
}

/// Asking for a seat: a line to the host, what a yes costs, and the rule for backing out.
struct AskSeatView: View {
    var supper: SupperDTO
    var onAsk: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        let host = SupperCopy.firstName(supper.host.displayName)
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(supper.title).font(.system(size: 20, weight: .bold))
                TextField("A line to \(host): who you are, anything you can't eat", text: $note, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(12)
                    .card(radius: 14)
                Text(SupperCopy.askLine(host: supper.host.displayName, totalCents: supper.seatTotalCents, inApp: supper.inApp,
                                        refundUntil: supper.refundUntil, now: .now))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Ask \(host) for a seat") {
                    onAsk(note)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(18)
            .background(Palette.bg)
            .navigationTitle("Ask for a seat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.bg)
    }
}

/// A review after the supper: of the host by a guest, or of a guest by the host.
struct SupperReviewView: View {
    var mate: TableMateDTO
    var isHost: Bool
    var onSend: (Int, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var stars = 5
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(isHost ? "How was supper at \(SupperCopy.firstName(mate.displayName))'s?" : "How was \(SupperCopy.firstName(mate.displayName)) as a guest?")
                    .font(.system(size: 20, weight: .bold))
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { i in
                        Button { stars = i } label: {
                            Image(systemName: i <= stars ? "star.fill" : "star")
                                .font(.system(size: 26))
                                .foregroundStyle(Palette.star)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(i) stars")
                    }
                }
                TextField(isHost ? "What was good" : "Other hosts see this", text: $text, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(12)
                    .card(radius: 14)
                Spacer()
                Button("Send") {
                    onSend(stars, text)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(18)
            .background(Palette.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .presentationBackground(Palette.bg)
    }
}
