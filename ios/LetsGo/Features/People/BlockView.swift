import SwiftUI
import SwiftData

/// Pushes Your block onto People.
struct BlockRoute: Hashable {}

/// Your block: what's going on within a few blocks, titled with your area. Each row is a
/// thumbnail, a bold line and a detail line. It isn't endless: it ends with today's, and says so.
/// The bell at the top turns the evening digest on and off.
struct BlockView: View {
    @Environment(LocationService.self) private var location
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query private var gatherings: [Gathering]
    @Query private var kitchens: [Kitchen]
    @Query(filter: #Predicate<Intro> { !$0.dismissed }) private var intros: [Intro]
    @State private var openIntro: Intro?
    @State private var hosting = false

    private var feed: BlockFeed { BlockFeed.shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let now = timeline.date
            let shown = feed.today(now: now)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if !ServerFeatures.shared.has(.block) {
                        note(ServerFeatures.Feature.block.comingSoon)
                    } else if !APIConfig.isConfigured {
                        note("Your block needs a server. Add one at the bottom of Passport, under Server.")
                    } else if shown.isEmpty {
                        empty
                    } else {
                        rows(shown, now: now)
                        Text("That\u{2019}s everything on your block today.")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 22)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Palette.bg)
            .refreshable { await feed.refresh(around: location.center) }
            .onAppear { feed.see(shown, now: now) }
            .onChange(of: shown.map(\.key)) { _, _ in feed.see(shown, now: now) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $openIntro) { ThirdTimeView(intro: $0).presentationBackground(Palette.bg) }
        .sheet(isPresented: $hosting) { NewGatheringView(draft: nil) }
        .task {
            if !feed.loaded { await feed.refresh(around: location.center) }
        }
    }

    // MARK: Top

    private var header: some View {
        @Bindable var feed = feed
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 42, height: 42)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to People")
                Spacer()
                Menu {
                    Toggle(isOn: $feed.digestOn) {
                        Label("Evening digest", systemImage: "bell")
                    }
                } label: {
                    Image(systemName: feed.digestOn ? "bell" : "bell.slash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 42, height: 42)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .accessibilityLabel(feed.digestOn ? "Evening digest is on" : "Evening digest is off")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.area).eyebrow()
                Text("Your block").display(34)
            }
            Text(digestLine)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var digestLine: String {
        if !feed.digestOn { return "The evening digest is off. Turn it on with the bell." }
        if feed.notificationsDenied { return "Notifications are off for Let\u{2019}s Go in Settings, so the evening digest can\u{2019}t come." }
        return "Once a day around 5:30, only when there\u{2019}s something new. Turn it off with the bell."
    }

    // MARK: Rows

    private func rows(_ items: [BlockItemDTO], now: Date) -> some View {
        VStack(spacing: 8) {
            ForEach(items) { item in
                link(Block.row(item, now: now))
            }
        }
    }

    private func gathering(_ id: UUID) -> Gathering? { gatherings.first { $0.remoteID == id || $0.id == id } }
    private func kitchen(_ id: UUID?) -> Kitchen? { id.flatMap { id in kitchens.first { $0.remoteID == id } } }
    private func intro(_ id: UUID) -> Intro? { intros.first { $0.id == id } }

    /// Where a row goes: the kitchen, the gathering, saying hi, or back to People for I'm in.
    @ViewBuilder
    private func link(_ row: Block.Row) -> some View {
        switch row.kind {
        case "supper":
            NavigationLink(value: SupperLink(id: row.subject)) { BlockRow(row: row, opens: true) }.buttonStyle(.plain)
        case "batch", "back":
            if let k = kitchen(row.kitchenID) {
                NavigationLink(value: k) { BlockRow(row: row, opens: true) }.buttonStyle(.plain)
            } else {
                BlockRow(row: row, opens: false)
            }
        case "going":
            if let g = gathering(row.subject) {
                NavigationLink(value: g) { BlockRow(row: row, opens: true) }.buttonStyle(.plain)
            } else {
                BlockRow(row: row, opens: false)
            }
        case "neighbor":
            if let i = intro(row.subject) {
                Button { openIntro = i } label: { BlockRow(row: row, opens: true) }.buttonStyle(.plain)
            } else {
                BlockRow(row: row, opens: false)
            }
        case "up_for":
            // I'm in and Wave are on People, right under what you're up for.
            Button { dismiss() } label: { BlockRow(row: row, opens: true) }.buttonStyle(.plain)
        default:
            BlockRow(row: row, opens: false)
        }
    }

    // MARK: Nothing yet

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(feed.loaded ? "Nothing on your block today" : "Looking around your block")
                .font(.system(size: 17, weight: .bold))
            Text("When a neighbor posts a batch, a kitchen you follow is back, friends are up for something, or people nearby are going somewhere, it shows here.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button { hosting = true } label: {
                Label("Host something", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            Button { model.addingFriend = true } label: {
                Label("Add a friend", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(16)
        .card(radius: 24)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row: a thumbnail, a bold line, a detail line.
struct BlockRow: View {
    var row: Block.Row
    var opens: Bool

    var body: some View {
        HStack(spacing: 12) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                Text(row.line)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Text(row.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .card(radius: 18)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var thumb: some View {
        switch row.thumb {
        case .photo(let path, let title):
            BatchPhoto(path: path, title: title, height: 44, radius: 12).frame(width: 44)
        case .initials(let letters):
            Text(letters)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.onProminent)
                .frame(width: 44, height: 44)
                .background(Palette.prominent, in: .circle)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .background(Palette.raise, in: .rect(cornerRadius: 12))
        }
    }
}
