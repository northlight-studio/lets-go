import SwiftUI
import SwiftData

/// A batch's listing, the page a neighbor sees: the photo, what it is, the kitchen (walk, rating,
/// regulars, Follow), how many are left, allergens and diets, a review, and Reserve. Once you've
/// reserved, the button opens your pickup instead.
struct BatchView: View {
    @Bindable var drop: Drop
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @State private var reserving = false
    @State private var following = false
    @State private var problem: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BatchPhoto(path: drop.photoURL, title: drop.title, height: 300)
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(drop.isLive(at: now) ? "On now · until \(BatchCopy.hour(drop.end))" : BatchCopy.window(drop.start, drop.end, now: now))
                                .eyebrow(drop.isLive(at: now) ? Palette.accentSoft : Palette.muted)
                            Text(drop.title).display(28)
                            Text(BatchCopy.price(drop.priceCents, unit: drop.unit))
                                .font(.system(size: 17, weight: .semibold))
                                .monospacedDigit()
                        }
                        if let k = drop.kitchen { seller(k) }
                        left
                        if !drop.tags.isEmpty { tags }
                        if let k = drop.kitchen, !k.quote.isEmpty { quote(k) }
                        if let k = drop.kitchen, k.permitConfirmed, k.handlerCardConfirmed {
                            Label("Home kitchen permit on file", systemImage: "checkmark.seal")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.muted)
                        }
                        if let k = drop.kitchen {
                            Label(k.isMine ? "Your address shows to people once they've reserved." : "The exact address shows once you've reserved.", systemImage: "lock.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                }
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: .top)
            .scrollIndicators(.hidden)
            .background(Palette.bg)
            .safeAreaInset(edge: .bottom) { action(now: now) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $reserving) { ReserveBatchView(drop: drop) }
        .errorAlert($problem)
        .task {
            if let k = drop.kitchen { try? await Sync.refresh(k, context: context) }
            try? await Sync.refresh(batch: drop, context: context)
        }
    }

    private func seller(_ k: Kitchen) -> some View {
        HStack(spacing: 10) {
            Text(String(k.cookName.prefix(1)))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.onProminent)
                .frame(width: 38, height: 38)
                .background(Palette.prominent, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(k.name).font(.system(size: 16, weight: .semibold))
                Text(BatchCopy.kitchenLine(
                    walkMinutes: Walk.minutes(location.center.distance(to: k.coordinate)),
                    rating: k.rating, reviews: k.reviewCount, regulars: k.regulars
                ))
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
            }
            Spacer(minLength: 6)
            if !k.isMine {
                Button(k.isFollowing ? "Following" : "Follow") { follow(k) }
                    .buttonStyle(.glass)
                    .font(.system(size: 13, weight: .semibold))
                    .disabled(following || k.remoteID == nil)
                    .accessibilityHint(k.isFollowing ? "Stop hearing about new batches" : "Hear when this kitchen posts a new batch")
            }
        }
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BatchCopy.left(drop.left, of: drop.total, unit: drop.unit))
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
            LeftBar(left: drop.left, total: drop.total, color: drop.isSoldOut ? Palette.muted : Palette.ink)
        }
    }

    private var tags: some View {
        FlowLayout(spacing: 6) {
            ForEach(drop.tags, id: \.self) { t in
                Text(t)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .foregroundStyle(Palette.soft)
                    .background(Palette.raise, in: .capsule)
            }
        }
    }

    private func quote(_ k: Kitchen) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\u{201C}\(k.quote)\u{201D}")
                .font(.system(size: 15))
                .fixedSize(horizontal: false, vertical: true)
            Text(k.quoteAuthor).font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 16)
    }

    @ViewBuilder
    private func action(now: Date) -> some View {
        let mine = drop.kitchen?.orders.filter { $0.status != .reviewed && drop.slots.contains($0.pickupAt) && $0.payment.isLive } ?? []
        Group {
            if let k = drop.kitchen, k.isMine {
                NavigationLink {
                    MyKitchenView()
                } label: {
                    Text("\(drop.sold) of \(drop.total) reserved · See orders")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else if let order = mine.first {
                NavigationLink {
                    OrderStatusView(order: order)
                } label: {
                    Text(order.payment == .unpaid ? "Finish paying" : "Your pickup · \(BatchCopy.ready(order.pickupAt))")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else if drop.end <= now {
                Text("This batch is over.").font(.system(size: 15)).foregroundStyle(Palette.muted)
            } else if drop.isSoldOut {
                Text(drop.kitchen?.isFollowing == true ? "Sold out. You'll hear about the next one." : "Sold out. Follow to hear about the next one.")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.muted)
            } else {
                Button(BatchCopy.reserve(quantity: 1, unit: drop.unit, totalCents: unitTotal, pay: drop.kitchen?.pay ?? .atPickup)) {
                    reserving = true
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private var unitTotal: Int {
        let pay = drop.kitchen?.pay ?? .atPickup
        return drop.priceCents + (pay == .inApp ? Pricing.serviceFee(for: drop.priceCents) : 0)
    }

    private func follow(_ k: Kitchen) {
        following = true
        Task {
            await attempt($problem) { () throws(APIError) in try await Sync.follow(k, !k.isFollowing, context: context) }
            following = false
        }
    }
}

/// Reserve from a batch: how many and when, then pay (in the app, or at pickup), then your pickup.
struct ReserveBatchView: View {
    var drop: Drop
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var quantity = 1
    @State private var slot: Date?
    @State private var order: Order?
    @State private var reserving = false
    @State private var problem: String?
    @State private var checkout = PayFlow()
    /// Made once per attempt and reused on retry: the server returns the first order, not a second.
    @State private var orderID = UUID()

    private var pay: PayMode { drop.kitchen?.pay ?? .atPickup }
    private var cook: String { drop.kitchen?.cookName ?? "the cook" }

    var body: some View {
        NavigationStack {
            Group {
                if let order, order.payment != .unpaid {
                    PickupView(order: order, onDone: { dismiss() })
                } else {
                    form
                }
            }
            .background(Palette.bg)
            .navigationTitle(order == nil ? "Reserve" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if order == nil || order?.payment == .unpaid {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
            }
            .errorAlert($problem)
            .errorAlert($checkout.problem)
        }
        .presentationBackground(Palette.bg)
        .checkoutSheet(checkout, context: context)
    }

    private var form: some View {
        let now = Date.now
        let open = BatchSlots.open(start: drop.start, end: drop.end, full: drop.fullSlots, now: now)
        let subtotal = drop.priceCents * quantity
        let service = pay == .inApp ? Pricing.serviceFee(for: subtotal) : 0
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    BatchPhoto(path: drop.photoURL, title: drop.title, height: 64, radius: 14)
                        .frame(width: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(drop.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                        Text(BatchCopy.price(drop.priceCents, unit: drop.unit)).font(.system(size: 14)).foregroundStyle(Palette.muted)
                    }
                }
                if order == nil {
                    HStack {
                        Text("How many").font(.system(size: 15))
                        Spacer()
                        Stepperish(count: quantity, max: min(drop.left, 10)) { quantity = max(1, $0) }
                        Text(BatchCopy.count(quantity, drop.unit))
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                    .padding(14)
                    .card()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pick up at").eyebrow()
                        if open.isEmpty {
                            Text("Every pickup time is full.").font(.system(size: 14)).foregroundStyle(Palette.muted)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                            ForEach(open, id: \.self) { s in
                                Button { slot = s } label: {
                                    Text(s.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 14, weight: .semibold))
                                        .monospacedDigit()
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .foregroundStyle(slot == s ? Palette.onProminent : Palette.ink)
                                        .background(slot == s ? Palette.prominent : Palette.card, in: .rect(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(slot == s ? .isSelected : [])
                            }
                        }
                    }
                }
                VStack(spacing: 6) {
                    line(BatchCopy.count(order?.itemCount ?? quantity, drop.unit), Pricing.format(order?.subtotalCents ?? subtotal))
                    if pay == .inApp { line("Service", Pricing.format(order?.serviceCents ?? service)) }
                    line(pay == .inApp ? "Total" : "Total, paid at pickup", Pricing.format(order?.totalCents ?? subtotal + service), bold: true)
                }
                Text(order == nil
                     ? BatchCopy.payLine(pay: pay, cook: cook, totalCents: subtotal + service)
                     : BatchCopy.receipt(.unpaid, totalCents: order?.totalCents ?? 0, cook: cook))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if let order {
                    Button(checkout.working ? "One moment…" : "Pay \(Pricing.format(order.totalCents))") {
                        Task { await checkout.pay(order, context: context) }
                    }
                    .disabled(checkout.working)
                } else {
                    Button(reserving ? "Reserving…" : BatchCopy.reserve(quantity: quantity, unit: drop.unit, totalCents: subtotal + service, pay: pay)) {
                        reserve()
                    }
                    .disabled(reserving || slot == nil || drop.left < quantity)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .onAppear {
            if slot == nil { slot = open.first }
            quantity = min(max(1, quantity), max(1, drop.left))
        }
    }

    private func line(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 15, weight: bold ? .bold : .regular))
    }

    private func reserve() {
        guard let slot else { return }
        reserving = true
        let id = orderID
        let q = quantity
        Task {
            await attempt($problem) { () throws(APIError) in
                let placed = try await Sync.reserve(q, of: drop, at: slot, orderID: id, context: context)
                withAnimation { order = placed }
            }
            reserving = false
            if let order, order.payment == .unpaid {
                await checkout.pay(order, context: context)
            }
        }
    }
}
