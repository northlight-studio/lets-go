import SwiftUI
import SwiftData

struct OrderStatusView: View {
    @Bindable var order: Order
    @Environment(\.modelContext) private var context
    @State private var reviewing = false
    @State private var earned: Stamp?
    @State private var problem: String?

    var body: some View {
        // A batch's order, or any order with a pickup code: the pickup screen.
        if !order.title.isEmpty || !order.pickupCode.isEmpty || order.payment != .atPickup {
            PickupView(order: order)
        } else {
            menuOrder
        }
    }

    private var menuOrder: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(order.kitchen?.name ?? "Order").display(26)
                Text(order.status == .reserved
                     ? "Pickup at \(order.pickupAt.formatted(date: .omitted, time: .shortened))"
                     : "Picked up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(order.status == .reserved ? Palette.ink : Genre.play.color)
                if let note = order.kitchen?.pickupNote, !note.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Where to go", systemImage: "mappin.and.ellipse").eyebrow(Palette.accent)
                        Text(note).font(.system(size: 16, weight: .semibold))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
                VStack(spacing: 0) {
                    ForEach(order.lines, id: \.name) { line in
                        HStack {
                            Text("\(line.quantity)× \(line.name)")
                            Spacer()
                            Text(Pricing.format(line.priceCents * line.quantity)).font(.system(size: 14, design: .monospaced))
                        }
                        .padding(.vertical, 9)
                        Divider().overlay(Palette.line)
                    }
                    HStack {
                        Text("Total, paid at pickup").fontWeight(.bold)
                        Spacer()
                        Text(Pricing.format(order.totalCents)).font(.system(size: 15, weight: .bold, design: .monospaced))
                    }
                    .padding(.vertical, 9)
                }
            }
            .padding(18)
        }
        .background(Palette.bg)
        .safeAreaInset(edge: .bottom) {
            Group {
                switch order.status {
                case .reserved:
                    Button("I picked it up") {
                        Task {
                            await attempt($problem) { () throws(APIError) in
                                try await Sync.pickedUp(order, context: context)
                                reviewing = true
                            }
                        }
                    }
                case .pickedUp:
                    Button("Leave a review") { reviewing = true }
                case .reviewed:
                    EmptyView()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Palette.bg)
        }
        .sheet(isPresented: $reviewing) {
            ReviewView(order: order) { stamp in earned = stamp }
        }
        .sheet(item: $earned) { StampEarnedView(stamp: $0) }
        .errorAlert($problem)
    }
}

struct ReviewView: View {
    var order: Order
    var onPosted: (Stamp?) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var stars = 5
    @State private var tags: Set<String> = []
    @State private var text = ""
    @State private var posting = false
    @State private var problem: String?

    private let tagOptions = ["Generous", "On time", "Would reorder", "Porch was fun", "Great value", "Friendly"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("How was \(order.kitchen?.cookName ?? "it")'s?").display(24).multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        ForEach(1...5, id: \.self) { i in
                            Button { stars = i } label: {
                                Image(systemName: i <= stars ? "star.fill" : "star")
                                    .font(.system(size: 34))
                                    .foregroundStyle(Palette.star)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(i) stars")
                        }
                    }
                    FlowLayout(spacing: 8) {
                        ForEach(tagOptions, id: \.self) { t in
                            let on = tags.contains(t)
                            Button {
                                if on { tags.remove(t) } else { tags.insert(t) }
                            } label: {
                                Text(t).font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .foregroundStyle(on ? Palette.onProminent : Palette.ink)
                                    .background(on ? Palette.prominent : Palette.surface, in: .capsule)
                                    .overlay(Capsule().stroke(on ? .clear : Palette.line))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField("What stood out?", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(14)
                        .card()
                }
                .padding(20)
            }
            .background(Palette.bg)
            .safeAreaInset(edge: .bottom) {
                Button("Post review") { post() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(posting)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
            }
            .errorAlert($problem)
        }
        .presentationBackground(Palette.bg)
    }

    private func post() {
        let review = Review(stars: stars, tags: Array(tags).sorted(), text: text.trimmingCharacters(in: .whitespacesAndNewlines), author: "You", isMine: true)
        posting = true
        Task {
            await attempt($problem) { () throws(APIError) in
                let stamp = try await Sync.review(review, for: order, context: context)
                dismiss()
                onPosted(stamp)
            }
            posting = false
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
