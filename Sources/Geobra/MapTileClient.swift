import Foundation
import GeobraCore

enum MapTileError: Error, LocalizedError, Equatable {
    case missingGoogleKey
    case credentialsUnavailable
    case invalidTile
    case invalidViewport
    case authentication
    case rateLimited
    case unavailable
    case invalidResponse
    case network

    var errorDescription: String? {
        switch self {
        case .missingGoogleKey:
            return "Add a Google Maps API key in Map Sources settings."
        case .credentialsUnavailable:
            return "Geobra could not read the Google Maps key from Keychain."
        case .invalidTile:
            return "The requested map tile is outside the supported range."
        case .invalidViewport:
            return "The map viewport is outside the supported range."
        case .authentication:
            return "The map service rejected this request. Check provider access and API key restrictions."
        case .rateLimited:
            return "The map service reached its request limit. Try again later."
        case .unavailable:
            return "The map service is unavailable. Try again later."
        case .invalidResponse:
            return "The map service returned an invalid response."
        case .network:
            return "Geobra could not connect to the map service. Check the internet connection."
        }
    }
}

actor MapTileClient {
    private let osmSession: URLSession
    private let googleSession: URLSession
    private let credentialReader: @Sendable () throws -> String?
    private let clock: @Sendable () -> Date
    private let language: String
    private let region: String
    private var activeGoogleKey: String?
    private var sessions: [MapSource: GoogleSession] = [:]
    private var sessionRequests: [MapSource: SessionRequest] = [:]

    init(session: URLSession? = nil,
         credentialReader: @escaping @Sendable () throws -> String? = { try GoogleMapsCredentialStore.read() },
         clock: @escaping @Sendable () -> Date = { Date() },
         language: String = Locale.preferredLanguages.first ?? "en-US",
         region: String = Locale.current.region?.identifier ?? "US") {
        osmSession = session ?? Self.makeSession(diskCache: true)
        googleSession = session ?? Self.makeSession(diskCache: false)
        self.credentialReader = credentialReader
        self.clock = clock
        self.language = language
        self.region = region
    }

    func tileData(for tile: MapTile, source: MapSource) async throws -> Data {
        try Task.checkCancellation()
        guard tile.isValid, tile.zoom <= source.maximumZoom else { throw MapTileError.invalidTile }
        if source == .openStreetMap {
            let url = URL(string: "https://tile.openstreetmap.org/\(tile.zoom)/\(tile.x)/\(tile.y).png")!
            let request = Self.makeRequest(url: url)
            return try await Self.imageData(for: request, session: osmSession)
        }
        let key = try googleKey()
        return try await googleTile(tile, source: source, key: key, canRenew: true)
    }

    func attribution(for viewport: MapViewport, source: MapSource) async throws -> MapAttribution {
        try Task.checkCancellation()
        guard viewport.isValid, viewport.zoom <= source.maximumZoom else { throw MapTileError.invalidViewport }
        if source == .openStreetMap {
            return MapAttribution(text: "© OpenStreetMap contributors", maximumZoom: source.maximumZoom)
        }
        let key = try googleKey()
        return try await googleAttribution(viewport, source: source, key: key, canRenew: true)
    }

    private func googleTile(_ tile: MapTile, source: MapSource, key: String, canRenew: Bool) async throws -> Data {
        let session = try await self.session(for: source, key: key)
        try Task.checkCancellation()
        let url = try Self.googleURL(path: "/v1/2dtiles/\(tile.zoom)/\(tile.x)/\(tile.y)", query: [
            URLQueryItem(name: "session", value: session.token),
            URLQueryItem(name: "key", value: key)
        ])
        do {
            return try await Self.imageData(for: Self.makeRequest(url: url), session: googleSession)
        } catch ServiceResponse.invalidSession where canRenew {
            invalidateSession(for: source, matching: session.token)
            return try await googleTile(tile, source: source, key: key, canRenew: false)
        } catch ServiceResponse.invalidSession {
            throw MapTileError.invalidResponse
        }
    }

    private func googleAttribution(_ viewport: MapViewport, source: MapSource,
                                   key: String, canRenew: Bool) async throws -> MapAttribution {
        let session = try await self.session(for: source, key: key)
        try Task.checkCancellation()
        let query = [
            URLQueryItem(name: "session", value: session.token),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "zoom", value: String(viewport.zoom)),
            URLQueryItem(name: "north", value: String(min(89.9999999, viewport.north))),
            URLQueryItem(name: "south", value: String(max(-89.9999999, viewport.south))),
            URLQueryItem(name: "east", value: String(min(179.9999999, viewport.east))),
            URLQueryItem(name: "west", value: String(max(-179.9999999, viewport.west)))
        ]
        let url = try Self.googleURL(path: "/tile/v1/viewport", query: query)
        do {
            let data = try await Self.responseData(for: Self.makeRequest(url: url), session: googleSession).0
            guard let response = try? JSONDecoder().decode(ViewportResponse.self, from: data),
                  !response.copyright.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MapTileError.invalidResponse
            }
            let maximum = response.maxZoomRects?.filter { $0.intersects(viewport) }.map(\.maxZoom).max()
            return MapAttribution(text: response.copyright, maximumZoom: maximum)
        } catch ServiceResponse.invalidSession where canRenew {
            invalidateSession(for: source, matching: session.token)
            return try await googleAttribution(viewport, source: source, key: key, canRenew: false)
        } catch ServiceResponse.invalidSession {
            throw MapTileError.invalidResponse
        }
    }

    private func googleKey() throws -> String {
        let key: String
        do {
            key = try credentialReader()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            throw MapTileError.credentialsUnavailable
        }
        guard !key.isEmpty else { throw MapTileError.missingGoogleKey }
        if activeGoogleKey != key {
            activeGoogleKey = key
            sessions.removeAll()
            sessionRequests.values.forEach { $0.task.cancel() }
            sessionRequests.removeAll()
            googleSession.configuration.urlCache?.removeAllCachedResponses()
        }
        return key
    }

    private func session(for source: MapSource, key: String) async throws -> GoogleSession {
        guard activeGoogleKey == key else { throw CancellationError() }
        if let session = sessions[source], session.key == key, session.expiry > clock().addingTimeInterval(60) {
            return session
        }
        let pending: SessionRequest
        if let request = sessionRequests[source], request.key == key {
            pending = request
        } else {
            let networkSession = googleSession
            let language = language
            let region = region
            let task = Task {
                try await Self.createSession(source: source, key: key, language: language,
                                             region: region, session: networkSession)
            }
            pending = SessionRequest(id: UUID(), key: key, task: task)
            sessionRequests[source] = pending
        }
        do {
            let created = try await pending.task.value
            guard activeGoogleKey == key else { throw CancellationError() }
            guard created.expiry > clock() else { throw MapTileError.invalidResponse }
            sessions[source] = created
            if sessionRequests[source]?.id == pending.id { sessionRequests[source] = nil }
            return created
        } catch {
            if sessionRequests[source]?.id == pending.id { sessionRequests[source] = nil }
            throw error
        }
    }

    private func invalidateSession(for source: MapSource, matching token: String) {
        if sessions[source]?.token == token { sessions[source] = nil }
    }

    private static func createSession(source: MapSource, key: String, language: String,
                                      region: String, session: URLSession) async throws -> GoogleSession {
        let url = try googleURL(path: "/v1/createSession", query: [URLQueryItem(name: "key", value: key)])
        var request = makeRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "mapType": source == .googleRoadmap ? "roadmap" : "satellite",
            "language": language,
            "region": region,
            "imageFormat": "png"
        ]
        if source == .googleHybrid {
            body["layerTypes"] = ["layerRoadmap"]
            body["overlay"] = false
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        do {
            let data = try await responseData(for: request, session: session).0
            guard let response = try? JSONDecoder().decode(SessionResponse.self, from: data),
                  let expiry = Double(response.expiry), expiry.isFinite, !response.session.isEmpty else {
                throw MapTileError.invalidResponse
            }
            return GoogleSession(token: response.session, expiry: Date(timeIntervalSince1970: expiry), key: key)
        } catch ServiceResponse.invalidSession {
            throw MapTileError.invalidResponse
        }
    }

    private static func imageData(for request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await responseData(for: request, session: session)
        guard ["image/png", "image/jpeg"].contains(response.mimeType ?? ""), !data.isEmpty else {
            throw MapTileError.invalidResponse
        }
        return data
    }

    private static func responseData(for request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw MapTileError.network
        }
        guard let response = response as? HTTPURLResponse else { throw MapTileError.invalidResponse }
        switch response.statusCode {
        case 200...299: break
        case 400, 410:
            if request.url?.host == "tile.googleapis.com" { throw ServiceResponse.invalidSession }
            throw MapTileError.invalidResponse
        case 401, 403: throw MapTileError.authentication
        case 429: throw MapTileError.rateLimited
        case 500...599: throw MapTileError.unavailable
        default: throw MapTileError.invalidResponse
        }
        guard data.count <= 8 * 1024 * 1024 else { throw MapTileError.invalidResponse }
        return (data, response)
    }

    private static func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
        request.setValue("Geobra/0.1 (+https://github.com/jturolla/geobra)", forHTTPHeaderField: "User-Agent")
        request.setValue("image/png,image/jpeg,application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func googleURL(path: String, query: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tile.googleapis.com"
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw MapTileError.invalidResponse }
        return url
    }

    private static func makeSession(diskCache: Bool) -> URLSession {
        let configuration = diskCache ? URLSessionConfiguration.default : .ephemeral
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: diskCache ? 256 * 1024 * 1024 : 0,
            diskPath: diskCache ? "GeobraOpenStreetMap" : nil
        )
        return URLSession(configuration: configuration)
    }
}

private struct GoogleSession: Sendable {
    let token: String
    let expiry: Date
    let key: String
}

private struct SessionRequest {
    let id: UUID
    let key: String
    let task: Task<GoogleSession, Error>
}

private struct SessionResponse: Decodable {
    let session: String
    let expiry: String
}

private struct ViewportResponse: Decodable {
    let copyright: String
    let maxZoomRects: [ZoomRectangle]?
}

private struct ZoomRectangle: Decodable {
    let maxZoom: Int
    let north: Double
    let south: Double
    let east: Double
    let west: Double

    func intersects(_ viewport: MapViewport) -> Bool {
        guard (0...22).contains(maxZoom), (-90...90).contains(south), (-90...90).contains(north),
              (-180...180).contains(west), (-180...180).contains(east), north >= south else { return false }
        guard south <= viewport.north, north >= viewport.south else { return false }
        let ownRanges = longitudeRanges(west: west, east: east)
        let viewportRanges = longitudeRanges(west: viewport.west, east: viewport.east)
        return ownRanges.contains { own in viewportRanges.contains { own.overlaps($0) } }
    }

    private func longitudeRanges(west: Double, east: Double) -> [ClosedRange<Double>] {
        west <= east ? [west...east] : [west...180, -180...east]
    }
}

private enum ServiceResponse: Error {
    case invalidSession
}
