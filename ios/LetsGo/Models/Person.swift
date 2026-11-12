import Foundation
import SwiftData
import SwiftUI
import CoreLocation

/// Someone you go out with. Friends come from the server: you became friends by trading a code.
@Model
final class Person {
    /// A real friend's id is their id on the server.
    var id: UUID
    var name: String
    /// Left from the sample neighborhood, which is gone. Only `SamplePurge` reads these, to clear
    /// what older versions stored; they stay in the model so the store opens without a migration.
    var isSample: Bool
    var sampleRole: String = ""
    /// Up for something (once called the porch light) until then. `porchNote` is what, as it reads ("A walk").
    var porchUntil: Date?
    var porchNote: String = ""
    /// What they're up for: walk, coffee, drink, pickup, cooking, or "" for their own words.
    var upActivity: String = ""
    /// How far a walk they are, rounded, from the server. Never where they are.
    var upWalkMinutes: Int?
    /// Where they are, only when that's a gathering they checked in to (public anyway).
    var latitude: Double?
    var longitude: Double?
    /// What they joined tonight, from the server: "there" (checked in) or "heading".
    var outStateRaw: String = ""
    var outTitle: String = ""
    var outPlace: String = ""
    var outStart: Date?
    var outGatheringID: UUID?
    var outLatitude: Double?
    var outLongitude: Double?
    /// They waved at you.
    var wavedAt: Date?
    /// You waved at them.
    var youWavedAt: Date?
    /// The hour they're free from on a weekend, when they've shared it, for Wren's planning.
    var freeAfterHour: Int?

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
        self.isSample = false
    }
}

/// A named group of friends: "Tuesday trivia", "the run lot".
@Model
final class Crew {
    var id: UUID
    var name: String
    /// `Person.id`s, you not included.
    var memberIDs: [UUID]
    var isMine: Bool
    /// Only `SamplePurge` reads this (see `Person.isSample`).
    var isSample: Bool
    /// The next thing two or more of the crew are in for, from the server.
    var nextTitle: String = ""
    var nextStart: Date?
    var nextGatheringID: UUID?

    init(id: UUID = UUID(), name: String, memberIDs: [UUID], isMine: Bool = true) {
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
        self.isMine = isMine
        self.isSample = false
    }
}

/// A person as the screens and Wren reason about them: a plain value, so it can be tested.
struct Friend: Identifiable, Hashable, Sendable {
    enum OutState: String, Sendable { case there, heading }

    struct Out: Hashable, Sendable {
        var state: OutState
        var title: String
        var place: String
        var start: Date?
        /// The local gathering they're at or heading to, when this phone has it.
        var gatheringID: UUID?
        var latitude: Double?
        var longitude: Double?
    }

    var id: UUID
    var name: String
    var porchUntil: Date?
    var porchNote: String = ""
    var upActivity: String = ""
    var upWalkMinutes: Int?
    var latitude: Double?
    var longitude: Double?
    var out: Out?
    var wavedAt: Date?
    var youWavedAt: Date?
    var freeAfterHour: Int?

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
    var initial: String { String(name.first ?? "?").uppercased() }

    func porchOn(at now: Date) -> Bool { (porchUntil ?? .distantPast) > now }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return .init(latitude: latitude, longitude: longitude)
    }

    /// Ink, pastel and amber: one per person, the same every time.
    var color: Color { Color(hex: Self.hue(for: name)) }
    var ink: Color { Color(hex: Self.ink(for: name)) }

    static let swatches: [(fill: UInt32, ink: UInt32)] = [
        (0xF2B04B, 0x2A1A00), (0x7DB5FF, 0x04182F), (0x6ED7A0, 0x052414), (0xF58FB7, 0x2E0716),
        (0xB9A2FF, 0x170A33), (0xFF9F7A, 0x2E0E02), (0xE9E4D8, 0x1B1A17), (0x9FD9E8, 0x062A33),
    ]

    /// A stable pick for each name.
    static func swatch(for name: String) -> (fill: UInt32, ink: UInt32) {
        return swatches[Int(Art.unit(name, 7) * Double(swatches.count)) % swatches.count]
    }

    static func hue(for name: String) -> UInt32 { swatch(for: name).fill }
    static func ink(for name: String) -> UInt32 { swatch(for: name).ink }
}

extension Person {
    var snapshot: Friend {
        var out: Friend.Out?
        if let state = Friend.OutState(rawValue: outStateRaw) {
            out = Friend.Out(
                state: state, title: outTitle, place: outPlace, start: outStart,
                gatheringID: outGatheringID, latitude: outLatitude, longitude: outLongitude
            )
        }
        return Friend(
            id: id, name: name,
            porchUntil: porchUntil, porchNote: porchNote, upActivity: upActivity, upWalkMinutes: upWalkMinutes,
            latitude: latitude, longitude: longitude,
            out: out, wavedAt: wavedAt, youWavedAt: youWavedAt, freeAfterHour: freeAfterHour
        )
    }
}

/// Someone you keep ending up at the same things with: three real check-ins together.
/// If you both say hi, you're friends; if one doesn't, nobody hears a thing.
@Model
final class Intro {
    /// Their id on the server.
    var id: UUID
    var name: String
    var together: [SharedNight]
    var saidHi: Bool
    /// Only `SamplePurge` reads this (see `Person.isSample`).
    var isSample: Bool
    var dismissed: Bool = false
    /// What they're up for, when they are: people you've met see each other's.
    var upUntil: Date?
    var upActivity: String = ""
    var upLabel: String = ""
    var upWalkMinutes: Int?
    var wavedAt: Date?
    var youWavedAt: Date?

    init(id: UUID, name: String, together: [SharedNight], saidHi: Bool = false) {
        self.id = id
        self.name = name
        self.together = together
        self.saidHi = saidHi
        self.isSample = false
    }

    var friend: Friend {
        Friend(id: id, name: name, porchUntil: upUntil, porchNote: upLabel, upActivity: upActivity,
               upWalkMinutes: upWalkMinutes, wavedAt: wavedAt, youWavedAt: youWavedAt)
    }
}

/// You and one other person meeting, after one of you said I'm in. From the server; seen only by the
/// two of you, until Done. Their position never comes down: only how many minutes off they are.
@Model
final class UpMatch {
    var id: UUID
    var otherID: UUID
    var otherName: String
    /// It was your "up for" they said I'm in to.
    var isMine: Bool
    var activity: String
    var label: String
    var headline: String
    var spotName: String = ""
    var spotLatitude: Double?
    var spotLongitude: Double?
    /// Roughly halfway, rounded to a few hundred metres: where this phone looks for a spot.
    var areaLatitude: Double?
    var areaLongitude: Double?
    var meetAt: Date
    var endsAt: Date
    var myWalkMinutes: Int?
    var theirWalkMinutes: Int?
    var iAmOnMyWay: Bool = false
    var theyAreOnTheirWay: Bool = false
    var theySay: String = ""
    var iSaid: String = ""

    init(id: UUID, otherID: UUID, otherName: String, isMine: Bool, activity: String, label: String,
         headline: String, meetAt: Date, endsAt: Date) {
        self.id = id
        self.otherID = otherID
        self.otherName = otherName
        self.isMine = isMine
        self.activity = activity
        self.label = label
        self.headline = headline
        self.meetAt = meetAt
        self.endsAt = endsAt
    }

    var other: Friend { Friend(id: otherID, name: otherName) }

    var spot: CLLocationCoordinate2D? {
        guard let spotLatitude, let spotLongitude else { return nil }
        return .init(latitude: spotLatitude, longitude: spotLongitude)
    }

    var area: CLLocationCoordinate2D? {
        guard let areaLatitude, let areaLongitude else { return nil }
        return .init(latitude: areaLatitude, longitude: areaLongitude)
    }
}

struct SharedNight: Codable, Hashable, Sendable {
    var title: String
    var startsAt: Date
}

/// A seat at a kitchen's shared porch table: who sits down when.
struct TableSeat: Codable, Hashable, Sendable {
    var personID: UUID
    var name: String
    var at: Date
}
