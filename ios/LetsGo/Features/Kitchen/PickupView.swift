import SwiftUI
import SwiftData
import MapKit

/// Your pickup, once you've reserved (and paid, if paying in the app): when it's ready, where (the
/// address, now yours to see) with a small map and the walk, the three-digit code to say at the door,
/// Walk there, and what you owe. After pickup, the review.
struct PickupView: View {
    @Bindable var order: Order
    /// Shown as a sheet's last step: a Done button to close it.
    var onDone: (() -> Void)?
    @Environment(LocationService.self) private var location
    @Environment(\.modelContext) private var context
    @State private var checkout = PayFlow()
    @State private var reviewing = false
    @State private var earned: Stamp?
    @State private var problem: String?

    private var cook: String { order.kitchen?.cookName ?? "the cook" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(header).eyebrow(order.status == .reserved ? Palette.muted : Palette.live)
                    Text(order.status == .reserved ? BatchCopy.ready(order.pickupAt) : (order.title.isEmpty ? (order.kitchen?.name ?? "Order") : order.title))
                        .display(30)
                }
                HStack(spacing: 12) {
                    BatchPhoto(path: order.photoURL, title: order.title, height: 56, radius: 12)
                        .frame(width: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(order.title.isEmpty ? order.lines.map(\.name).joined(separator: ", ") : order.title)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(2)
                        Text(BatchCopy.count(order.itemCount, order.unit)).font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }
                }
                if order.payment != .unpaid && order.payment.isLive { place }
                if !order.pickupCode.isEmpty && order.status == .reserved && order.payment.isLive { code }
                Text(BatchCopy.receipt(order.payment, totalCents: order.totalCents, cook: cook))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(order.payment == .paid ? Palette.live : Palette.ink)
                if order.status == .reserved && order.payment.isLive {
                    Text("After you pick it up, rate it. Three pickups makes you one of \(cook == "the cook" ? "the cook" : cook)'s regulars.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
        .background(Palette.bg)
        .safeAreaInset(edge: .bottom) { actions.padding(.horizontal, 18).padding(.vertical, 8) }
        .sheet(isPresented: $reviewing) { ReviewView(order: order) { stamp in earned = stamp } }
        .sheet(item: $earned) { StampEarnedView(stamp: $0) }
        .errorAlert($problem)
        .errorAlert($checkout.problem)
        .checkoutSheet(checkout, context: context)
        .task { try? await Sync.refresh(order: order, context: context) }
    }

    private var header: String {
        switch order.status {
        case .reserved: "Your pickup"
        case .pickedUp: "Picked up"
        case .reviewed: "Picked up and reviewed"
        }
    }

    @ViewBuilder
    private var place: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label(where_, systemImage: "lock.open.fill")
                    .font(.system(size: 16, weight: .semibold))
                if let note = order.kitchen?.pickupNote, !note.isEmpty {
                    Text(note).font(.system(size: 14)).foregroundStyle(Palette.soft)
                }
            }
            if let spot = order.exactCoordinate {
                let meters = location.center.distance(to: spot)
                Map(initialPosition: .region(MKCoordinateRegion(center: spot, latitudinalMeters: max(500, meters * 2.4), longitudinalMeters: max(500, meters * 2.4)))) {
                    Marker(order.kitchen?.name ?? "Pickup", systemImage: "takeoutbag.and.cup.and.straw.fill", coordinate: spot)
                        .tint(Palette.accent)
                    UserAnnotation()
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .allowsHitTesting(false)
                .frame(height: 160)
                .clipShape(.rect(cornerRadius: 16))
                Text("\(Walk.minutes(meters))-minute walk.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var where_: String {
        let spot = BatchCopy.spot(order.pickupSpot, cook: cook)
        let address = order.address.isEmpty ? (order.kitchen?.address ?? "") : order.address
        return address.isEmpty ? spot : "\(spot), \(address)"
    }

    private var code: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Say the code").font(.system(size: 14)).foregroundStyle(Palette.muted)
            Spacer()
            Text(BatchCopy.spoken(order.pickupCode))
                .font(.system(size: 34, weight: .bold))
                .monospacedDigit()
                .accessibilityLabel("Pickup code \(BatchCopy.spoken(order.pickupCode))")
        }
        .padding(14)
        .card()
    }

    @ViewBuilder
    private var actions: some View {
        switch order.status {
        case .reserved where !order.payment.isLive:
            if let onDone { Button("Done", action: onDone).buttonStyle(PrimaryButtonStyle()) }
        case .reserved where order.payment == .unpaid:
            Button(checkout.working ? "One moment…" : "Pay \(Pricing.format(order.totalCents))") {
                Task { await checkout.pay(order, context: context) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(checkout.working)
        case .reserved:
            HStack(spacing: 10) {
                if order.exactCoordinate != nil {
                    Button { walk() } label: { Label("Walk there", systemImage: "figure.walk") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if let onDone {
                    Button("Done", action: onDone).buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Picked up") { pickedUp() }.buttonStyle(SecondaryButtonStyle())
                }
            }
        case .pickedUp:
            Button("Leave a review") { reviewing = true }.buttonStyle(PrimaryButtonStyle())
        case .reviewed:
            if let onDone { Button("Done", action: onDone).buttonStyle(PrimaryButtonStyle()) }
        }
    }

    /// Walking directions in Apple Maps, to the door.
    private func walk() {
        guard let spot = order.exactCoordinate else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: spot))
        item.name = order.kitchen?.name ?? "Pickup"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    private func pickedUp() {
        Task {
            await attempt($problem) { () throws(APIError) in
                try await Sync.pickedUp(order, context: context)
                reviewing = true
            }
        }
    }
}
