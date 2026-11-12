import Foundation
import CoreLocation

/// Your block: the server picks and ranks what's on within a few blocks (backend `app/block.py`).
extension Sync {
    static func block(around center: CLLocationCoordinate2D) async throws(APIError) -> [BlockItemDTO] {
        guard APIConfig.isConfigured else { return [] }
        let dto: BlockDTO = try await api.send(.get("/v1/me/block", query: [
            URLQueryItem(name: "lat", value: String(center.latitude)),
            URLQueryItem(name: "lon", value: String(center.longitude)),
        ]))
        return dto.items
    }
}
