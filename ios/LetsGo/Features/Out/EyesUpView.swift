import SwiftUI
import MapKit
import UIKit

/// Where an eyes-up walk is going.
struct WalkTarget: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var genre: Genre
    var latitude: Double
    var longitude: Double
    var start: Date?
    /// Walking with someone: "With Maya".
    var friends: [Friend] = []
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// Eyes up: the walk there, guided by the phone in your pocket. One buzz for a left,
/// two for a right, three when you're here. "Pocket it and go" dims the screen; the
/// proximity sensor turns it off in a pocket while Let's Go keeps guiding.
struct EyesUpView: View {
    var target: WalkTarget
    @Environment(LocationService.self) private var location
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var routes = RouteBook()
    @State private var directions: Directions?
    /// Directions came back empty (offline, or no walking route).
    @State private var noRoute = false
    @State private var haptics = WalkHaptics()
    @State private var next = 0
    @State private var pocketed = false
    @State private var arrived = false
    @State private var lastBuzz: Turn?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let now = timeline.date
            ZStack(alignment: .top) {
                map
                LinearGradient(colors: [Palette.bg.opacity(0.95), Palette.bg.opacity(0.7), Palette.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                header(now: now)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            .overlay(alignment: .bottom) { panel(now: now).padding(.horizontal, 8).padding(.bottom, 8) }
            .overlay { if pocketed { pocketScreen } }
        }
        .background(Palette.bg)
        .statusBarHidden(pocketed)
        .task { await load() }
        .onAppear { location.setPrecise(true) }
        .onDisappear(perform: stop)
        .onChange(of: location.center.latitude) { follow() }
        .onChange(of: location.center.longitude) { follow() }
        .sensoryFeedback(.success, trigger: arrived)
    }

    // MARK: Map

    private var map: some View {
        Map(initialPosition: .camera(MapCamera(centerCoordinate: target.coordinate, distance: 1400))) {
            if let d = directions {
                MapPolyline(coordinates: d.coordinates)
                    .stroke(Palette.walk, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                ForEach(Array(d.turns.enumerated()), id: \.offset) { i, turn in
                    if turn.way != .arrive {
                        Annotation(turn.instruction, coordinate: turn.coordinate, anchor: .center) {
                            TurnBadge(turn: turn, done: i < next)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            Annotation(target.title, coordinate: target.coordinate, anchor: .center) {
                Image(systemName: target.genre.symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(target.genre.ink)
                    .frame(width: 32, height: 32)
                    .background(target.genre.color, in: .circle)
                    .overlay(Circle().stroke(Palette.card, lineWidth: 2))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            }
            .annotationTitles(.hidden)
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .ignoresSafeArea()
    }

    // MARK: Over it

    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(eyebrow(now: now)).eyebrow(Palette.accentSoft)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop the walk")
            }
            Text(arrived ? "You're here." : "Eyes up.").font(.system(size: 54, weight: .bold))
            Text(arrived ? "Pocket it. Go say hi." : subtitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.soft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        let with = target.friends.isEmpty ? "" : ", and \(Crowd.names(target.friends)) \(target.friends.count == 1 ? "is" : "are") on the way too"
        if noRoute { return "Couldn't get walking directions, so it can't buzz at the turns. Apple Maps can take you." }
        return "Pocket the phone. It buzzes at each turn\(with)."
    }

    private func eyebrow(now: Date) -> String {
        var parts = [now.formatted(.dateTime.weekday(.abbreviated)), HomeLine.clock(now)]
        if let start = target.start { parts.append("starts \(HomeLine.clock(start))") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func panel(now: Date) -> some View {
        let minutes = directions?.minutes ?? Walk.minutes(location.center.distance(to: target.coordinate))
        let there = now.addingTimeInterval(Double(minutes) * 60)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(arrived ? "Here" : "\(minutes) min").font(.system(size: 64, weight: .bold)).monospacedDigit()
                    Text("to \(target.title) \u{00B7} there at \(HomeLine.clock(there))")
                        .font(.system(size: 14))
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Spacer()
                if !target.friends.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        AvatarStack(friends: target.friends, size: 30, includesYou: true, ground: Palette.card)
                        Text("With \(Crowd.names(target.friends))").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.soft)
                    }
                    .padding(.bottom, 4)
                }
            }
            if let turn = upcoming {
                HStack(spacing: 10) {
                    Image(systemName: turn.way == .left ? "arrow.turn.up.left" : turn.way == .right ? "arrow.turn.up.right" : "mappin")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Palette.accentSoft)
                    Text("Next: \(Turn.short(turn.instruction))").font(.system(size: 14))
                    Spacer()
                    Text("\(Int(location.center.distance(to: turn.coordinate))) m")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Palette.walk.opacity(0.1), in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.walk.opacity(0.22)))
                .padding(.top, 16)
            }
            HStack(spacing: 8) {
                legend(.left, "Turn left")
                legend(.right, "Turn right")
                legend(.arrive, "You're here")
            }
            .padding(.top, 16)
            Button { setPocketed(true) } label: {
                Label("Pocket it and go", systemImage: "iphone.slash")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 16)
            .disabled(arrived || noRoute)
            if noRoute {
                Link(destination: mapsURL) {
                    Label("Open in Apple Maps", systemImage: "map")
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 10)
            }
            Text("The screen goes dark. Wren handles the rest.")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .glassPanel(radius: 34)
    }

    /// Tap to feel it before you need it.
    private func legend(_ way: Turn.Way, _ title: String) -> some View {
        Button { haptics.play(way) } label: {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<WalkHaptics.count(for: way), id: \.self) { _ in
                        Circle().fill(Palette.accentSoft).frame(width: 10, height: 10)
                    }
                }
                .frame(height: 12)
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Palette.card, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays the buzz for this")
    }

    private var pocketScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Text(arrived ? "You're here." : "Walking")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accent.opacity(0.5))
                if let turn = upcoming, !arrived {
                    Text("Next: \(Turn.short(turn.instruction))").font(.system(size: 13)).foregroundStyle(Palette.faint)
                }
                Button("Show the map") { setPocketed(false) }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .overlay(Capsule().stroke(Color.white.opacity(0.15)))
                    .padding(.top, 10)
            }
        }
        // A black screen in a pocket, whatever the phone's appearance.
        .environment(\.colorScheme, .dark)
        .transition(.opacity)
    }

    /// Walking directions in Apple Maps, for when there's no route here.
    private var mapsURL: URL {
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [
            URLQueryItem(name: "daddr", value: "\(target.coordinate.latitude),\(target.coordinate.longitude)"),
            URLQueryItem(name: "dirflg", value: "w"),
        ]
        return c?.url ?? URL(string: "https://maps.apple.com/")!
    }

    private var upcoming: Turn? {
        guard let d = directions, next < d.turns.count else { return nil }
        return d.turns[next]
    }

    // MARK: Guiding

    private func load() async {
        directions = await routes.directions(from: location.center, to: target.coordinate)
        noRoute = directions == nil
    }

    private func follow() {
        guard let d = directions, !arrived else { return }
        let step = Guidance.step(at: location.center, turns: d.turns, next: next)
        next = step.next
        if let turn = step.fire, turn != lastBuzz {
            lastBuzz = turn
            haptics.play(turn.way)
            if turn.way == .arrive {
                arrived = true
                setPocketed(false)
            }
        }
    }

    private func setPocketed(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.4)) { pocketed = on }
        model.dark = on
        // The proximity sensor switches the screen off in a pocket; the app stays in front and keeps guiding.
        UIDevice.current.isProximityMonitoringEnabled = on
        UIApplication.shared.isIdleTimerDisabled = on
    }

    private func stop() {
        setPocketed(false)
        location.setPrecise(false)
    }
}

/// A turn on the walk's map: dots for how it buzzes, and what it is.
private struct TurnBadge: View {
    var turn: Turn
    var done: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(Palette.accentSoft.opacity(done ? 0.25 : 0.6), lineWidth: 1.5)
                .background(Palette.bg.opacity(0.7), in: .circle)
                .frame(width: 26, height: 26)
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(0..<WalkHaptics.count(for: turn.way), id: \.self) { _ in
                        Circle().fill(Palette.accentSoft).frame(width: 6, height: 6)
                    }
                }
                Text(Turn.short(turn.instruction)).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Palette.surface, in: .capsule)
            .overlay(Capsule().stroke(Palette.line))
            .fixedSize()
            .offset(x: -32)
            .opacity(done ? 0.4 : 1)
        }
    }
}
