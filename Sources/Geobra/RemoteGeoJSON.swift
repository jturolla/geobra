import Foundation
import GeobraCore

enum RemoteGeoJSON {
    static let maximumSize = 100 * 1024 * 1024
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    static func load(
        from url: URL,
        session: URLSession = RemoteGeoJSON.defaultSession,
        maximumSize: Int = RemoteGeoJSON.maximumSize
    ) async throws -> GeoFolder {
        try validate(url)
        guard maximumSize > 0 else { throw RemoteGeoJSONError.tooLarge }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("application/geo+json, application/json", forHTTPHeaderField: "Accept")
        request.setValue("Geobra/0.1 (+https://github.com/jturolla/geobra)", forHTTPHeaderField: "User-Agent")

        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RemoteGeoJSONSessionDelegate())
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else {
                throw RemoteGeoJSONError.unsupportedResponse
            }
            if (300..<400).contains(response.statusCode) {
                throw RemoteGeoJSONError.unsafeRedirect
            }
            guard (200..<300).contains(response.statusCode) else {
                throw RemoteGeoJSONError.httpStatus(response.statusCode)
            }
            if let finalURL = response.url { try validate(finalURL) }
            guard response.expectedContentLength <= Int64(maximumSize) else {
                throw RemoteGeoJSONError.tooLarge
            }
            try validateContentType(response.mimeType)

            var data = Data()
            data.reserveCapacity(min(maximumSize, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < maximumSize else { throw RemoteGeoJSONError.tooLarge }
                data.append(byte)
            }
            do {
                return try GeoJSONCodec.decode(data: data, name: "GeoJSON Data Source")
            } catch {
                throw RemoteGeoJSONError.invalidGeoJSON
            }
        } catch let error as RemoteGeoJSONError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw RemoteGeoJSONError.downloadFailed
        }
    }

    static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw RemoteGeoJSONError.invalidURL
        }
    }

    private static func validateContentType(_ mimeType: String?) throws {
        guard let mimeType = mimeType?.lowercased() else { return }
        let documentTypes = ["text/html", "application/xhtml+xml", "text/xml", "application/xml"]
        guard !documentTypes.contains(mimeType),
              !["image/", "audio/", "video/"].contains(where: mimeType.hasPrefix) else {
            throw RemoteGeoJSONError.unsupportedResponse
        }
    }
}

enum RemoteGeoJSONError: Error, LocalizedError, Equatable {
    case invalidURL
    case unsupportedResponse
    case httpStatus(Int)
    case tooLarge
    case invalidGeoJSON
    case downloadFailed
    case unsafeRedirect

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter an HTTPS URL without a user name or password."
        case .unsupportedResponse:
            return "The data source returned a response that is not a GeoJSON document."
        case .httpStatus(let code):
            return "The data source returned HTTP status \(code). Check access to the file."
        case .tooLarge:
            return "The data source exceeds the import size limit."
        case .invalidGeoJSON:
            return "The data source did not return valid GeoJSON."
        case .downloadFailed:
            return "Geobra could not download the data source. Check the URL and connection."
        case .unsafeRedirect:
            return "The data source redirected to an unsupported URL. Use a direct HTTPS URL."
        }
    }
}

final class RemoteGeoJSONSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, (try? RemoteGeoJSON.validate(url)) != nil else {
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.httpShouldHandleCookies = false
        redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        redirected.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
