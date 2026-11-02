import Foundation
import GeobraCore
import XCTest
@testable import Geobra

final class MapTileClientTests: XCTestCase {
    private let tile = MapTile(zoom: 3, x: 2, y: 4)
    private let viewport = MapViewport(zoom: 3, north: 20, south: -20, east: 30, west: -30)

    override func tearDown() {
        MapProtocol.configure { _ in .image }
        super.tearDown()
    }

    func testOpenStreetMapUsesOfficialXYZEndpoint() async throws {
        MapProtocol.configure { _ in .image }
        _ = try await makeClient().tileData(for: tile, source: .openStreetMap)
        XCTAssertEqual(MapProtocol.requests.first?.url?.absoluteString, "https://tile.openstreetmap.org/3/2/4.png")
    }

    func testOpenStreetMapUsesIdentifiableUserAgent() async throws {
        MapProtocol.configure { _ in .image }
        _ = try await makeClient().tileData(for: tile, source: .openStreetMap)
        XCTAssertEqual(MapProtocol.requests.first?.value(forHTTPHeaderField: "User-Agent"),
                       "Geobra/0.1 (+https://github.com/jturolla/geobra)")
    }

    func testOpenStreetMapHonorsHTTPCachePolicy() async throws {
        MapProtocol.configure { _ in .image }
        _ = try await makeClient().tileData(for: tile, source: .openStreetMap)
        XCTAssertEqual(MapProtocol.requests.first?.cachePolicy, .useProtocolCachePolicy)
    }

    func testOpenStreetMapDoesNotSendCacheBypassHeader() async throws {
        MapProtocol.configure { _ in .image }
        _ = try await makeClient().tileData(for: tile, source: .openStreetMap)
        XCTAssertNil(MapProtocol.requests.first?.value(forHTTPHeaderField: "Cache-Control"))
    }

    func testOpenStreetMapAttributionRequiresNoNetwork() async throws {
        MapProtocol.configure { _ in .image }
        _ = try await makeClient().attribution(for: viewport, source: .openStreetMap)
        XCTAssertTrue(MapProtocol.requests.isEmpty)
    }

    func testOpenStreetMapAttributionIncludesContributors() async throws {
        let attribution = try await makeClient().attribution(for: viewport, source: .openStreetMap)
        XCTAssertEqual(attribution.text, "© OpenStreetMap contributors")
    }

    func testRejectsInvalidTileBeforeNetworkRequest() async {
        MapProtocol.configure { _ in .image }
        do { _ = try await makeClient().tileData(for: MapTile(zoom: 3, x: 8, y: 0), source: .openStreetMap) }
        catch {}
        XCTAssertTrue(MapProtocol.requests.isEmpty)
    }

    func testRejectsOpenStreetMapZoomAboveNineteen() async {
        do {
            _ = try await makeClient().tileData(for: MapTile(zoom: 20, x: 0, y: 0), source: .openStreetMap)
            XCTFail("The client accepted an unsupported zoom level.")
        } catch { XCTAssertEqual(error as? MapTileError, .invalidTile) }
    }

    func testGoogleRequiresConfiguredKey() async {
        do {
            _ = try await makeClient(key: nil).tileData(for: tile, source: .googleRoadmap)
            XCTFail("The client accepted a missing key.")
        } catch { XCTAssertEqual(error as? MapTileError, .missingGoogleKey) }
    }

    func testGoogleCreatesOfficialSessionBeforeTileRequest() async throws {
        MapProtocol.configure { request in
            request.url?.path == "/v1/createSession" ? .session(token: "session-one") : .image
        }
        _ = try await makeClient().tileData(for: tile, source: .googleRoadmap)
        XCTAssertEqual(MapProtocol.requests.map { $0.url?.path }, ["/v1/createSession", "/v1/2dtiles/3/2/4"])
    }

    func testGoogleSessionUsesPOSTAndJSON() async throws {
        MapProtocol.configure { request in
            request.url?.path == "/v1/createSession" ? .session(token: "session-one") : .image
        }
        _ = try await makeClient().tileData(for: tile, source: .googleRoadmap)
        let request = try XCTUnwrap(MapProtocol.requests.first)
        XCTAssertEqual([request.httpMethod, request.value(forHTTPHeaderField: "Content-Type")], ["POST", "application/json"])
    }

    func testGoogleRoadmapSessionSpecifiesMapTypeLanguageAndRegion() async throws {
        MapProtocol.configure { request in
            request.url?.path == "/v1/createSession" ? .session(token: "session-one") : .image
        }
        _ = try await makeClient().tileData(for: tile, source: .googleRoadmap)
        let body = try sessionBody()
        XCTAssertEqual([body["mapType"] as? String, body["language"] as? String, body["region"] as? String],
                       ["roadmap", "pt-BR", "BR"])
    }

    func testGoogleHybridAddsRoadmapLayerToSatellite() async throws {
        MapProtocol.configure { request in
            request.url?.path == "/v1/createSession" ? .session(token: "session-one") : .image
        }
        _ = try await makeClient().tileData(for: tile, source: .googleHybrid)
        let body = try sessionBody()
        XCTAssertTrue(body["mapType"] as? String == "satellite"
                      && body["layerTypes"] as? [String] == ["layerRoadmap"] && body["overlay"] as? Bool == false)
    }

    func testGoogleTileIncludesSessionAndKey() async throws {
        MapProtocol.configure { request in
            request.url?.path == "/v1/createSession" ? .session(token: "session-one") : .image
        }
        _ = try await makeClient().tileData(for: tile, source: .googleSatellite)
        let url = try XCTUnwrap(MapProtocol.requests.last?.url)
        XCTAssertEqual(query(url), ["session": "session-one", "key": "test-key"])
    }

    func testGoogleReusesUnexpiredSession() async throws {
        MapProtocol.configure { request in
            request.url?.path == "/v1/createSession" ? .session(token: "session-one") : .image
        }
        let client = makeClient()
        _ = try await client.tileData(for: tile, source: .googleRoadmap)
        _ = try await client.tileData(for: tile, source: .googleRoadmap)
        XCTAssertEqual(MapProtocol.requests.filter { $0.url?.path == "/v1/createSession" }.count, 1)
    }

    func testGoogleRenewsSessionAfterExpiry() async throws {
        let time = LockedValue(Date(timeIntervalSince1970: 100))
        MapProtocol.configure { request in
            request.url?.path == "/v1/createSession"
                ? .session(token: "session-one", expiry: Int(time.value.timeIntervalSince1970) + 100)
                : .image
        }
        let client = makeClient(clock: { time.value })
        _ = try await client.tileData(for: tile, source: .googleRoadmap)
        time.value = Date(timeIntervalSince1970: 201)
        _ = try await client.tileData(for: tile, source: .googleRoadmap)
        XCTAssertEqual(MapProtocol.requests.filter { $0.url?.path == "/v1/createSession" }.count, 2)
    }

    func testGoogleRecreatesSessionWhenKeyChanges() async throws {
        let key = LockedValue("first-key")
        MapProtocol.configure { request in
            request.url?.path == "/v1/createSession" ? .session(token: "session-one") : .image
        }
        let client = makeClient(credentialReader: { key.value })
        _ = try await client.tileData(for: tile, source: .googleRoadmap)
        key.value = "second-key"
        _ = try await client.tileData(for: tile, source: .googleRoadmap)
        let keys = MapProtocol.requests.filter { $0.url?.path == "/v1/createSession" }.compactMap { $0.url }.map { query($0)["key"] }
        XCTAssertEqual(keys, ["first-key", "second-key"])
    }

    func testGoogleRetriesExpiredSessionResponseOnce() async throws {
        let expired = LockedValue(true)
        MapProtocol.configure { request in
            if request.url?.path == "/v1/createSession" { return .session(token: "session-one") }
            if expired.value { expired.value = false; return MapResponse(status: 400) }
            return .image
        }
        _ = try await makeClient().tileData(for: tile, source: .googleRoadmap)
        XCTAssertEqual(MapProtocol.requests.filter { $0.url?.path == "/v1/createSession" }.count, 2)
    }

    func testGoogleAuthenticationErrorDoesNotExposeKeyOrURL() async {
        MapProtocol.configure { _ in MapResponse(status: 403, body: Data("secret-key request URL".utf8)) }
        do {
            _ = try await makeClient(key: "secret-key").tileData(for: tile, source: .googleRoadmap)
            XCTFail("The client accepted an authentication failure.")
        } catch { XCTAssertEqual(error.localizedDescription, MapTileError.authentication.localizedDescription) }
    }

    func testNetworkErrorDoesNotExposeRequestURL() async {
        MapProtocol.configure { _ in throw URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "secret-key"]) }
        do {
            _ = try await makeClient().tileData(for: tile, source: .openStreetMap)
            XCTFail("The client accepted a network failure.")
        } catch { XCTAssertEqual(error as? MapTileError, .network) }
    }

    func testRateLimitHasAStableError() async {
        MapProtocol.configure { _ in MapResponse(status: 429) }
        do {
            _ = try await makeClient().tileData(for: tile, source: .openStreetMap)
            XCTFail("The client accepted a rate limit response.")
        } catch { XCTAssertEqual(error as? MapTileError, .rateLimited) }
    }

    func testRejectsNonImageTileResponse() async {
        MapProtocol.configure { _ in MapResponse(status: 200, mime: "application/json", body: Data("{}".utf8)) }
        do {
            _ = try await makeClient().tileData(for: tile, source: .openStreetMap)
            XCTFail("The client accepted a non-image response.")
        } catch { XCTAssertEqual(error as? MapTileError, .invalidResponse) }
    }

    func testGoogleViewportUsesOfficialMetadataEndpoint() async throws {
        MapProtocol.configure { request in
            request.url?.path == "/v1/createSession" ? .session(token: "session-one") : .viewport
        }
        _ = try await makeClient().attribution(for: viewport, source: .googleRoadmap)
        XCTAssertEqual(MapProtocol.requests.last?.url?.path, "/tile/v1/viewport")
    }

    func testGooglePreservesViewportCopyrightText() async throws {
        MapProtocol.configure { request in
            request.url?.path == "/v1/createSession" ? .session(token: "session-one") : .viewport
        }
        let attribution = try await makeClient().attribution(for: viewport, source: .googleRoadmap)
        XCTAssertEqual(attribution.text, "Map data © Google, Test imagery provider")
    }

    func testGoogleViewportReportsAvailableZoom() async throws {
        MapProtocol.configure { request in
            request.url?.path == "/v1/createSession" ? .session(token: "session-one") : .viewport
        }
        let attribution = try await makeClient().attribution(for: viewport, source: .googleSatellite)
        XCTAssertEqual(attribution.maximumZoom, 19)
    }

    func testGoogleViewportPreservesAntimeridianBounds() async throws {
        MapProtocol.configure { request in
            request.url?.path == "/v1/createSession" ? .session(token: "session-one") : .viewport
        }
        _ = try await makeClient().attribution(for: MapViewport(zoom: 3, north: 10, south: -10, east: -170, west: 170), source: .googleSatellite)
        let url = try XCTUnwrap(MapProtocol.requests.last?.url)
        XCTAssertEqual([query(url)["east"], query(url)["west"]], ["-170.0", "170.0"])
    }

    private func makeClient(key: String? = "test-key", clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 100) },
                            credentialReader: (@Sendable () throws -> String?)? = nil) -> MapTileClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MapProtocol.self]
        return MapTileClient(session: URLSession(configuration: configuration),
                             credentialReader: credentialReader ?? { key }, clock: clock, language: "pt-BR", region: "BR")
    }

    private func sessionBody() throws -> [String: Any] {
        let request = try XCTUnwrap(MapProtocol.requests.first)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name, $0) } })
    }
}

private struct MapResponse {
    var status: Int
    var mime = "application/json"
    var body = Data()

    static var image: MapResponse { MapResponse(status: 200, mime: "image/png", body: Data([137, 80, 78, 71])) }
    static var viewport: MapResponse {
        MapResponse(status: 200, body: Data("""
        {"copyright":"Map data © Google, Test imagery provider","maxZoomRects":[{"maxZoom":19,"north":90,"south":-90,"east":180,"west":-180}]}
        """.utf8))
    }
    static func session(token: String, expiry: Int = 10000) -> MapResponse {
        MapResponse(status: 200, body: Data("{\"session\":\"\(token)\",\"expiry\":\"\(expiry)\"}".utf8))
    }
}

private final class MapProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: (URLRequest) throws -> MapResponse = { _ in .image }
    private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func configure(_ handler: @escaping (URLRequest) throws -> MapResponse) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.lock.lock()
        Self.recorded.append(captured)
        let handler = Self.handler
        Self.lock.unlock()
        do {
            let result = try handler(captured)
            let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": result.mime, "Cache-Control": "max-age=604800"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowedInMemoryOnly)
            client?.urlProtocol(self, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
