import SwiftUI
import SwiftData
import CoreLocation

/// Wren's tab. Say who and when ("something with Maya and Theo saturday") and Wren works it
/// out in front of you: when everyone's free, the day, what's worth going to, food and the
/// walks, then a plan to send. Say a mood instead and get real things nearby; say "host …"
/// and get a draft to post.
struct WrenView: View {
    @Environment(LocationService.self) private var location
    @Environment(HomeModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Gathering.start) private var gatherings: [Gathering]
    @Query private var kitchens: [Kitchen]
    @Query private var notes: [TasteNote]
    @Query(sort: \Person.name) private var people: [Person]
    @Query(sort: \Crew.name) private var crews: [Crew]

    @State private var input = ""
    @State private var exchanges: [Exchange] = []
    @State private var draft: GatheringDraft?
    @State private var path = NavigationPath()
    @State private var voice = WrenVoice()
    @State private var busy = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    struct Exchange: Identifiable {
        var id = UUID()
        var question: String
        var reply: String
        var answer: Wren.Answer?
        var plan: Plan?
        var request: PlanRequest?
        /// Events already offered, for "Another".
        var excluded: Set<UUID> = []
        /// How far the checklist has got. The reply shows after the last check, the card after that.
        var step = 0
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        WrenHeader()
                        if exchanges.isEmpty { welcome }
                        ForEach(exchanges) { e in
                            exchange(e).id(e.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
                .onChange(of: exchanges.count) {
                    if let last = exchanges.last?.id { withAnimation { proxy.scrollTo(last, anchor: .top) } }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .background(Palette.bg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Gathering.self) { GatheringDetailView(gathering: $0) }
            .navigationDestination(for: Kitchen.self) { KitchenView(kitchen: $0) }
            .navigationDestination(for: Order.self) { OrderStatusView(order: $0) }
            .navigationDestination(for: SavedPlan.self) { PlanView(plan: $0) }
            .sheet(item: $draft) { NewGatheringView(draft: $0) }
            .errorAlert($problem)
        }
        .onAppear(perform: takeDraft)
        .onChange(of: model.wrenDraft) { takeDraft() }
    }

    // MARK: Pieces

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tell me who and when, and I'll sort the rest: a time that works, the thing, food, the walk, and who's in.")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button { ask(s) } label: {
                        Text(s)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.soft)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The first ones use your actual friends' names, so they work as written.
    private var suggestions: [String] {
        let names = people.prefix(2).map(\.snapshot.firstName)
        var out: [String] = []
        if names.count == 2 { out.append("Something with \(names[0]) and \(names[1]) Saturday") }
        else if let one = names.first { out.append("Something with \(one) tomorrow evening") }
        out += ["Something chill tonight under $15", "Live music this weekend", "Host a slow jog Saturday 8am"]
        return out
    }

    @ViewBuilder
    private func exchange(_ e: Exchange) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            YouBubble(text: e.question)
            if let plan = e.plan {
                ThinkingList(checks: plan.checks, step: e.step)
                if e.step > plan.checks.count {
                    Text(e.reply)
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.2)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if e.step > plan.checks.count + 1 {
                    let group = people.filter { plan.friendIDs.contains($0.id) }.map(\.snapshot)
                    PlanCard(plan: plan, friends: group, onAsk: { send(e) }, onAnother: { another(e) })
                        .disabled(busy)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    refinements(e, plan: plan)
                }
            } else {
                Text(e.reply)
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let answer = e.answer {
                    if !answer.picks.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(answer.picks.enumerated()), id: \.element.id) { i, p in
                                PickRow(pick: p, now: .now) { open(p) }
                                    .padding(.horizontal, 14)
                                if i < answer.picks.count - 1 { Divider().overlay(Palette.line).padding(.leading, 66) }
                            }
                        }
                        .card(radius: 22)
                    }
                    if let d = answer.draft { DraftCard(draft: d) { draft = d } }
                }
            }
        }
    }

    /// "Add Jun", "Done by 9", "Free only": change one thing and plan again.
    private func refinements(_ e: Exchange, plan: Plan) -> some View {
        let extra = people.first { !plan.friendIDs.contains($0.id) }
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if let extra {
                    chip("Add \(extra.snapshot.firstName)") { refine(e, as: "Add \(extra.snapshot.firstName)") { $0.friendIDs.append(extra.id) } }
                }
                chip("Done by 9") { refine(e, as: "Done by 9") { $0.untilHour = 21 } }
                chip("Free only") { refine(e, as: "Free only") { $0.wantsFree = true } }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.soft)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("What are you in the mood for?", text: $input, axis: .vertical)
                .lineLimit(1...3)
                .font(.system(size: 16))
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { ask(input) }
            Button { ask(input) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.onProminent)
                    .frame(width: 42, height: 42)
                    .background(Palette.prominent, in: .circle)
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Ask Wren")
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 27))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Asking

    private func ask(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        focused = false
        let now = Date.now
        let friends = people.map(\.snapshot)
        let crewList = crews.map { (name: $0.name, memberIDs: $0.memberIDs) }
        if let request = PlanRequest.parse(text, friends: friends, crews: crewList, now: now) {
            show(request, question: text, excluded: [])
            return
        }
        let candidates = Nearby.candidates(gatherings: gatherings, kitchens: kitchens, from: location.center, now: now)
        let taste = Nearby.taste(notes: notes, gatherings: gatherings, kitchens: kitchens)
        let answer = Wren.answer(text, candidates: candidates, taste: taste, now: now)
        let e = Exchange(question: text, reply: answer.reply, answer: answer)
        withAnimation(.snappy) { exchanges.append(e) }
        Task {
            if let better = await voice.reply(for: answer, asked: text, now: now) { update(e.id) { $0.reply = better } }
        }
    }

    private func show(_ request: PlanRequest, question: String, excluded: Set<UUID>) {
        let now = Date.now
        guard let plan = makePlan(request, excluding: excluded, now: now) else {
            let day = request.day.formatted(.dateTime.weekday(.wide))
            let e = Exchange(question: question, reply: "Nothing's on \(day) near you yet that works for everyone. Say \u{201C}host\u{201D} and what you'd like, and I'll draft it for people nearby.")
            withAnimation(.snappy) { exchanges.append(e) }
            return
        }
        let e = Exchange(question: question, reply: plan.reply, plan: plan, request: request, excluded: excluded.union(plan.stops.compactMap(\.gatheringID)))
        withAnimation(.snappy) { exchanges.append(e) }
        reveal(e.id, steps: plan.checks.count + 2)
        let names = Crowd.names(people.filter { plan.friendIDs.contains($0.id) }.map(\.snapshot))
        Task {
            if let better = await voice.reply(for: plan, asked: question, names: names) { update(e.id) { $0.reply = better } }
        }
    }

    private func makePlan(_ r: PlanRequest, excluding: Set<UUID>, now: Date) -> Plan? {
        let here = location.center
        let events = Nearby.candidates(gatherings: gatherings, kitchens: kitchens, from: here, now: now)
        let drops = kitchens.flatMap { k in
            k.drops.filter { $0.end > now && !$0.isSoldOut }.map { d in
                DropSlot(kitchenID: k.id, name: k.name, cuisine: k.cuisine, start: d.start, end: d.end, left: d.left,
                         priceFromCents: k.menu.map(\.priceCents).min(), latitude: k.latitude, longitude: k.longitude)
            }
        }
        let outside = Spots.all
            .filter { [.park, .view, .water].contains($0.kind) }
            .map { OutsideSpot(title: $0.title, area: $0.area, latitude: $0.lat, longitude: $0.lon) }
        return Planner.plan(
            r, friends: people.map(\.snapshot), events: events, drops: drops, outside: outside, here: here,
            sunset: Sun.sunset(on: r.day, at: here), taste: Nearby.taste(notes: notes, gatherings: gatherings, kitchens: kitchens),
            excluding: excluding, now: now
        )
    }

    /// The checklist resolves a line at a time, then the reply, then the card.
    private func reveal(_ id: UUID, steps: Int) {
        Task {
            for s in 1...steps {
                if !reduceMotion { try? await Task.sleep(for: .milliseconds(750)) }
                withAnimation(.snappy(duration: 0.35)) { update(id) { $0.step = s } }
            }
        }
    }

    private func refine(_ e: Exchange, as label: String, _ change: (inout PlanRequest) -> Void) {
        guard var r = e.request else { return }
        change(&r)
        show(r, question: label, excluded: [])
    }

    private func another(_ e: Exchange) {
        guard let r = e.request else { return }
        show(r, question: "Another", excluded: e.excluded)
    }

    /// Save the plan, hold a spot at the event, and ask the friends in it.
    private func send(_ e: Exchange) {
        guard let plan = e.plan, let request = e.request else { return }
        let saved = SavedPlan(plan, request: request.text)
        saved.askedAt = .now
        context.insert(saved)
        Ledger.save(context, "save plan")
        let group = people.filter { plan.friendIDs.contains($0.id) }
        let event = plan.stops.last(where: { $0.kind == .event }).flatMap { s in gatherings.first(where: { $0.id == s.gatheringID }) }
        busy = true
        Task {
            await attempt($problem) { () throws(APIError) in
                if let event {
                    if !event.isJoined { try await Sync.join(event, context: context) }
                    // Friends get an invite only when the event is on the server.
                    if event.remoteID != nil, !group.isEmpty { try await Sync.invite(group, to: event, context: context) }
                }
            }
            busy = false
            path.append(saved)
        }
    }

    private func update(_ id: UUID, _ change: (inout Exchange) -> Void) {
        guard let i = exchanges.firstIndex(where: { $0.id == id }) else { return }
        change(&exchanges[i])
    }

    private func takeDraft() {
        guard let d = model.wrenDraft else { return }
        model.wrenDraft = nil
        input = d
        focused = true
    }

    private func open(_ p: Candidate) {
        switch p.kind {
        case .gathering: if let g = gatherings.first(where: { $0.id == p.id }) { path.append(g) }
        case .drop: if let k = kitchens.first(where: { $0.id == p.id }) { path.append(k) }
        }
    }
}

/// Wren's name plate at the top of its tab.
struct WrenHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            WrenOrb(size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Wren").display(34)
                Text("Does the logistics. You show up.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
        }
        .padding(.top, 6)
    }
}

/// What you said, in a yellow bubble on the right.
struct YouBubble: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Palette.onProminent)
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(Palette.prominent, in: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22, bottomTrailingRadius: 6, topTrailingRadius: 22))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 60)
    }
}

/// A gathering Wren drafted, ready to check and post.
struct DraftCard: View {
    var draft: GatheringDraft
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Draft").eyebrow(Palette.accentSoft)
                Spacer()
                Label(draft.category.label, systemImage: draft.category.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(draft.category.color)
            }
            Text(draft.title).font(.system(size: 17, weight: .bold))
            Text([When.short(draft.start), draft.placeName].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
            Button("Review and post", action: action)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 6)
        }
        .padding(16)
        .background(Palette.accent.opacity(0.08), in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Palette.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }
}
