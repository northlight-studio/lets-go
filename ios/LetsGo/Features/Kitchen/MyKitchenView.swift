import SwiftUI
import SwiftData

/// The seller side: set up your kitchen, keep the menu, post drops.
struct MyKitchenView: View {
    @Query(filter: #Predicate<Kitchen> { $0.isMine }) private var mine: [Kitchen]

    var body: some View {
        Group {
            if let kitchen = mine.first {
                KitchenDashboard(kitchen: kitchen)
            } else {
                OpenKitchenForm()
            }
        }
        .background(Palette.bg)
    }
}

private struct OpenKitchenForm: View {
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var cuisine = ""
    @State private var story = ""
    @State private var pickupNote = ""
    @State private var porchTables = 0
    @State private var permit = false
    @State private var handlerCard = false
    @State private var opening = false
    @State private var selling = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Text("Sell what you're good at making to people a few blocks away. You set the batch, the time and the price; people reserve and pick up at your door.")
                    .font(.system(size: 14)).foregroundStyle(Palette.muted)
                Button { selling = true } label: { Label("Sell something", systemImage: "camera") }
                    .fontWeight(.semibold)
            } footer: {
                Text("Just one batch? Post it and your kitchen opens with your name. Or set up a whole kitchen below.")
            }
            Section("Your kitchen") {
                TextField("Name, like \"Back Gate Ice Cream\"", text: $name)
                TextField("What you make, like \"Ice cream\"", text: $cuisine)
                TextField("A line about it", text: $story, axis: .vertical).lineLimit(2...4)
            }
            Section {
                TextField("Where to pick up, like \"Blue back gate off the alley\"", text: $pickupNote, axis: .vertical)
                Stepper(porchTables == 0 ? "No seating" : "\(porchTables) porch tables", value: $porchTables, in: 0...8)
            } header: {
                Text("Pickup")
            } footer: {
                Text("Your kitchen sits on the map where you are now. The pickup note only shows to people who've reserved.")
            }
            Section {
                Toggle("I have a home kitchen permit for my county", isOn: $permit)
                Toggle("I have a food handler card", isOn: $handlerCard)
            } header: {
                Text("Permits")
            } footer: {
                Text("Selling food from home needs a permit in most places. In California that's a MEHKO permit, where your county offers one; cottage-food rules elsewhere usually don't cover dairy or full meals.")
            }
            Section {
                Button("Open my kitchen") { open() }
                    .fontWeight(.bold)
                    .disabled(opening || name.trimmingCharacters(in: .whitespaces).isEmpty || cuisine.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Open your kitchen")
        .sheet(isPresented: $selling) { SellView() }
        .errorAlert($problem)
    }

    private func open() {
        let k = Kitchen(
            name: name.trimmingCharacters(in: .whitespaces),
            cookName: "You",
            cuisine: cuisine.trimmingCharacters(in: .whitespaces),
            story: story,
            coordinate: location.center,
            pickupNote: pickupNote,
            porchTables: porchTables,
            isMine: true
        )
        k.permitConfirmed = permit
        k.handlerCardConfirmed = handlerCard
        opening = true
        Task {
            await attempt($problem) { () throws(APIError) in try await Sync.open(k, context: context) }
            opening = false
        }
    }
}

private struct KitchenDashboard: View {
    @Bindable var kitchen: Kitchen
    @Environment(\.modelContext) private var context
    @State private var addingItem = false
    @State private var postingDrop = false
    @State private var selling = false
    @State private var problem: String?
    /// Every confirmed order on the kitchen, from the server, with names and codes.
    @State private var orders: [OrderDTO] = []
    @State private var handing: Set<UUID> = []
    @State private var payouts: PayoutsDTO?
    @Environment(\.openURL) private var openURL

    var body: some View {
        let now = Date.now
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your kitchen").eyebrow()
                    Text(kitchen.name).display(26)
                    if let r = kitchen.rating {
                        HStack(spacing: 5) { Stars(value: r); Text(String(format: "%.1f · %d reviews", r, kitchen.reviewCount)) }
                            .font(.system(size: 13))
                    }
                    if kitchen.followers > 0 {
                        Text("\(kitchen.followers) follower\(kitchen.followers == 1 ? "" : "s")")
                            .font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }
                }
                Button { selling = true } label: { Label("Sell something", systemImage: "camera") }
                    .buttonStyle(PrimaryButtonStyle())
                ForEach(batches(now: now)) { batchCard($0, now: now) }
                payoutsCard
                stats
                dropSection(now: now)
                if let tip = tip(now: now) { TipNote(text: tip) }
                menuSection
                checklist
            }
            .padding(18)
        }
        .sheet(isPresented: $addingItem) { AddMenuItemView(kitchen: kitchen) }
        .sheet(isPresented: $postingDrop) { PostDropView(kitchen: kitchen) }
        .sheet(isPresented: $selling, onDismiss: { Task { await load() } }) { SellView() }
        .errorAlert($problem)
        .refreshable { await load() }
        .task {
            try? await Sync.refresh(kitchen, context: context)
            await load()
        }
    }

    private func load() async {
        guard kitchen.remoteID != nil else { return }
        if let o = try? await Sync.kitchenOrders() { orders = o }
        if let p = try? await Sync.payouts() { payouts = p }
        for d in batches(now: .now) { try? await Sync.refresh(batch: d, context: context) }
    }

    // MARK: Batches

    /// Your batches still to come or on now, soonest first.
    private func batches(now: Date) -> [Drop] {
        kitchen.drops.filter { $0.isBatch && $0.end > now }.sorted { $0.start < $1.start }
    }

    private func batchCard(_ drop: Drop, now: Date) -> some View {
        let mine = orders.filter { $0.dropId == drop.remoteID }
        let waiting = mine.filter { $0.status == "reserved" }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BatchPhoto(path: drop.photoPath, title: drop.title, height: 64, radius: 14).frame(width: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(drop.isLive(at: now) ? "Live now" : BatchCopy.window(drop.start, drop.end, now: now))
                        .eyebrow(drop.isLive(at: now) ? Palette.accentSoft : Palette.muted)
                    Text(drop.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    Text("\(drop.sold) of \(BatchCopy.count(drop.total, drop.unit)) sold · \(BatchCopy.price(drop.priceCents, unit: drop.unit))")
                        .font(.system(size: 13)).foregroundStyle(Palette.muted).monospacedDigit()
                }
            }
            LeftBar(left: drop.left, total: drop.total)
            if mine.isEmpty {
                Text("No orders yet. They show here with each buyer's pickup code.")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(mine.enumerated()), id: \.element.id) { i, o in
                        orderRow(o)
                        if i < mine.count - 1 { Divider().overlay(Palette.line) }
                    }
                }
                if waiting.isEmpty {
                    Text("Everyone's picked up.").font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
            }
        }
        .padding(14)
        .card()
    }

    private func orderRow(_ o: OrderDTO) -> some View {
        let qty = o.lines.reduce(0) { $0 + $1.quantity }
        let done = o.status != "reserved"
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(o.buyerName ?? "Someone") · \(BatchCopy.count(qty, o.unit ?? ""))")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(o.pickupAt.formatted(date: .omitted, time: .shortened)) · \(o.payment == PaymentState.paid.rawValue ? "paid" : "pays \(Pricing.format(o.totalCents)) at pickup")")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 6)
            Text(BatchCopy.spoken(o.pickupCode ?? ""))
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(done ? Palette.muted : Palette.ink)
                .accessibilityLabel("Code \(BatchCopy.spoken(o.pickupCode ?? ""))")
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.live)
                    .accessibilityLabel("Picked up")
            } else {
                Button("Picked up") { handOver(o) }
                    .buttonStyle(.glass)
                    .font(.system(size: 13, weight: .semibold))
                    .disabled(handing.contains(o.id))
                    .accessibilityLabel("Mark \(o.buyerName ?? "this order") picked up")
            }
        }
        .padding(.vertical, 9)
    }

    private func handOver(_ o: OrderDTO) {
        handing.insert(o.id)
        Task {
            await attempt($problem) { () throws(APIError) in
                let done = try await Sync.handOver(o.id, code: nil)
                if let i = orders.firstIndex(where: { $0.id == done.id }) { orders[i] = done }
            }
            handing.remove(o.id)
        }
    }

    // MARK: Payouts

    @ViewBuilder
    private var payoutsCard: some View {
        if let p = payouts {
            VStack(alignment: .leading, spacing: 8) {
                Text("Payments").eyebrow()
                if !p.enabled {
                    Text("Buyers pay you at pickup. Paying in the app isn't switched on yet.")
                        .font(.system(size: 14)).foregroundStyle(Palette.soft)
                } else if p.ready {
                    Label("Buyers pay in the app. Stripe sends it to your bank.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14)).foregroundStyle(Palette.live)
                } else {
                    Text("Buyers pay you at pickup until you set up payouts. Stripe asks for your name, date of birth and a bank account.")
                        .font(.system(size: 14)).foregroundStyle(Palette.soft)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set up payouts") { setUpPayouts() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    private func setUpPayouts() {
        Task {
            await attempt($problem) { () throws(APIError) in
                let p = try await Sync.setUpPayouts()
                payouts = p
                if let link = p.onboardingUrl.flatMap { URL(string: $0) } { openURL(link) }
            }
        }
    }

    /// Handed over so far, from the server's orders (what the cook gets: the food, not the service fee).
    private var stats: some View {
        let done = orders.filter { $0.status != "reserved" }
        let items = done.reduce(0) { $0 + $1.lines.reduce(0) { $0 + $1.quantity } }
        let paid = done.reduce(0) { $0 + $1.subtotalCents }
        return HStack(spacing: 8) {
            stat("\(items)", "sold")
            stat(Pricing.format(paid), "earned")
            stat("\(done.count)", "orders")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).display(20).monospacedDigit()
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 14)
    }

    @ViewBuilder
    private func dropSection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drops").eyebrow()
            // Drops off the menu; batches have their own cards above.
            if let drop = kitchen.drops.filter({ !$0.isBatch && $0.end > now }).min(by: { $0.start < $1.start }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(drop.isLive(at: now) ? "On now" : When.short(drop.start, now: now)).font(.system(size: 15, weight: .bold))
                        Spacer()
                        Text("\(drop.sold) / \(drop.total) reserved").font(.label).foregroundStyle(Genre.food.color)
                    }
                    LeftBar(left: drop.left, total: drop.total)
                    let upcoming = kitchen.orders.filter { $0.status == .reserved }.sorted { $0.pickupAt < $1.pickupAt }
                    ForEach(upcoming) { o in
                        HStack {
                            Text(o.pickupAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 13, design: .monospaced))
                            Text(o.lines.map { "\($0.quantity)× \($0.name)" }.joined(separator: ", ")).font(.system(size: 13)).lineLimit(1)
                        }
                        .foregroundStyle(Palette.muted)
                    }
                }
                .padding(14)
                .card()
            }
            Button {
                postingDrop = true
            } label: {
                Label("Post a drop from the menu", systemImage: "plus")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(kitchen.menu.isEmpty)
            if kitchen.menu.isEmpty {
                Text("Add something to the menu first.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }
    }

    private var menuSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Menu").eyebrow()
                Spacer()
                Button("Add") { addingItem = true }.font(.system(size: 14, weight: .semibold))
            }
            .padding(.bottom, 6)
            ForEach(kitchen.sortedMenu) { item in
                HStack {
                    Text(item.name).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(Pricing.format(item.priceCents)).font(.system(size: 14, design: .monospaced))
                }
                .padding(.vertical, 10)
                .contextMenu {
                    Button("Remove", role: .destructive) {
                        Task { await attempt($problem) { () throws(APIError) in try await Sync.remove(item, context: context) } }
                    }
                }
                Divider().overlay(Palette.line)
            }
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Checklist").eyebrow()
            check("Home kitchen permit", kitchen.permitConfirmed) { kitchen.permitConfirmed.toggle(); savePermits() }
            check("Food handler card", kitchen.handlerCardConfirmed) { kitchen.handlerCardConfirmed.toggle(); savePermits() }
            check("Something on the menu", !kitchen.menu.isEmpty, action: nil)
        }
    }

    private func check(_ label: String, _ done: Bool, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            HStack(spacing: 9) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(done ? Genre.play.color : Palette.muted)
                Text(label).foregroundStyle(done ? Palette.ink : Palette.muted)
            }
            .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private func savePermits() {
        Task { await attempt($problem) { () throws(APIError) in try await Sync.savePermits(kitchen, context: context) } }
    }

    /// One suggestion from how the last finished drop went.
    private func tip(now: Date) -> String? {
        guard let last = kitchen.drops.filter({ $0.end <= now }).max(by: { $0.end < $1.end }) else {
            return kitchen.menu.isEmpty ? nil : "First drops do best small and soon. Try 12 at dinner time tomorrow."
        }
        if last.isSoldOut {
            return "Your last drop **sold out**. Make about \(Int((Double(last.total) * 1.3).rounded())) next time."
        }
        if last.total > 0, Double(last.sold) / Double(last.total) < 0.5 {
            return "Last drop moved **\(last.sold) of \(last.total)**. A smaller batch or an earlier time might sell through."
        }
        return nil
    }
}

private struct AddMenuItemView: View {
    var kitchen: Kitchen
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""
    @State private var price = 10.0
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("A short note (optional)", text: $note)
                Stepper("Price: \(Pricing.format(Int(price * 100)))", value: $price, in: 1...200, step: 0.5)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle("Add to menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let item = MenuItem(name: name.trimmingCharacters(in: .whitespaces), note: note, priceCents: Int(price * 100), sortIndex: kitchen.menu.count)
                        Task {
                            await attempt($problem) { () throws(APIError) in
                                try await Sync.add(item, to: kitchen, context: context)
                                dismiss()
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .errorAlert($problem)
        }
        .presentationDetents([.medium])
    }
}

private struct PostDropView: View {
    var kitchen: Kitchen
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date.now.addingTimeInterval(2 * 3600)
    @State private var hours = 1.5
    @State private var total = 12
    @State private var perSlot = 4
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Starts", selection: $start, in: Date.now...)
                Stepper(String(format: "Open for %.1f hours", hours), value: $hours, in: 0.5...6, step: 0.5)
                Stepper("\(total) to sell", value: $total, in: 1...200)
                Stepper("\(perSlot) pickups per 15 min", value: $perSlot, in: 1...20)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle("Post a drop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") {
                        let d = Drop(start: start, end: start.addingTimeInterval(hours * 3600), total: total, perSlot: perSlot)
                        Task {
                            await attempt($problem) { () throws(APIError) in
                                try await Sync.post(d, to: kitchen, context: context)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .errorAlert($problem)
        }
        .presentationDetents([.medium])
    }
}
