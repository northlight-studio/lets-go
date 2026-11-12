import SwiftUI
import SwiftData

/// The Kitchens section of the home sheet: drops near you, your orders, your own kitchen.
struct KitchensView: View {
    @Environment(LocationService.self) private var location
    @Query private var kitchens: [Kitchen]
    @Query(sort: \Order.pickupAt, order: .reverse) private var orders: [Order]

    var body: some View {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let now = timeline.date
                    VStack(alignment: .leading, spacing: 22) {
                        let open = openOrders
                        if !open.isEmpty {
                            section("Your orders") {
                                ForEach(open) { o in
                                    NavigationLink(value: o) { OrderRow(order: o, now: now) }.buttonStyle(.plain)
                                }
                            }
                        }
                        section("Drops near you") {
                            Text("A drop is a set batch a neighbor cooks, ready at a set time. Reserve a pickup slot and collect it at their door.")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            let near = sorted(now: now)
                            if near.isEmpty {
                                Text("No kitchens nearby yet. When a neighbor opens theirs, its drops show up here, or open yours below.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Palette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(near) { k in
                                NavigationLink(value: k) { KitchenRow(kitchen: k, now: now, meters: location.center.distance(to: k.coordinate)) }
                                    .buttonStyle(.plain)
                            }
                        }
                        myKitchenCard
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
    }

    /// Reserved ones until an hour after pickup, then picked-up ones waiting for a review.
    private var openOrders: [Order] { OrderLimits.open(orders, now: .now) }

    private var mine: Kitchen? { kitchens.first(where: \.isMine) }

    private func sorted(now: Date) -> [Kitchen] {
        kitchens.filter { !$0.isMine }.sorted { a, b in
            let da = a.nextDrop(after: now)?.start ?? .distantFuture
            let db = b.nextDrop(after: now)?.start ?? .distantFuture
            return da < db
        }
    }

    private var myKitchenCard: some View {
        NavigationLink(value: MyKitchenRoute()) {
            HStack(spacing: 12) {
                Image(systemName: mine == nil ? "house.and.flag" : "house.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 44, height: 44)
                    .background(Palette.accent.opacity(0.14), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mine?.name ?? "Open your kitchen").font(.system(size: 16, weight: .bold))
                    Text(mine == nil ? "Sell what you're good at making to people nearby." : "Menu, drops and orders")
                        .font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Palette.muted)
            }
            .padding(14)
            .card()
        }
        .buttonStyle(.plain)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).eyebrow()
            content()
        }
    }
}

struct MyKitchenRoute: Hashable {}

/// The city list, pushed from Plans or Passport.
struct CityListRoute: Hashable {}

/// Every kitchen near you, pushed from Plans.
struct KitchensRoute: Hashable {}

/// Kitchens as a page of its own: your orders, drops near you, your kitchen.
struct KitchensPage: View {
    var body: some View {
        ScrollView { KitchensView() }
            .scrollIndicators(.hidden)
            .background(Palette.bg)
            .navigationTitle("Home kitchens")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct KitchenRow: View {
    var kitchen: Kitchen
    var now: Date
    var meters: Double

    var body: some View {
        let drop = kitchen.nextDrop(after: now)
        HStack(spacing: 14) {
            PhotoHero(kitchen: kitchen, height: 72, radius: 14)
                .frame(width: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(kitchen.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if let r = kitchen.rating {
                        Image(systemName: "star.fill").foregroundStyle(Palette.star).font(.system(size: 10))
                        Text(String(format: "%.1f", r)).fontWeight(.medium)
                        Text("·")
                    }
                    Text("\(kitchen.cuisine) · \(Walk.label(meters))")
                }
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                if let drop {
                    HStack(spacing: 6) {
                        Text(drop.isLive(at: now) ? "On now" : When.short(drop.start, now: now))
                            .fontWeight(.semibold)
                            .foregroundStyle(drop.isLive(at: now) ? Palette.live : Palette.ink)
                        Text(drop.isSoldOut ? "Sold out" : "\(drop.left) of \(drop.total) left")
                            .foregroundStyle(Palette.muted)
                    }
                    .font(.system(size: 13))
                    .monospacedDigit()
                } else {
                    Text("No drop scheduled").font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted.opacity(0.6))
        }
        .padding(10)
        .card()
    }
}

struct OrderRow: View {
    var order: Order
    var now: Date

    var body: some View {
        HStack(spacing: 12) {
            CategoryDot(category: .food)
            VStack(alignment: .leading, spacing: 2) {
                Text(order.kitchen?.name ?? "Order").font(.system(size: 15, weight: .bold))
                Text(order.status == .reserved ? "Pickup \(When.short(order.pickupAt, now: now))" : "Picked up · leave a review")
                    .font(.system(size: 13)).foregroundStyle(order.status == .reserved ? Palette.muted : Palette.accent)
            }
            Spacer()
            Text(Pricing.format(order.totalCents)).font(.system(size: 13, weight: .semibold, design: .monospaced))
            Image(systemName: "chevron.right").foregroundStyle(Palette.muted)
        }
        .padding(14)
        .card()
    }
}
