import Foundation
import XCTest
@testable import GeobraCore

final class GeoImporterTests: XCTestCase {
    func testImportsGeoJSONFile() throws {
        let url = try temporaryFile(extension: "geojson", data: Data(#"{"type":"Point","coordinates":[1,2]}"#.utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(try GeoImporter.importFile(at: url).featureCount, 1)
    }

    func testImportsCaseInsensitiveExtension() throws {
        let url = try temporaryFile(extension: "GEOJSON", data: Data(#"{"type":"Point","coordinates":[1,2]}"#.utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(try GeoImporter.importFile(at: url).featureCount, 1)
    }

    func testRejectsUnsupportedFileType() throws {
        let url = try temporaryFile(extension: "txt", data: Data())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertThrowsError(try GeoImporter.importFile(at: url))
    }

    func testRejectsDirectory() {
        XCTAssertThrowsError(try GeoImporter.importFile(at: FileManager.default.temporaryDirectory))
    }

    func testRejectsOversizedFileBeforeReading() throws {
        let url = try temporaryFile(extension: "geojson", data: Data())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(GeoImporter.maximumFileSize + 1))
        try handle.close()
        XCTAssertThrowsError(try GeoImporter.importFile(at: url))
    }

    func testImportsAllSampleFormats() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let counts = try ["kml", "kmz", "geojson"].map { format in
            try GeoImporter.importFile(at: root.appendingPathComponent("Samples/sao-paulo.\(format)")).featureCount
        }
        XCTAssertEqual(counts, [3, 3, 3])
    }

    private func temporaryFile(extension fileExtension: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("test.\(fileExtension)")
        try data.write(to: url)
        return url
    }
}
