import Foundation
import Observation
import OSLog

/// What the server Let's Go talks to can do. A server still running an older build lacks the
/// newer routes, and a feature that needs one says so plainly ("coming soon") or steps aside,
/// instead of failing with the server's "Not Found".
///
/// It reads the server's own route list (`/openapi.json`) when the app pulls, and a request that
/// comes back from a missing route marks its feature too. Until it knows, everything counts as
/// there, so nothing is hidden while the phone is offline.
@Observable
final class ServerFeatures {
    static let shared = ServerFeatures()

    nonisolated enum Feature: String, CaseIterable, Sendable {
        /// Friends, porch lights, crews, intros and invites.
        case people
        /// The lamppost poster.
        case posters
        /// The city's listings.
        case listings
        /// The city catalog and the scout.
        case discover

        /// Routes (as the server's OpenAPI lists them) the feature can't work without.
        var routes: [String] {
            switch self {
            case .people: ["/v1/people", "/v1/friends/code", "/v1/me/porch-light", "/v1/gatherings/{gathering_id}/invites"]
            case .posters: ["/v1/gatherings/{gathering_id}/poster"]
            case .listings: ["/v1/listings"]
            case .discover: ["/v1/discover"]
            }
        }

        /// The feature a request path belongs to, when it's one the first server didn't have.
        static func owning(_ path: String) -> Feature? {
            if path.hasSuffix("/poster") || path.hasPrefix("/v1/posters") { return .posters }
            if path.hasSuffix("/invites") { return .people }
            let people = ["/v1/people", "/v1/friends", "/v1/me/porch-light", "/v1/crews", "/v1/intros"]
            if people.contains(where: { path.hasPrefix($0) }) { return .people }
            if path.hasPrefix("/v1/listings") { return .listings }
            if ["/v1/discover", "/v1/scout", "/v1/me/finds"].contains(where: { path.hasPrefix($0) }) { return .discover }
            return nil
        }

        /// One plain line for when the server doesn't have it yet.
        var comingSoon: String {
            switch self {
            case .people: "Friends, porch lights and crews need the new server. They're coming soon."
            case .posters: "Posters need the new server. They're coming soon."
            case .listings: "The city's newest listings need the new server. These are the ones that came with the app."
            case .discover: "Searching the city needs the new server. It's coming soon."
            }
        }

        /// The routes from an OpenAPI document, or nil if it isn't one.
        static func paths(fromOpenAPI data: Data) -> Set<String>? {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let paths = obj["paths"] as? [String: Any] else { return nil }
            return Set(paths.keys)
        }

        /// The features a server with these routes is missing.
        static func missing(in paths: Set<String>) -> Set<Feature> {
            Set(allCases.filter { !Set($0.routes).isSubset(of: paths) })
        }
    }

    private(set) var missing: Set<Feature> = []
    private var checkedBase: URL?
    private var checkedAt: Date?
    private let log = Logger(subsystem: "com.yasser100ali.letsgo", category: "api")

    func has(_ feature: Feature) -> Bool { !missing.contains(feature) }

    /// A request to `path` hit a route the server doesn't have.
    func noteMissing(path: String) {
        guard let f = Feature.owning(path), !missing.contains(f) else { return }
        log.info("The server has no \(f.rawValue, privacy: .public) yet (\(path, privacy: .public))")
        missing.insert(f)
    }

    /// Reads the server's route list, at most every ten minutes, and again when the server changes.
    func check(session: URLSession = APIClient.defaultSession, now: Date = .now) async {
        guard let base = APIConfig.baseURL else { missing = []; return }
        if base != checkedBase { missing = [] }
        if base == checkedBase, let at = checkedAt, now.timeIntervalSince(at) < 10 * 60 { return }
        var request = URLRequest(url: base.appending(path: "/openapi.json"))
        request.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let paths = Feature.paths(fromOpenAPI: data) else { return }
            missing = Feature.missing(in: paths)
            checkedBase = base
            checkedAt = now
        } catch {
            // Offline: keep what was known.
            log.error("Couldn't read the server's routes: \(error.localizedDescription, privacy: .public)")
        }
    }
}
