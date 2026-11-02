import Foundation

enum KMZReader {
    private static let maximumKMLSize = 64 * 1024 * 1024
    private static let maximumListingSize = 2 * 1024 * 1024

    static func kmlData(at url: URL) throws -> Data {
        let archivePath = url.standardizedFileURL.path
        let listing = try runUnzip(arguments: ["-Z", "-1", archivePath], limit: maximumListingSize)
        guard let text = String(data: listing, encoding: .utf8) else {
            throw GeoImportError.archive("The KMZ archive contains invalid file names.")
        }
        let paths = text.split(whereSeparator: \.isNewline).map(String.init)
        guard paths.count <= 10_000, paths.allSatisfy(isSafePath) else {
            throw GeoImportError.archive("The KMZ archive contains an unsafe path or too many files.")
        }
        let candidates = paths.filter { $0.lowercased().hasSuffix(".kml") }.sorted()
        guard let path = candidates.first(where: { $0.lowercased() == "doc.kml" }) ?? candidates.first else {
            throw GeoImportError.archive("The KMZ archive does not contain a KML document.")
        }
        return try runUnzip(arguments: ["-p", archivePath, path], limit: maximumKMLSize)
    }

    private static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 2_048,
              !path.hasPrefix("/"), !path.hasPrefix("-"),
              !path.contains("\\"), !path.contains(":"),
              !path.contains(where: { "*?[]\0".contains($0) }) else { return false }
        return !path.split(separator: "/").contains("..")
    }

    private static func runUnzip(arguments: [String], limit: Int) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw GeoImportError.archive("The Mac could not start the KMZ archive reader.")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            if process.isRunning { process.terminate() }
        }
        var data = Data()
        do {
            while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                guard data.count + chunk.count <= limit else {
                    process.terminate()
                    output.fileHandleForReading.closeFile()
                    process.waitUntilExit()
                    throw GeoImportError.archive("The KMZ document exceeds the import size limit.")
                }
                data.append(chunk)
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            if let error = error as? GeoImportError { throw error }
            throw GeoImportError.archive("The Mac could not read the KMZ archive.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GeoImportError.archive("The KMZ archive is damaged, encrypted, or cannot be read.")
        }
        return data
    }
}
