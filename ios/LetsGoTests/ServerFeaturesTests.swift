import Testing
import Foundation
import CoreLocation
@testable import LetsGo

@Suite("An older server, said plainly")
struct ServerFeaturesTests {
    typealias Feature = ServerFeatures.Feature

    /// The routes the deployed server had before people, listings and posters.
    let oldServer: Set<String> = [
        "/v1/users", "/v1/me", "/v1/nearby", "/v1/gatherings", "/v1/gatherings/{gathering_id}",
        "/v1/gatherings/{gathering_id}/join", "/v1/gatherings/{gathering_id}/check-in",
        "/v1/kitchens", "/v1/kitchens/me", "/v1/kitchens/me/menu", "/v1/kitchens/me/menu/{item_id}",
        "/v1/kitchens/me/drops", "/v1/kitchens/me/orders", "/v1/kitchens/{kitchen_id}",
        "/v1/orders", "/v1/orders/{order_id}/picked-up", "/v1/orders/{order_id}/review", "/health",
    ]

    @Test func readsTheRouteList() throws {
        let json = #"{"openapi":"3.1.0","paths":{"/v1/people":{"get":{}},"/health":{"get":{}}}}"#
        let paths = try #require(Feature.paths(fromOpenAPI: Data(json.utf8)))
        #expect(paths == ["/v1/people", "/health"])
        #expect(Feature.paths(fromOpenAPI: Data("Not Found".utf8)) == nil)
    }

    @Test func theOldServerLacksEverythingNewer() {
        #expect(Feature.missing(in: oldServer) == Set(Feature.allCases))
    }

    @Test func aCurrentServerLacksNothing() {
        let current = oldServer.union(Feature.allCases.flatMap(\.routes))
        #expect(Feature.missing(in: current).isEmpty)
    }

    @Test func requestPathsFindTheirFeature() {
        #expect(Feature.owning("/v1/me/porch-light") == .people)
        #expect(Feature.owning("/v1/friends/code") == .people)
        #expect(Feature.owning("/v1/crews/\(UUID().uuidString)") == .people)
        #expect(Feature.owning("/v1/intros/\(UUID().uuidString)/hi") == .people)
        #expect(Feature.owning("/v1/gatherings/\(UUID().uuidString)/invites") == .people)
        #expect(Feature.owning("/v1/gatherings/\(UUID().uuidString)/poster") == .posters)
        #expect(Feature.owning("/v1/posters/abc234") == .posters)
        #expect(Feature.owning("/v1/listings") == .listings)
        #expect(Feature.owning("/v1/discover") == .discover)
        // The first server's own routes belong to nothing newer.
        #expect(Feature.owning("/v1/me") == nil)
        #expect(Feature.owning("/v1/gatherings/\(UUID().uuidString)/join") == nil)
        #expect(Feature.owning("/v1/kitchens/me/orders") == nil)
    }

    @Test func onlyFastAPIsOwnNotFoundCountsAsAMissingRoute() {
        #expect(APIClient.isMissingRoute(status: 404, reason: "Not Found"))
        #expect(APIClient.isMissingRoute(status: 405, reason: "Method Not Allowed"))
        // Ours always say what wasn't found.
        #expect(!APIClient.isMissingRoute(status: 404, reason: "Gathering not found"))
        #expect(!APIClient.isMissingRoute(status: 404, reason: nil))
        #expect(!APIClient.isMissingRoute(status: 409, reason: "Not Found"))
    }

    @Test func aMissingRouteNeverSaysNotFound() {
        let porch = APIError.notOnServer(path: "/v1/me/porch-light")
        #expect(porch.errorDescription == Feature.people.comingSoon)
        #expect(porch.isNotOnServer)
        #expect(APIError.notOnServer(path: "/v1/somewhere").errorDescription?.contains("Not Found") == false)
        #expect(!APIError.server(status: 500).errorDescription!.contains("500"))
    }

    @Test func aPosterWaitsForTheNewServer() {
        let g = Gathering(
            title: "Pickup soccer", category: .play, details: "", placeName: "The park",
            coordinate: .init(latitude: 37.76, longitude: -122.42), start: .now.addingTimeInterval(3600),
            end: .now.addingTimeInterval(7200), capacity: 12, hostName: "You", bring: "", isMine: true
        )
        g.remoteID = UUID()
        #expect(PosterCopy.unavailable(g, now: .now, serverHasPosters: true) == nil)
        #expect(PosterCopy.unavailable(g, now: .now, serverHasPosters: false) == Feature.posters.comingSoon)
    }
}

@Suite("Kitchen limits")
struct KitchenLimitsTests {
    @Test func clipsToWhatTheServerTakes() {
        #expect(KitchenLimits.clip("Back Gate", KitchenLimits.name) == "Back Gate")
        #expect(KitchenLimits.clip(String(repeating: "a", count: 90), KitchenLimits.name).count == 80)
    }

    @Test func yourOrdersKeepsOnlyWhatsStillOpen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let line = [OrderLine(name: "Cone", priceCents: 500, quantity: 1)]
        let soon = Order(pickupAt: now.addingTimeInterval(1800), lines: line, eatOnPorch: false)
        let justNow = Order(pickupAt: now.addingTimeInterval(-1800), lines: line, eatOnPorch: false)
        let lastWeek = Order(pickupAt: now.addingTimeInterval(-7 * 86_400), lines: line, eatOnPorch: false)
        let toReview = Order(pickupAt: now.addingTimeInterval(-7 * 86_400), lines: line, eatOnPorch: false)
        toReview.status = .pickedUp
        let reviewed = Order(pickupAt: now.addingTimeInterval(-86_400), lines: line, eatOnPorch: false)
        reviewed.status = .reviewed
        let open = OrderLimits.open([soon, justNow, lastWeek, toReview, reviewed], now: now).map(\.id)
        #expect(open == [soon.id, justNow.id, toReview.id])
    }
}
