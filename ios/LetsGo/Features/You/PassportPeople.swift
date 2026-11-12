import SwiftUI

/// Who you were with across your nights out. Plain functions, so they're tested.
enum PassportPeople {
    struct Ranked: Equatable {
        var friend: Friend
        var nights: Int
    }

    /// Everyone you've been out with, most nights first. A night counts once per person.
    static func mostNightsWith(_ nights: [[NightStop]], people: [Friend], limit: Int = 8) -> [Ranked] {
        var counts: [UUID: Int] = [:]
        var names: [UUID: String] = [:]
        for stops in nights {
            var seen = Set<UUID>()
            for stop in stops {
                for (id, name) in zip(stop.withIDs, stop.withNames) where !seen.contains(id) {
                    seen.insert(id)
                    counts[id, default: 0] += 1
                    names[id] = name
                }
            }
        }
        let byID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return counts
            .map { id, n in Ranked(friend: byID[id] ?? Friend(id: id, name: names[id] ?? "Someone"), nights: n) }
            .sorted { $0.nights != $1.nights ? $0.nights > $1.nights : $0.friend.name < $1.friend.name }
            .prefix(limit)
            .map { $0 }
    }

    /// The people with you on one night, in the order you met up.
    static func with(_ stops: [NightStop], people: [Friend]) -> [Friend] {
        let byID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Friend] = []
        for stop in stops {
            for (id, name) in zip(stop.withIDs, stop.withNames) where !out.contains(where: { $0.id == id }) {
                out.append(byID[id] ?? Friend(id: id, name: name))
            }
        }
        return out
    }

    /// "Halloween with Maya & Theo", "Trivia at The Dubliner", "Saturday with Jun".
    static func title(_ stops: [NightStop], evening: Date, with: [Friend], calendar: Calendar = .current) -> String {
        let names = with.prefix(2).map(\.firstName).joined(separator: " & ")
        if let holiday = Planner.holiday(on: evening, calendar: calendar) {
            return names.isEmpty ? holiday : "\(holiday) with \(names)"
        }
        if stops.count == 1 { return stops[0].title }
        let day = evening.formatted(.dateTime.weekday(.wide))
        return names.isEmpty ? "\(day) out" : "\(day) with \(names)"
    }
}

/// A night's date as a passport stamp: a ringed seal, a little crooked.
struct DateSeal: View {
    var date: Date
    var color: Color
    var tilt: Double = -8

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.1))
            Circle().stroke(color, lineWidth: 2)
            Circle().stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).padding(4)
            VStack(spacing: 0) {
                Text(date.formatted(.dateTime.month(.abbreviated)).uppercased()).font(.system(size: 9, weight: .heavy)).tracking(0.9)
                Text(date.formatted(.dateTime.day())).font(.system(size: 20, weight: .heavy)).monospacedDigit()
            }
            .foregroundStyle(color)
        }
        .frame(width: 60, height: 60)
        .rotationEffect(.degrees(tilt))
        .accessibilityLabel(date.formatted(date: .abbreviated, time: .omitted))
    }
}
