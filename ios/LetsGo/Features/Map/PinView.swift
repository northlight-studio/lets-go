import UIKit
import MapLibre

/// The pins on the map, drawn in UIKit for MapLibre (what they say is `Pins`).
/// - A kitchen: a round photo of the drop (or, until there is one, a soft gradient with the
///   dish) in a white ring, with a small black price tag ("$6") under it.
/// - An event: a pill with a dot by kind, the time in bold tabular figures and a short name
///   ("● 7:30 Jazz in the park"); "Now" in the accent for what's on now. White by day, a
///   navy lift after dark. The one you tapped is filled in the accent.
/// - A merged group: a small round count in ink.
/// - A friend: their initials in a white ring, with a speech bubble when they're up for
///   something ("walk?").
enum PinView {
    static func make(group: Timetable.Group, now: Date, selectedID: UUID?, traits: UITraitCollection) -> MLNAnnotationView {
        guard group.isSingle else { return count(group, traits: traits) }
        let c = group.members[0]
        let tapped = c.id == selectedID
        let view = c.kind == .drop ? food(c, tapped: tapped, traits: traits) : event(c, now: now, tapped: tapped, traits: traits)
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        let when = Timetable.isOn(c, now: now) ? "on now" : "at \(HomeLine.clock(c.start))"
        var label = "\(c.title), \(when)"
        if c.kind == .drop, let price = Pins.priceTag(cents: c.priceFromCents) { label += ", from \(price)" }
        view.accessibilityLabel = label
        if tapped { view.accessibilityTraits.insert(.selected) }
        return view
    }

    // MARK: Events

    private static func event(_ c: Candidate, now: Date, tapped: Bool, traits: UITraitCollection) -> MLNAnnotationView {
        let on = Timetable.isOn(c, now: now)
        let height: CGFloat = 26

        let time = UILabel()
        time.text = Pins.time(c, now: now)
        time.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        time.textColor = (tapped ? MapInk.onFill : on ? MapInk.accent : MapInk.pillText).resolvedColor(with: traits)

        let name = UILabel()
        name.text = Pins.shortName(c.title)
        name.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        name.textColor = (tapped ? MapInk.onFill : MapInk.pillName).resolvedColor(with: traits)

        for l in [time, name] { l.adjustsFontForContentSizeCategory = false }
        let timeSize = time.intrinsicContentSize, nameSize = name.intrinsicContentSize
        let dot: CGFloat = 7
        let width = 8 + dot + 5 + ceil(timeSize.width) + 4 + ceil(nameSize.width) + 10

        let view = MLNAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.scalesWithViewingDistance = false
        view.backgroundColor = (tapped ? MapInk.accent : MapInk.pill).resolvedColor(with: traits)
        view.layer.cornerRadius = height / 2
        view.layer.borderWidth = tapped ? 0 : 1
        view.layer.borderColor = MapInk.pillEdge.resolvedColor(with: traits).cgColor
        lift(view, traits: traits)

        let dotView = UIView(frame: CGRect(x: 8, y: (height - dot) / 2, width: dot, height: dot))
        dotView.layer.cornerRadius = dot / 2
        dotView.backgroundColor = tapped ? MapInk.onFill : MapInk.dot(c.category).resolvedColor(with: traits)
        view.addSubview(dotView)

        time.frame = CGRect(x: 8 + dot + 5, y: 0, width: ceil(timeSize.width), height: height)
        name.frame = CGRect(x: time.frame.maxX + 4, y: 0, width: ceil(nameSize.width), height: height)
        view.addSubview(time)
        view.addSubview(name)
        return view
    }

    // MARK: Kitchens

    private static func food(_ c: Candidate, tapped: Bool, traits: UITraitCollection) -> MLNAnnotationView {
        let photo: CGFloat = 38
        let ring: CGFloat = tapped ? 3 : 2.5
        let circle = photo + ring * 2
        let price = Pins.priceTag(cents: c.priceFromCents)
        let tagHeight: CGFloat = 17, tagOverlap: CGFloat = 6
        let height = circle + (price == nil ? 0 : tagHeight - tagOverlap)

        let tagLabel = UILabel()
        tagLabel.text = price
        tagLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        tagLabel.textColor = MapInk.onTag
        tagLabel.textAlignment = .center
        tagLabel.adjustsFontForContentSizeCategory = false
        let tagWidth = price == nil ? 0 : ceil(tagLabel.intrinsicContentSize.width) + 10
        let width = max(circle, tagWidth + 3)

        let view = MLNAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.scalesWithViewingDistance = false
        // The photo's centre sits on the kitchen.
        view.centerOffset = CGVector(dx: 0, dy: height / 2 - circle / 2)

        let ringView = UIView(frame: CGRect(x: (width - circle) / 2, y: 0, width: circle, height: circle))
        ringView.layer.cornerRadius = circle / 2
        ringView.backgroundColor = (tapped ? MapInk.accent : MapInk.ring).resolvedColor(with: traits)
        lift(ringView, traits: traits)
        view.addSubview(ringView)

        let face = UIView(frame: CGRect(x: ring, y: ring, width: photo, height: photo))
        face.layer.cornerRadius = photo / 2
        face.clipsToBounds = true
        ringView.addSubview(face)

        // Until there's a photo: a soft gradient in the food's hue with the dish on it.
        let hue = KitchenLook.hue(for: c.place)
        let gradient = CAGradientLayer()
        gradient.frame = face.bounds
        gradient.colors = [
            UIColor(hue: hue, saturation: 0.28, brightness: 1, alpha: 1).cgColor,
            UIColor(hue: hue + 0.03, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0.2, y: 0)
        gradient.endPoint = CGPoint(x: 0.8, y: 1)
        face.layer.addSublayer(gradient)
        let dish = UILabel(frame: face.bounds)
        dish.text = c.glyph.isEmpty ? "🍽️" : c.glyph
        dish.font = .systemFont(ofSize: 20)
        dish.textAlignment = .center
        dish.adjustsFontForContentSizeCategory = false
        face.addSubview(dish)

        if let url = c.photoURL {
            let image = UIImageView(frame: face.bounds)
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            face.addSubview(image)
            PinPhotos.shared.load(url, into: image)
        }

        if price != nil {
            let tag = UIView(frame: CGRect(x: (width - tagWidth) / 2, y: circle - tagOverlap, width: tagWidth, height: tagHeight))
            tag.backgroundColor = MapInk.tag
            tag.layer.cornerRadius = 6
            tag.layer.borderWidth = 1.5
            tag.layer.borderColor = MapInk.ring.cgColor
            tagLabel.frame = tag.bounds
            tag.addSubview(tagLabel)
            view.addSubview(tag)
        }
        return view
    }

    // MARK: Counts

    private static func count(_ group: Timetable.Group, traits: UITraitCollection) -> MLNAnnotationView {
        let label = UILabel()
        label.text = "\(group.members.count)"
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        label.textColor = MapInk.onCount.resolvedColor(with: traits)
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = false
        let side = max(28, ceil(label.intrinsicContentSize.width) + 14)

        let view = MLNAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.frame = CGRect(x: 0, y: 0, width: side, height: 28)
        view.scalesWithViewingDistance = false
        view.backgroundColor = MapInk.count.resolvedColor(with: traits)
        view.layer.cornerRadius = 14
        view.layer.borderWidth = 2
        view.layer.borderColor = MapInk.ring.cgColor
        lift(view, traits: traits)
        label.frame = view.bounds
        view.addSubview(label)

        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        view.accessibilityLabel = "\(group.members.count) things here"
        view.accessibilityHint = "Zooms in"
        return view
    }

    // MARK: Friends

    static func friend(_ f: Pins.FriendPin, traits: UITraitCollection) -> MLNAnnotationView {
        let face: CGFloat = 30, ring: CGFloat = 2
        let circle = face + ring * 2

        let bubbleLabel = UILabel()
        bubbleLabel.text = f.bubble
        bubbleLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        bubbleLabel.textColor = MapInk.pillText.resolvedColor(with: traits)
        bubbleLabel.adjustsFontForContentSizeCategory = false
        let bubbleWidth = f.bubble == nil ? 0 : ceil(bubbleLabel.intrinsicContentSize.width) + 12
        let bubbleHeight: CGFloat = 20, rise: CGFloat = f.bubble == nil ? 0 : 12
        let width = f.bubble == nil ? circle : circle - 8 + bubbleWidth
        let height = circle + rise

        let view = MLNAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.scalesWithViewingDistance = false
        // The face's centre sits on the friend.
        view.centerOffset = CGVector(dx: width / 2 - circle / 2, dy: height / 2 - (rise + circle / 2))

        let ringView = UIView(frame: CGRect(x: 0, y: rise, width: circle, height: circle))
        ringView.layer.cornerRadius = circle / 2
        ringView.backgroundColor = MapInk.ring
        lift(ringView, traits: traits)
        view.addSubview(ringView)

        let swatch = Friend.swatch(for: f.name)
        let initials = UILabel(frame: CGRect(x: ring, y: ring, width: face, height: face))
        initials.text = f.initials
        initials.font = .systemFont(ofSize: f.initials.count > 1 ? 11.5 : 13, weight: .bold)
        initials.textAlignment = .center
        initials.textColor = UIColor(hex: swatch.ink)
        initials.backgroundColor = UIColor(hex: swatch.fill)
        initials.layer.cornerRadius = face / 2
        initials.clipsToBounds = true
        initials.adjustsFontForContentSizeCategory = false
        ringView.addSubview(initials)

        if f.bubble != nil {
            let bubble = UIView(frame: CGRect(x: circle - 8, y: 0, width: bubbleWidth, height: bubbleHeight))
            bubble.backgroundColor = MapInk.pill.resolvedColor(with: traits)
            bubble.layer.cornerRadius = 9
            // The corner nearest the face is the bubble's tail.
            bubble.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            bubble.layer.borderWidth = 1
            bubble.layer.borderColor = MapInk.pillEdge.resolvedColor(with: traits).cgColor
            lift(bubble, traits: traits)
            bubbleLabel.frame = CGRect(x: 6, y: 0, width: bubbleWidth - 12, height: bubbleHeight)
            bubble.addSubview(bubbleLabel)
            view.addSubview(bubble)
        }

        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        view.accessibilityLabel = f.bubble.map { "\(f.name), up for something: \($0)" } ?? f.name
        view.accessibilityHint = "Opens People"
        return view
    }

    // MARK: Shared

    /// A soft shadow under a pin so it sits on the map.
    private static func lift(_ v: UIView, traits: UITraitCollection) {
        v.layer.shadowColor = MapInk.shadow.resolvedColor(with: traits).cgColor
        v.layer.shadowOpacity = 1
        v.layer.shadowRadius = 4
        v.layer.shadowOffset = CGSize(width: 0, height: 2)
    }
}

/// Drop photos for the map's kitchen pins, fetched once and kept small in memory. A pin
/// shows its gradient and dish until the photo arrives, and keeps them if it never does.
@MainActor
final class PinPhotos {
    static let shared = PinPhotos()
    private let cache = NSCache<NSURL, UIImage>()

    func load(_ url: URL, into view: UIImageView) {
        if let image = cache.object(forKey: url as NSURL) {
            view.image = image
            return
        }
        Task { [weak view] in
            guard let image = await fetch(url) else { return }
            view?.image = image
        }
    }

    private func fetch(_ url: URL) async -> UIImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = UIImage(data: data) else { return nil }
            let small = image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
            cache.setObject(small, forKey: url as NSURL)
            return small
        } catch {
            print("Map pin photo failed: \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}
