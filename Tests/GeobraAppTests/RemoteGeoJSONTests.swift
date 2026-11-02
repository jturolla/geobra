import Foundation
import GeobraCore
import XCTest
@testable import Geobra

final class RemoteGeoJSONTests: XCTestCase {
    func testImportsGeoJSONAsAnIndependentFolder() async throws {
        let (session, url) = makeSession(stub: StubResponse())

        let folder = try await RemoteGeoJSON.load(from: url, session: session)

        XCTAssertEqual(folder.allFeatures.first?.properties["status"], .string("Draft"))
    }

    func testDoesNotSaveTheSourceAddressOrQuery() async throws {
        let (session, url) = makeSession(stub: StubResponse())
        let folder = try await RemoteGeoJSON.load(from: url, session: session)

        let saved = String(decoding: try JSONEncoder().encode(folder), as: UTF8.self)

        XCTAssertFalse(saved.contains("query-secret"))
    }

    func testRejectsHTTPSource() async throws {
        let url = try XCTUnwrap(URL(string: "http://example.com/data.geojson"))

        let error = await loadError(from: url)

        XCTAssertEqual(error, .invalidURL)
    }

    func testRejectsEmbeddedCredentials() async throws {
        let url = try XCTUnwrap(URL(string: "https://name:password@example.com/data.geojson"))

        let error = await loadError(from: url)

        XCTAssertEqual(error, .invalidURL)
    }

    func testReportsHTTPFailureWithoutAddress() async throws {
        let (session, url) = makeSession(stub: StubResponse(status: 403))

        let error = await loadError(from: url, session: session)

        XCTAssertEqual(error, .httpStatus(403))
    }

    func testRejectsAdvertisedSizeBeforeReading() async throws {
        let stub = StubResponse(headers: ["Content-Type": "application/geo+json", "Content-Length": "1024"])
        let (session, url) = makeSession(stub: stub)

        let error = await loadError(from: url, session: session, maximumSize: 512)

        XCTAssertEqual(error, .tooLarge)
    }

    func testLimitsStreamWithoutContentLength() async throws {
        let (session, url) = makeSession(stub: StubResponse())

        let error = await loadError(from: url, session: session, maximumSize: 8)

        XCTAssertEqual(error, .tooLarge)
    }

    func testRejectsHTMLResponse() async throws {
        let stub = StubResponse(headers: ["Content-Type": "text/html"], body: Data("<html>Sign in</html>".utf8))
        let (session, url) = makeSession(stub: stub)

        let error = await loadError(from: url, session: session)

        XCTAssertEqual(error, .unsupportedResponse)
    }

    func testRejectsInvalidGeoJSON() async throws {
        let (session, url) = makeSession(stub: StubResponse(body: Data("invalid JSON".utf8)))

        let error = await loadError(from: url, session: session)

        XCTAssertEqual(error, .invalidGeoJSON)
    }

    func testSanitizesNetworkErrors() async throws {
        let failure = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://example.com/?token=query-secret"])
        let (session, url) = makeSession(stub: StubResponse(failure: failure))

        let error = await loadError(from: url, session: session)

        XCTAssertEqual(error?.localizedDescription, RemoteGeoJSONError.downloadFailed.localizedDescription)
    }

    func testRequestsDoNotSendAuthorizationOrCookies() async throws {
        let recorder = RequestRecorder()
        let (session, url) = makeSession(stub: StubResponse(), recorder: recorder)
        _ = try await RemoteGeoJSON.load(from: url, session: session)

        let request = try XCTUnwrap(recorder.request)

        XCTAssertEqual([request.value(forHTTPHeaderField: "Authorization"), request.value(forHTTPHeaderField: "Cookie")], [nil, nil])
    }

    func testRejectsHTTPSDowngradeRedirect() throws {
        let original = try XCTUnwrap(URL(string: "https://example.com/data.geojson"))
        let destination = try XCTUnwrap(URL(string: "http://example.com/data.geojson"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        var redirected: URLRequest?

        RemoteGeoJSONSessionDelegate().urlSession(
            session, task: session.dataTask(with: original), willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: destination), completionHandler: { redirected = $0 }
        )

        XCTAssertNil(redirected)
    }

    func testRedirectRemovesAuthorization() throws {
        let original = try XCTUnwrap(URL(string: "https://example.com/data.geojson"))
        let destination = try XCTUnwrap(URL(string: "https://other.example.com/data.geojson"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        var request = URLRequest(url: destination)
        request.setValue("example-token", forHTTPHeaderField: "Authorization")
        var redirected: URLRequest?

        RemoteGeoJSONSessionDelegate().urlSession(
            session, task: session.dataTask(with: original), willPerformHTTPRedirection: response,
            newRequest: request, completionHandler: { redirected = $0 }
        )

        XCTAssertNil(redirected?.value(forHTTPHeaderField: "Authorization"))
    }

    private func loadError(
        from url: URL,
        session: URLSession = RemoteGeoJSON.defaultSession,
        maximumSize: Int = RemoteGeoJSON.maximumSize
    ) async -> RemoteGeoJSONError? {
        do {
            _ = try await RemoteGeoJSON.load(from: url, session: session, maximumSize: maximumSize)
            return nil
        } catch {
            return error as? RemoteGeoJSONError
        }
    }

    private func makeSession(stub: StubResponse, recorder: RequestRecorder? = nil) -> (URLSession, URL) {
        let host = "geobra-\(UUID().uuidString.lowercased()).test"
        let url = URL(string: "https://\(host)/data.geojson?token=query-secret")!
        RemoteGeoJSONURLProtocol.register(host: host) { request in
            recorder?.record(request)
            return stub
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteGeoJSONURLProtocol.self]
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        addTeardownBlock {
            session.invalidateAndCancel()
            RemoteGeoJSONURLProtocol.remove(host: host)
        }
        return (session, url)
    }
}

private struct StubResponse {
    var status = 200
    var headers = ["Content-Type": "application/geo+json"]
    var body = Data("""
    {"type":"Feature","id":"source-1","geometry":{"type":"Point","coordinates":[-43.2,-22.9]},"properties":{"status":"Draft"}}
    """.utf8)
    var failure: Error?
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: URLRequest?

    var request: URLRequest? { lock.withLock { recorded } }

    func record(_ request: URLRequest) {
        lock.withLock { recorded = request }
    }
}

private final class RemoteGeoJSONURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) -> StubResponse] = [:]

    static func register(host: String, handler: @escaping (URLRequest) -> StubResponse) {
        lock.withLock { handlers[host] = handler }
    }

    static func remove(host: String) {
        _ = lock.withLock { handlers.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { handlers[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let handler = Self.lock.withLock({ Self.handlers[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = handler(request)
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: stub.body.count, by: 7) {
            client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<min(offset + 7, stub.body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
