import Foundation

/// Wren's three for right now: the server says how well each nearby thing fits you (backend
/// `app/right_now.py`); the phone still does the ranking (`RightNow`).
extension Sync {
    static func rightNow(_ body: RightNowBody) async throws(APIError) -> RightNowDTO {
        guard APIConfig.isConfigured else { return RightNowDTO(scored: false, fits: []) }
        let dto: RightNowDTO = try await api.send(.post("/v1/me/right-now", body))
        return dto
    }
}
