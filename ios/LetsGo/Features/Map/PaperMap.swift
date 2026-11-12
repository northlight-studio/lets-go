import SwiftUI
import UIKit
import CoreLocation
import MapLibre

/// The map, edge to edge: MapLibre drawing OpenStreetMap tiles from OpenFreeMap in our own
/// style (`neighborhood-light.json` / `neighborhood-dark.json`, made by `scripts/map-style.py`),
/// following the phone's light and dark. Each thing in the window is a pin (`PinView`): a
/// kitchen's round photo with its price, an event's pill with its time and name; friends who
/// are out or up for something show as their initials. Pins that would overlap merge into a
/// count (`Timetable.merge`), and come apart as you zoom in. The walk ring and the route are
/// drawn only once you've tapped something. You are the system blue dot. No rotation or
/// tilt: north stays up.
struct PaperMap: UIViewRepresentable {
    /// Where the map should look, asked for once per `id`.
    struct Camera: Equatable {
        enum Kind: Equatable {
            /// Fly to a place, keeping it clear of the card at the bottom.
            case show(latitude: Double, longitude: Double)
            /// Back to you.
            case recenter(latitude: Double, longitude: Double)
            /// Frame these places (a merged tag you tapped).
            case fit([LatLon])
        }

        var id = UUID()
        var kind: Kind
    }

    struct LatLon: Equatable {
        var latitude: Double
        var longitude: Double
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    var items: [Candidate]
    /// Friends to draw (`Pins.friends`), separate from what merges.
    var friends: [Pins.FriendPin] = []
    var now: Date
    var selectedID: UUID?
    /// Where the map opens.
    var start: CLLocationCoordinate2D
    var startZoom: Double
    /// You, for the walk ring once something is tapped.
    var here: CLLocationCoordinate2D
    /// The walk to what's tapped (a real route when there is one).
    var route: [CLLocationCoordinate2D]
    var camera: Camera?
    var dark: Bool
    var onSelect: (Candidate) -> Void
    /// A tap on a friend.
    var onFriend: (Pins.FriendPin) -> Void = { _ in }
    /// A tap on the map itself, away from any tag.
    var onTapMap: () -> Void
    /// True while the map is being moved by a finger.
    var onMoving: (Bool) -> Void

    /// Ten minutes at 80 m a minute.
    static let walkRadius: CLLocationDistance = 800

    static func styleURL(dark: Bool) -> URL? {
        Bundle.main.url(forResource: dark ? "neighborhood-dark" : "neighborhood-light", withExtension: "json")
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: Self.styleURL(dark: dark))
        map.delegate = context.coordinator
        map.backgroundColor = MapInk.paper
        map.tintColor = .systemBlue
        map.logoView.isHidden = true
        // The attribution is ours to show (the credit over the rail in `HomeView`), small and quiet.
        map.attributionButton.isHidden = true
        map.compassView.isHidden = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.minimumZoomLevel = 9
        map.maximumZoomLevel = 19
        map.showsUserLocation = true
        map.setCenter(start, zoomLevel: startZoom, animated: false)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)

        context.coordinator.map = map
        context.coordinator.styleDark = dark
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.styleDark != dark {
            c.styleDark = dark
            map.styleURL = Self.styleURL(dark: dark)
        }
        c.refreshTags()
        c.refreshFriends()
        c.refreshLines()
        if let camera, camera.id != c.lastCamera {
            c.lastCamera = camera.id
            c.move(camera.kind)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PaperMap
        weak var map: MLNMapView?
        var styleDark = false
        var lastCamera: UUID?

        /// The tags on the map, by a key that changes whenever a tag looks different.
        private var tags: [String: MLNPointAnnotation] = [:]
        private var groupsByKey: [String: Timetable.Group] = [:]
        private var views: [String: MLNAnnotationView] = [:]
        private var mergedAt: Double = -1
        private var lastItems: [UUID] = []
        private var lastSelected: UUID?
        private var lastMinute = -1
        private var friendTags: [String: MLNPointAnnotation] = [:]
        private var friendsByKey: [String: Pins.FriendPin] = [:]
        private var ring: MLNPolyline?
        private var routeLine: MLNPolyline?
        private var lineKey = ""
        private var settle: Task<Void, Never>?
        private var moving = false

        init(parent: PaperMap) { self.parent = parent }

        // MARK: Friends

        /// Friends' pins: added, moved or removed only when they look different.
        func refreshFriends() {
            guard let map else { return }
            var wanted: [String: Pins.FriendPin] = [:]
            for f in parent.friends {
                wanted["f:\(f.id.uuidString)|\(f.latitude)|\(f.longitude)|\(f.bubble ?? "")|\(f.initials)|\(styleDark ? "d" : "l")"] = f
            }
            let gone = friendTags.keys.filter { wanted[$0] == nil }
            let goneAnnotations = gone.compactMap { friendTags[$0] }
            for k in gone {
                friendTags[k] = nil
                friendsByKey[k] = nil
                views[k] = nil
            }
            if !goneAnnotations.isEmpty { map.removeAnnotations(goneAnnotations) }
            var added: [MLNPointAnnotation] = []
            for (k, f) in wanted where friendTags[k] == nil {
                let a = MLNPointAnnotation()
                a.coordinate = f.coordinate
                a.title = k
                friendTags[k] = a
                friendsByKey[k] = f
                added.append(a)
            }
            if !added.isEmpty { map.addAnnotations(added) }
        }

        // MARK: Tags

        /// Regroups the tags when what's shown, what's tapped, the minute or the zoom (in
        /// quarter steps) has changed, and swaps only the tags that look different.
        func refreshTags(force: Bool = false) {
            guard let map else { return }
            let zoom = Timetable.mergeZoom(map.zoomLevel)
            let ids = parent.items.map(\.id)
            let minute = Int(parent.now.timeIntervalSinceReferenceDate / 60)
            guard force || zoom != mergedAt || ids != lastItems || parent.selectedID != lastSelected || minute != lastMinute else { return }
            mergedAt = zoom
            lastItems = ids
            lastSelected = parent.selectedID
            lastMinute = minute

            let groups = Timetable.merge(parent.items, zoom: zoom, now: parent.now, selected: parent.selectedID)
            var wanted: [String: Timetable.Group] = [:]
            for g in groups { wanted[key(for: g)] = g }

            let gone = tags.keys.filter { wanted[$0] == nil }
            let goneAnnotations = gone.compactMap { tags[$0] }
            for k in gone {
                tags[k] = nil
                groupsByKey[k] = nil
                views[k] = nil
            }
            if !goneAnnotations.isEmpty { map.removeAnnotations(goneAnnotations) }

            var added: [MLNPointAnnotation] = []
            for (k, g) in wanted where tags[k] == nil {
                let a = MLNPointAnnotation()
                a.coordinate = g.coordinate
                a.title = k
                tags[k] = a
                groupsByKey[k] = g
                added.append(a)
            }
            if !added.isEmpty { map.addAnnotations(added) }
        }

        /// The group, how its tag reads, and the appearance: any change makes a new tag.
        private func key(for g: Timetable.Group) -> String {
            let first = g.members[0]
            let text = g.isSingle ? Timetable.tag(first, now: parent.now) : "\(g.members.count)"
            let tapped = g.isSingle && first.id == parent.selectedID
            let on = g.isSingle && Timetable.isOn(first, now: parent.now)
            // A kitchen's photo arriving, or a renamed event, redraws its pin.
            let look = g.isSingle ? "\(first.title)|\(first.photoURL?.absoluteString ?? "")|\(first.priceFromCents ?? 0)" : ""
            return "\(g.id)|\(text)|\(tapped ? "t" : "-")\(on ? "n" : "-")|\(look)|\(styleDark ? "d" : "l")"
        }

        func view(for annotation: MLNAnnotation, in map: MLNMapView) -> MLNAnnotationView? {
            guard let point = annotation as? MLNPointAnnotation, let k = point.title else { return nil }
            if let friend = friendsByKey[k] {
                let view = PinView.friend(friend, traits: map.traitCollection)
                views[k] = view
                return view
            }
            guard let group = groupsByKey[k] else { return nil }
            let view = PinView.make(group: group, now: parent.now, selectedID: parent.selectedID, traits: map.traitCollection)
            views[k] = view
            return view
        }

        func select(_ annotation: MLNAnnotation, in map: MLNMapView) {
            map.deselectAnnotation(annotation, animated: false)
            guard let point = annotation as? MLNPointAnnotation, let k = point.title else { return }
            if let friend = friendsByKey[k] { return parent.onFriend(friend) }
            guard let group = groupsByKey[k] else { return }
            if group.isSingle {
                parent.onSelect(group.members[0])
            } else if Self.together(group.members) || map.zoomLevel >= map.maximumZoomLevel - 0.5 {
                // All at one place: zooming won't pull them apart, so open the first.
                parent.onSelect(group.members[0])
            } else {
                move(.fit(group.members.map { LatLon(latitude: $0.lat, longitude: $0.lon) }))
            }
        }

        /// Within about 30 m of each other: one venue.
        static func together(_ members: [Candidate]) -> Bool {
            guard let first = members.first else { return true }
            return members.allSatisfy { Timetable.meters(first, $0) < 30 }
        }

        // MARK: Lines

        /// The walk ring around you (a hairline) and the route to what's tapped, only
        /// while something is tapped.
        func refreshLines() {
            guard let map else { return }
            let route = parent.selectedID == nil ? [] : parent.route
            let here = parent.here
            let key = parent.selectedID == nil ? "" :
                "\(here.roundedKey)|\(route.count)|\(route.first?.latitude ?? 0)|\(route.last?.latitude ?? 0)|\(styleDark)"
            guard key != lineKey else { return }
            lineKey = key
            if let ring { map.removeAnnotation(ring) }
            if let routeLine { map.removeAnnotation(routeLine) }
            ring = nil
            routeLine = nil
            guard parent.selectedID != nil else { return }
            var circle = Self.circle(around: here, radius: PaperMap.walkRadius)
            let r = MLNPolyline(coordinates: &circle, count: UInt(circle.count))
            r.title = "ring"
            ring = r
            map.addAnnotation(r)
            if route.count > 1 {
                var points = route
                let line = MLNPolyline(coordinates: &points, count: UInt(points.count))
                line.title = "route"
                routeLine = line
                map.addAnnotation(line)
            }
        }

        static func circle(around c: CLLocationCoordinate2D, radius: Double, steps: Int = 96) -> [CLLocationCoordinate2D] {
            (0...steps).map { i in
                let a = Double(i) / Double(steps) * 2 * .pi
                return c.offset(east: radius * cos(a), north: radius * sin(a))
            }
        }

        func stroke(for shape: MLNShape, traits: UITraitCollection) -> UIColor {
            let color = shape.title == "route" ? MapInk.accent : MapInk.ink
            return color.resolvedColor(with: traits)
        }

        func width(for line: MLNPolyline) -> CGFloat { line.title == "route" ? 3 : 1 }
        func alpha(for shape: MLNShape) -> CGFloat { shape.title == "route" ? 0.9 : 0.3 }

        // MARK: Camera

        func move(_ kind: Camera.Kind) {
            guard let map else { return }
            let reduce = UIAccessibility.isReduceMotionEnabled
            switch kind {
            case .show(let lat, let lon):
                let zoom = max(map.zoomLevel, 14.5)
                // Sit it in the upper part of the screen, clear of the card.
                let center = Self.shift(CLLocationCoordinate2D(latitude: lat, longitude: lon), down: map.bounds.height * 0.18, zoom: zoom)
                map.setCenter(center, zoomLevel: zoom, animated: !reduce)
            case .recenter(let lat, let lon):
                map.setCenter(CLLocationCoordinate2D(latitude: lat, longitude: lon), zoomLevel: max(map.zoomLevel, 14.5), animated: !reduce)
            case .fit(let places):
                let coords = places.map(\.coordinate)
                guard coords.count > 1 else { return }
                let pad = UIEdgeInsets(top: 160, left: 70, bottom: 220, right: 70)
                let camera = map.cameraThatFitsCoordinateBounds(Self.bounds(of: coords), edgePadding: pad)
                map.setCamera(camera, animated: !reduce)
            }
        }

        static func bounds(of coords: [CLLocationCoordinate2D]) -> MLNCoordinateBounds {
            let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
            return MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: lats.min() ?? 0, longitude: lons.min() ?? 0),
                ne: CLLocationCoordinate2D(latitude: lats.max() ?? 0, longitude: lons.max() ?? 0)
            )
        }

        /// The center that puts `c` `down` points above the middle of the screen at `zoom`.
        static func shift(_ c: CLLocationCoordinate2D, down points: Double, zoom: Double) -> CLLocationCoordinate2D {
            let size = 512 * pow(2, zoom)
            let p = Timetable.worldPoint(latitude: c.latitude, longitude: c.longitude, zoom: zoom)
            let y = p.y + points
            let n = Double.pi - 2 * Double.pi * y / size
            let lat = 180 / Double.pi * atan(0.5 * (exp(n) - exp(-n)))
            return CLLocationCoordinate2D(latitude: lat, longitude: c.longitude)
        }

        // MARK: Moving

        func willMove(_ reason: MLNCameraChangeReason) {
            guard Self.byHand(reason) else { return }
            settle?.cancel()
            if !moving {
                moving = true
                parent.onMoving(true)
            }
        }

        func didMove(_ reason: MLNCameraChangeReason) {
            refreshTags()
            guard moving else { return }
            settle?.cancel()
            // Back once the map has been still for a moment.
            settle = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled else { return }
                self.moving = false
                self.parent.onMoving(false)
            }
        }

        static func byHand(_ reason: MLNCameraChangeReason) -> Bool {
            !reason.isDisjoint(with: [.gesturePan, .gesturePinch, .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom, .gestureRotate, .gestureTilt])
        }

        // MARK: Taps on the map

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let map, tap.state == .ended else { return }
            let p = tap.location(in: map)
            // A tap on a tag is the map's to select.
            let onTag = views.values.contains { v in
                v.superview != nil && v.convert(v.bounds.insetBy(dx: -6, dy: -6), to: map).contains(p)
            }
            if !onTag { parent.onTapMap() }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

extension PaperMap.Coordinator: @preconcurrency MLNMapViewDelegate {
    func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
        if annotation is MLNUserLocation { return nil }
        return view(for: annotation, in: mapView)
    }

    func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
        if annotation is MLNUserLocation { return }
        select(annotation, in: mapView)
    }

    func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { false }

    func mapView(_ mapView: MLNMapView, shapeAnnotationIsEnabled annotation: MLNShape) -> Bool { false }

    func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
        stroke(for: annotation, traits: mapView.traitCollection)
    }

    func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
        width(for: annotation)
    }

    func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat {
        alpha(for: annotation)
    }

    func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        willMove(reason)
    }

    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
        // Regroup during a pinch, a quarter zoom at a time.
        refreshTags()
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        didMove(reason)
    }

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        refreshTags(force: true)
        refreshFriends()
    }
}

