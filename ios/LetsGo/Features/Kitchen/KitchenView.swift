import SwiftUI
import SwiftData

/// A house that's a restaurant today: the photo, the drop, the menu, the reviews. A kitchen whose
/// next drop is a batch ("Sell something") opens on the batch's listing instead.
struct KitchenView: View {
    @Bindable var kitchen: Kitchen
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @Query private var people: [Person]
    @State private var bag: [UUID: Int] = [:]
    @State private var ordering = false
    /// Sitting down with a friend: the slot and the porch, picked for you.
    @State private var sitAt: Date?

    var body: some View {
        if let batch = kitchen.nextDrop(after: .now), batch.isBatch {
            BatchView(drop: batch)
        } else {
            menuPage
        }
    }

    private var menuPage: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            let drop = kitchen.nextDrop(after: now)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if kitchen.porchTables > 0 {
                        GarageArt(sign: "\(kitchen.cuisine)\ntonight")
                            .frame(height: 220)
                            .clipShape(.rect(cornerRadius: 20))
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    } else {
                        PhotoHero(kitchen: kitchen, height: 170, radius: 20)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        titleBlock
                        InfoStrip(items: facts(drop: drop, now: now))
                        if let drop { dropLine(drop, now: now) }
                        if let table = table(drop) { SharedTableCard(table: table, name: kitchen.porchTables > 0 ? "The porch table" : "The table") }
                        menu(drop: drop)
                        reviews
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Palette.bg)
            .safeAreaInset(edge: .bottom) {
                if let drop, !drop.isSoldOut, !kitchen.isMine {
                    HStack(spacing: 10) {
                        if let seat = table(drop)?.friends.first, table(drop)?.open ?? 0 > 0, seat.at > now {
                            Button("Sit with \(seat.friend.firstName) \u{00B7} \(NightPin.hour(seat.at))") { sit(at: seat.at, drop: drop) }
                                .buttonStyle(PrimaryButtonStyle())
                            Button("Pick up") { ordering = true }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(bagCount == 0)
                        } else {
                            Button(bagCount > 0 ? "Reserve \(bagCount) · \(Pricing.format(bagSubtotal))" : "Add something to reserve") { ordering = true }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(bagCount == 0)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
                }
            }
            .sheet(isPresented: $ordering, onDismiss: { sitAt = nil }) {
                if let drop {
                    OrderView(kitchen: kitchen, drop: drop, bag: $bag, preferredSlot: sitAt.flatMap { snap($0, in: drop) }, preferPorch: sitAt != nil)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await Sync.refreshQuietly(kitchen, context: context) }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(kitchen.name).display(28)
            Text(kitchen.story).font(.system(size: 15)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func facts(drop: Drop?, now: Date) -> [InfoStrip.Item] {
        var items: [InfoStrip.Item] = []
        if let r = kitchen.rating {
            items.append(.init(label: "\(kitchen.reviewCount) ratings", value: String(format: "%.1f", r), detail: String(repeating: "★", count: Int(r.rounded()))))
        } else {
            items.append(.init(label: "Ratings", value: "New", detail: "no reviews yet"))
        }
        items.append(.init(label: "Walk", value: "\(Walk.minutes(location.center.distance(to: kitchen.coordinate)))", detail: "minutes"))
        if let drop {
            items.append(.init(label: "Left", value: "\(drop.left)", detail: "of \(drop.total)"))
        } else {
            items.append(.init(label: "Next drop", value: "None", detail: "yet"))
        }
        return items
    }

    private func dropLine(_ drop: Drop, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(drop.isLive(at: now) ? "On now" : When.short(drop.start, now: now))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(drop.isLive(at: now) ? Palette.live : Palette.ink)
                Text("until \(drop.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 15)).foregroundStyle(Palette.muted)
                Spacer()
                if kitchen.porchTables > 0 {
                    Label("\(kitchen.porchTables) porch tables", systemImage: "chair.lounge")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            LeftBar(left: drop.left, total: drop.total, color: drop.isSoldOut ? Palette.muted : Palette.ink)
            if drop.isSoldOut {
                Text("Sold out. You'll see the next one here.").font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
        }
    }

    private func menu(drop: Drop?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu").eyebrow()
            VStack(spacing: 0) {
                ForEach(Array(kitchen.sortedMenu.enumerated()), id: \.element.id) { i, item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.system(size: 16, weight: .medium))
                            if !item.note.isEmpty { Text(item.note).font(.system(size: 13)).foregroundStyle(Palette.muted) }
                        }
                        Spacer()
                        Text(Pricing.format(item.priceCents)).font(.system(size: 15)).monospacedDigit().foregroundStyle(Palette.muted)
                        if let drop, !drop.isSoldOut, !kitchen.isMine {
                            Stepperish(count: bag[item.id] ?? 0, max: min(OrderLimits.perLine, drop.left - bagCount + (bag[item.id] ?? 0))) { bag[item.id] = $0 }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    if i < kitchen.menu.count - 1 { Divider().overlay(Palette.line).padding(.leading, 14) }
                }
            }
            .card()
        }
    }

    @ViewBuilder
    private var reviews: some View {
        // A server kitchen's list already includes anything you posted.
        let mine = kitchen.remoteID == nil ? kitchen.reviews.sorted { $0.createdAt > $1.createdAt } : []
        if !mine.isEmpty || !kitchen.sampleReviews.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reviews").eyebrow()
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(mine) { r in ReviewCard(stars: r.stars, text: r.text, author: r.isMine ? "You" : r.author, tags: r.tags) }
                        ForEach(kitchen.sampleReviews, id: \.self) { r in ReviewCard(stars: r.stars, text: r.text, author: r.author, tags: []) }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var bagCount: Int { bag.values.reduce(0, +) }

    private func table(_ drop: Drop?) -> SharedTable.Table? {
        SharedTable.table(
            seats: kitchen.porchTables, serverTaken: kitchen.tableTaken, serverFriends: kitchen.tableFriends,
            people: people.map(\.snapshot),
            drop: drop.map { (start: $0.start, end: $0.end) }
        )
    }

    /// Sit down with a friend: one of the first thing on the menu if the bag's empty, their slot, the porch.
    private func sit(at: Date, drop: Drop) {
        if bagCount == 0, let first = kitchen.sortedMenu.first { bag = [first.id: 1] }
        sitAt = at
        ordering = true
    }

    /// The pickup slot on the drop's grid at or just before a time.
    private func snap(_ at: Date, in drop: Drop) -> Date? {
        drop.slots.last { $0 <= at } ?? drop.slots.first
    }

    private var bagSubtotal: Int {
        kitchen.menu.reduce(0) { $0 + $1.priceCents * (bag[$1.id] ?? 0) }
    }
}

struct ReviewCard: View {
    var stars: Int
    var text: String
    var author: String
    var tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stars(value: Double(stars), size: 11)
            if !text.isEmpty {
                Text(text).font(.system(size: 14)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(tags.isEmpty ? author : "\(author) · \(tags.joined(separator: ", "))")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
        }
        .padding(14)
        .frame(width: 240, height: 128, alignment: .topLeading)
        .card(radius: 16)
    }
}

/// A compact minus / count / plus.
struct Stepperish: View {
    var count: Int
    var max: Int
    var onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if count > 0 {
                button("minus") { onChange(count - 1) }
                Text("\(count)").font(.system(size: 15, weight: .semibold)).monospacedDigit().frame(minWidth: 12)
            }
            button("plus") { onChange(count + 1) }.disabled(count >= max)
        }
        .sensoryFeedback(.selection, trigger: count)
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .background(symbol == "plus" ? Palette.accent.opacity(0.16) : Palette.raise, in: .circle)
                .foregroundStyle(symbol == "plus" ? Palette.accent : Palette.ink)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "Add one" : "Remove one")
    }
}
