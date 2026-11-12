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
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Text("Sell what you're good at making to people a few blocks away. You post a drop (a set batch, ready at a set time, at your price); people reserve a pickup slot and collect it at your door.")
                    .font(.system(size: 14)).foregroundStyle(Palette.muted)
            }
            Section("Your kitchen") {
                TextField("Name, like \"Back Gate Ice Cream\"", text: $name)
                TextField("What you make, like \"Ice cream\"", text: $cuisine)
                TextField("A line about it", text: $story, axis: .vertical).lineLimit(2...4)
            }
            .onChange(of: name) { _, v in name = KitchenLimits.clip(v, KitchenLimits.name) }
            .onChange(of: cuisine) { _, v in cuisine = KitchenLimits.clip(v, KitchenLimits.cuisine) }
            .onChange(of: story) { _, v in story = KitchenLimits.clip(v, KitchenLimits.story) }
            .onChange(of: pickupNote) { _, v in pickupNote = KitchenLimits.clip(v, KitchenLimits.pickupNote) }
            Section {
                TextField("Where to pick up, like \"Blue back gate off the alley\"", text: $pickupNote, axis: .vertical)
                Stepper(porchTables == 0 ? "No seating" : "\(porchTables) porch tables", value: $porchTables, in: 0...8)
            } header: {
                Text("Pickup")
            } footer: {
                Text(location.isUsingFallback
                     ? "Your kitchen sits on the map where you are now, so Let's Go needs your location first. Turn it on in Settings."
                     : "Your kitchen sits on the map where you are now. The pickup note only shows to people who've reserved.")
            }
            Section {
                Toggle("I have a home kitchen permit for my county", isOn: $permit)
                Toggle("I have a food handler card", isOn: $handlerCard)
            } header: {
                Text("Permits")
            } footer: {
                Text("Selling food from home needs a permit in most places. In California that's a MEHKO (microenterprise home kitchen) permit, where your county offers one; cottage-food rules elsewhere usually don't cover dairy or full meals.")
            }
            Section {
                Button("Open my kitchen") { open() }
                    .fontWeight(.bold)
                    .disabled(opening || location.isUsingFallback || name.trimmingCharacters(in: .whitespaces).isEmpty || cuisine.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Open your kitchen")
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
    @State private var problem: String?
    /// Everyone's orders here, from the server.
    @State private var orders: [OrderDTO]?
    @State private var ordersProblem: String?

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
                }
                stats
                if let ordersProblem {
                    Text(ordersProblem).font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
                dropSection(now: now)
                if let tip = tip(now: now) { TipNote(text: tip) }
                menuSection
                checklist
            }
            .padding(18)
        }
        .sheet(isPresented: $addingItem) { AddMenuItemView(kitchen: kitchen) }
        .sheet(isPresented: $postingDrop) { PostDropView(kitchen: kitchen) }
        .errorAlert($problem)
        .task {
            await Sync.refreshQuietly(kitchen, context: context)
            do {
                orders = try await Sync.kitchenOrders(kitchen)
                ordersProblem = nil
            } catch {
                ordersProblem = "Couldn't load your orders. \(error.errorDescription ?? "")"
            }
        }
    }

    /// Picked up (or reviewed): sold. From the server when it has your kitchen; a phone-only
    /// kitchen has nobody else ordering from it.
    private var stats: some View {
        let done = (orders ?? []).filter { $0.status != "reserved" }
        let items = done.reduce(0) { total, o in total + o.lines.reduce(0) { $0 + $1.quantity } }
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
            if let drop = kitchen.nextDrop(after: now) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(drop.isLive(at: now) ? "On now" : When.short(drop.start, now: now)).font(.system(size: 15, weight: .bold))
                        Spacer()
                        Text("\(drop.sold) / \(drop.total) reserved").font(.label).foregroundStyle(Genre.food.color)
                    }
                    LeftBar(left: drop.left, total: drop.total)
                    let upcoming = (orders ?? []).filter { $0.status == "reserved" && $0.dropId == drop.remoteID }
                        .sorted { $0.pickupAt < $1.pickupAt }
                    if upcoming.isEmpty {
                        Text("No pickups reserved yet.").font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }
                    ForEach(upcoming, id: \.id) { o in
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
                Label("Post a drop", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(kitchen.menu.isEmpty || !permitted)
            if kitchen.menu.isEmpty {
                Text("Add something to the menu first.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            } else if !permitted {
                Text("Tick your permit and food handler card in the checklist first.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            } else {
                Text("A drop is a set batch, ready at a set time. Neighbors reserve a 15-minute pickup slot.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
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
            check("Home kitchen permit", kitchen.permitConfirmed) {
                savePermits(permit: !kitchen.permitConfirmed, card: kitchen.handlerCardConfirmed)
            }
            check("Food handler card", kitchen.handlerCardConfirmed) {
                savePermits(permit: kitchen.permitConfirmed, card: !kitchen.handlerCardConfirmed)
            }
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

    /// Only a kitchen with both can post drops (the server checks too).
    private var permitted: Bool { kitchen.permitConfirmed && kitchen.handlerCardConfirmed }

    /// Ticks on the phone only once the server has them, so a failed save doesn't leave a box ticked.
    private func savePermits(permit: Bool, card: Bool) {
        Task {
            await attempt($problem) { () throws(APIError) in
                try await Sync.savePermits(kitchen, permit: permit, card: card, context: context)
            }
        }
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
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .onChange(of: name) { _, v in name = KitchenLimits.clip(v, KitchenLimits.itemName) }
                TextField("A short note (optional)", text: $note)
                    .onChange(of: note) { _, v in note = KitchenLimits.clip(v, KitchenLimits.itemNote) }
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
                        saving = true
                        Task {
                            await attempt($problem) { () throws(APIError) in
                                try await Sync.add(item, to: kitchen, context: context)
                                dismiss()
                            }
                            saving = false
                        }
                    }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
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
    @State private var saving = false

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
                        saving = true
                        Task {
                            await attempt($problem) { () throws(APIError) in
                                try await Sync.post(d, to: kitchen, context: context)
                                dismiss()
                            }
                            saving = false
                        }
                    }
                    .disabled(saving)
                }
            }
            .errorAlert($problem)
        }
        .presentationDetents([.medium])
    }
}
