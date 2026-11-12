import SwiftUI
import SwiftData

/// Pick a pickup slot (or a porch seat), then reserve.
/// Payment isn't wired up yet, so you pay the cook at pickup.
struct OrderView: View {
    var kitchen: Kitchen
    var drop: Drop
    @Binding var bag: [UUID: Int]
    /// Picked to start with: the slot a plan wants.
    var preferredSlot: Date? = nil
    /// Start with "eat on the porch" on: sitting down at the shared table.
    var preferPorch = false

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var slot: Date?
    @State private var porch = false
    @State private var placed: Order?
    @State private var reserving = false
    @State private var problem: String?
    /// Kept across taps, so retrying after a timeout sends the same order id
    /// and the server returns the first order instead of making a second.
    @State private var pendingID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if let placed {
                    ReservedView(order: placed) { dismiss() }
                } else {
                    form
                }
            }
            .background(Palette.bg)
            .navigationTitle(placed == nil ? "Your order" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if placed == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
            }
        }
        .presentationBackground(Palette.bg)
        .onAppear {
            if slot == nil, let preferredSlot, drop.slots.contains(preferredSlot) { slot = preferredSlot }
            if preferPorch, kitchen.porchTables > 0 { porch = true }
        }
    }

    private var form: some View {
        let now = Date.now
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(kitchen.name).display(22)
                VStack(spacing: 0) {
                    ForEach(lines, id: \.name) { line in
                        HStack {
                            Text("\(line.quantity)×").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Palette.muted)
                            Text(line.name).font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Text(Pricing.format(line.priceCents * line.quantity)).font(.system(size: 14, design: .monospaced))
                        }
                        .padding(.vertical, 10)
                        Divider().overlay(Palette.line)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pickup").eyebrow()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                        ForEach(drop.slots, id: \.self) { s in
                            let full = isFull(s)
                            let past = s.addingTimeInterval(15 * 60) < now
                            Button { slot = s } label: {
                                Text(s.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .strikethrough(full || past)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .foregroundStyle(slot == s ? Palette.accent : (full || past ? Palette.muted : Palette.ink))
                                    .background(slot == s ? Palette.accent.opacity(0.12) : Palette.surface, in: .rect(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(slot == s ? Palette.accent : Palette.line, lineWidth: slot == s ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(full || past)
                        }
                    }
                    if let firstFull = drop.slots.first(where: isFull) {
                        Text("\(firstFull.formatted(date: .omitted, time: .shortened)) is full. \(kitchen.cookName) hands out \(drop.perSlot) orders per slot.")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }
                if kitchen.porchTables > 0 {
                    Toggle(isOn: $porch) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Eat on the porch").font(.system(size: 15, weight: .semibold))
                            Text("\(kitchen.porchTables) tables, first come").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        }
                    }
                    .tint(Genre.play.color)
                    .padding(14)
                    .card()
                }
                Label("The exact pickup spot shows after you reserve.", systemImage: "lock.fill")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
                VStack(spacing: 6) {
                    row("Food", Pricing.format(subtotal))
                    row("Service", Pricing.format(Pricing.serviceFee(for: subtotal)))
                    row("Total", Pricing.format(subtotal + Pricing.serviceFee(for: subtotal)), bold: true)
                    Text("Pay \(kitchen.cookName) at pickup. In-app payment comes later.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(18)
        }
        .safeAreaInset(edge: .bottom) {
            Button(reserving ? "Reserving…" : "Reserve") { reserve() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(slot == nil || lines.isEmpty || reserving)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Palette.bg)
        }
        .errorAlert($problem)
        .onAppear {
            if slot == nil { slot = drop.slots.first { !isFull($0) && $0.addingTimeInterval(15 * 60) >= now } }
        }
    }

    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).font(.system(size: 15, weight: bold ? .bold : .regular, design: .monospaced))
        }
        .font(.system(size: 15, weight: bold ? .bold : .regular))
    }

    private var lines: [OrderLine] {
        kitchen.sortedMenu.compactMap { item in
            guard let q = bag[item.id], q > 0 else { return nil }
            return OrderLine(name: item.name, priceCents: item.priceCents, quantity: q)
        }
    }

    private var subtotal: Int { lines.reduce(0) { $0 + $1.priceCents * $1.quantity } }

    private func isFull(_ s: Date) -> Bool {
        let booked = kitchen.orders.filter { $0.pickupAt == s }.count
        return booked >= drop.perSlot
    }

    private func reserve() {
        guard let slot else { return }
        let order = Order(pickupAt: slot, lines: lines, eatOnPorch: porch)
        if let pendingID { order.id = pendingID } else { pendingID = order.id }
        let picked = kitchen.sortedMenu.compactMap { item in
            bag[item.id].flatMap { $0 > 0 ? (item: item, quantity: $0) : nil }
        }
        reserving = true
        Task {
            await attempt($problem) { () throws(APIError) in
                try await Sync.reserve(order, picked: picked, at: kitchen, drop: drop, context: context)
                bag = [:]
                pendingID = nil
                withAnimation { placed = order }
            }
            reserving = false
        }
    }
}

struct ReservedView: View {
    var order: Order
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(Genre.play.color)
                .padding(.top, 20)
            Text("Reserved").display(30)
            Text("Pick up \(When.short(order.pickupAt, now: .now)) from \(order.kitchen?.cookName ?? "the cook").")
                .font(.system(size: 17))
            if let note = order.kitchen?.pickupNote, !note.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Where to go", systemImage: "lock.open.fill").eyebrow(Palette.accent)
                    Text(note).font(.system(size: 16, weight: .semibold))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            if order.eatOnPorch {
                Label("A porch seat's yours if one's open when you get there.", systemImage: "chair.lounge")
                    .font(.system(size: 14)).foregroundStyle(Palette.muted)
            }
            Text("It's at the top of Plans until pickup. Mark it picked up there; the review waits in Home kitchens → Your orders.")
                .font(.system(size: 14)).foregroundStyle(Palette.muted)
            Spacer()
            Button("Done", action: done).buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
    }
}
