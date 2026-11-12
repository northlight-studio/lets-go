import Foundation
import OSLog

/// Where the backend lives. Nil means the app runs on this phone's data only.
nonisolated enum APIConfig {
    /// Set under Passport → Server (for a dev server or an ngrok tunnel), or with the
    /// LETSGO_API environment variable when running from Xcode.
    static let overrideKey = "api.baseURL"
    /// The deployed backend (Railway project "lets-go", service "api").
    static let deployed: URL? = URL(string: "https://api-production-658b9.up.railway.app")

    static var baseURL: URL? {
        if let s = ProcessInfo.processInfo.environment["LETSGO_API"], let url = URL(string: s) { return url }
        if let s = UserDefaults.standard.string(forKey: overrideKey)?.trimmingCharacters(in: .whitespaces),
           !s.isEmpty, let url = URL(string: s) { return url }
        return deployed
    }

    static var isConfigured: Bool { baseURL != nil }

    /// A path the server sent ("/v1/photos/…") as a full URL on whichever server the phone uses.
    static func resolve(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        return baseURL?.appending(path: path)
    }
}

nonisolated enum APIError: LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    /// The server said no, with a reason worth showing ("It's full", "Only 3 left").
    case rejected(status: Int, reason: String)
    case server(status: Int)
    case offline(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "No server is set up."
        case .unauthorized: "Your session expired. Try again."
        case .rejected(_, let reason): reason
        case .server(let status): "The server had a problem (\(status)). Try again in a bit."
        case .offline(let message): "Couldn't reach the server: \(message)"
        case .decoding: "The server sent something this version doesn't understand."
        }
    }
}

nonisolated struct Endpoint<Response: Decodable & Sendable>: Sendable {
    var method: String
    var path: String
    var query: [URLQueryItem] = []
    var body: Data?
    var contentType = "application/json"
    /// Only safe-to-repeat requests retry. A POST that timed out may still have
    /// happened on the server; repeating it could, say, place a second order.
    var retries: Int { method == "GET" || method == "DELETE" || method == "PUT" ? 2 : 0 }

    static func get(_ path: String, query: [URLQueryItem] = []) -> Endpoint {
        Endpoint(method: "GET", path: path, query: query)
    }

    static func post(_ path: String, _ body: some Encodable) -> Endpoint {
        Endpoint(method: "POST", path: path, body: try? JSONCoding.encoder.encode(body))
    }

    static func post(_ path: String) -> Endpoint {
        Endpoint(method: "POST", path: path)
    }

    static func patch(_ path: String, _ body: some Encodable) -> Endpoint {
        Endpoint(method: "PATCH", path: path, body: try? JSONCoding.encoder.encode(body))
    }

    /// Sets something to exactly this, so repeating it is safe.
    static func put(_ path: String, _ body: some Encodable) -> Endpoint {
        Endpoint(method: "PUT", path: path, body: try? JSONCoding.encoder.encode(body))
    }

    static func put(_ path: String) -> Endpoint {
        Endpoint(method: "PUT", path: path)
    }

    /// A photo, as the request body.
    static func upload(_ path: String, jpeg: Data) -> Endpoint {
        Endpoint(method: "POST", path: path, body: jpeg, contentType: "image/jpeg")
    }

    static func delete(_ path: String) -> Endpoint {
        Endpoint(method: "DELETE", path: path)
    }
}

nonisolated struct Empty: Codable, Sendable {}

nonisolated enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }()

    /// Python sends microseconds ("…T05:06:26.123456+00:00"); Foundation wants at most milliseconds.
    static func parseDate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = withFraction.date(from: s) ?? plain.date(from: s) { return d }
        // Trim the fraction to 3 digits and try again.
        guard let dot = s.firstIndex(of: "."),
              let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else { return nil }
        let digits = s[s.index(after: dot)..<tz].prefix(3)
        return withFraction.date(from: String(s[..<dot]) + "." + digits + String(s[tz...]))
    }
}

/// Talks to the Let's Go backend. Creates a device account the first time and
/// keeps its token in the Keychain.
final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let log = Logger(subsystem: "com.yasser100ali.letsgo", category: "api")
    private static let tokenKey = "api.token"
    static let nameKey = "profile.displayName"

    init(session: URLSession = APIClient.defaultSession) {
        self.session = session
    }

    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    var displayName: String {
        UserDefaults.standard.string(forKey: Self.nameKey).flatMap { $0.isEmpty ? nil : $0 } ?? "Neighbor"
    }

    func send<R>(_ endpoint: Endpoint<R>) async throws(APIError) -> R {
        guard let base = APIConfig.baseURL else { throw .notConfigured }
        let token = try await ensureToken(base: base)
        do {
            return try await perform(endpoint, base: base, token: token)
        } catch .unauthorized {
            // The server forgot us (fresh database). Make a new account once.
            Keychain.delete(Self.tokenKey)
            let fresh = try await ensureToken(base: base)
            return try await perform(endpoint, base: base, token: fresh)
        }
    }

    private func ensureToken(base: URL) async throws(APIError) -> String {
        if let t = Keychain.read(Self.tokenKey) { return t }
        nonisolated struct NewUser: Encodable, Sendable { var displayName: String }
        nonisolated struct Created: Decodable, Sendable { var token: String }
        let created: Created = try await perform(.post("/v1/users", NewUser(displayName: displayName)), base: base, token: nil)
        Keychain.write(created.token, for: Self.tokenKey)
        return created.token
    }

    private func perform<R>(_ e: Endpoint<R>, base: URL, token: String?) async throws(APIError) -> R {
        var components = URLComponents(url: base.appending(path: e.path), resolvingAgainstBaseURL: false)
        if !e.query.isEmpty { components?.queryItems = e.query }
        guard let url = components?.url else { throw .offline("bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = e.method
        request.httpBody = e.body
        request.setValue(e.contentType, forHTTPHeaderField: "Content-Type")
        // Lets the app talk to an ngrok tunnel without its browser warning page.
        request.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200..<300:
                    if R.self == Empty.self, let empty = Empty() as? R { return empty }
                    do {
                        return try JSONCoding.decoder.decode(R.self, from: data)
                    } catch {
                        log.error("Decode \(e.path, privacy: .public): \(String(describing: error), privacy: .public)")
                        throw APIError.decoding(String(describing: error))
                    }
                case 401:
                    throw APIError.unauthorized
                case 400..<500:
                    throw APIError.rejected(status: status, reason: Self.reason(from: data) ?? "That didn't work (\(status)).")
                default:
                    if attempt < e.retries { attempt += 1; try? await Task.sleep(for: .seconds(attempt)); continue }
                    throw APIError.server(status: status)
                }
            } catch let error as APIError {
                throw error
            } catch {
                if attempt < e.retries { attempt += 1; try? await Task.sleep(for: .seconds(attempt)); continue }
                log.error("\(e.method, privacy: .public) \(e.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                throw APIError.offline(error.localizedDescription)
            }
        }
    }

    /// FastAPI errors look like {"detail": "It's full"} or {"detail": [{"msg": …}]}.
    private static func reason(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let s = obj["detail"] as? String { return s }
        if let list = obj["detail"] as? [[String: Any]], let msg = list.first?["msg"] as? String {
            return msg.replacingOccurrences(of: "Value error, ", with: "")
        }
        return nil
    }
}
