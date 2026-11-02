import XCTest
@testable import GeobraCore

final class KMZReaderTests: XCTestCase {
    func testReadsCompressedKML() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("<kml><Document><name>Archive</name></Document></kml>".utf8)
        try data.write(to: directory.appendingPathComponent("doc.kml"))
        let archive = directory.appendingPathComponent("test.kmz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", archive.path, "doc.kml"]
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(try KMZReader.kmlData(at: archive), data)
    }

    func testPrefersRootDocument() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try writeArchive([
            ("a.kml", Data("other".utf8)),
            ("doc.kml", Data("preferred".utf8))
        ], in: directory)
        XCTAssertEqual(try KMZReader.kmlData(at: archive), Data("preferred".utf8))
    }

    func testReadsNestedKML() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try writeArchive([("folder/map.kml", Data("nested".utf8))], in: directory)
        XCTAssertEqual(try KMZReader.kmlData(at: archive), Data("nested".utf8))
    }

    func testRejectsTraversalPath() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try writeArchive([("../doc.kml", Data("unsafe".utf8))], in: directory)
        XCTAssertThrowsError(try KMZReader.kmlData(at: archive))
    }

    func testRejectsWildcardPath() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try writeArchive([("*.kml", Data("unsafe".utf8))], in: directory)
        XCTAssertThrowsError(try KMZReader.kmlData(at: archive))
    }

    func testRejectsArchiveWithoutKML() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try writeArchive([("image.png", Data([0, 1, 2]))], in: directory)
        XCTAssertThrowsError(try KMZReader.kmlData(at: archive))
    }

    func testRejectsDamagedArchive() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("bad.kmz")
        try Data("not a ZIP archive".utf8).write(to: archive)
        XCTAssertThrowsError(try KMZReader.kmlData(at: archive))
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeArchive(_ entries: [(String, Data)], in directory: URL) throws -> URL {
        var archive = Data()
        var central = Data()
        for (name, contents) in entries {
            let filename = Data(name.utf8)
            let offset = UInt32(archive.count)
            let crc = checksum(contents)
            archive.appendLE(UInt32(0x04034b50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(crc)
            archive.appendLE(UInt32(contents.count))
            archive.appendLE(UInt32(contents.count))
            archive.appendLE(UInt16(filename.count))
            archive.appendLE(UInt16(0))
            archive.append(filename)
            archive.append(contents)
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(crc)
            central.appendLE(UInt32(contents.count))
            central.appendLE(UInt32(contents.count))
            central.appendLE(UInt16(filename.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(offset)
            central.append(filename)
        }
        let offset = UInt32(archive.count)
        archive.append(central)
        archive.appendLE(UInt32(0x06054b50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(central.count))
        archive.appendLE(offset)
        archive.appendLE(UInt16(0))
        let url = directory.appendingPathComponent("test.kmz")
        try archive.write(to: url)
        return url
    }

    private func checksum(_ data: Data) -> UInt32 {
        var result: UInt32 = 0xffff_ffff
        for byte in data {
            result ^= UInt32(byte)
            for _ in 0..<8 {
                result = (result >> 1) ^ ((result & 1) == 1 ? 0xedb8_8320 : 0)
            }
        }
        return result ^ 0xffff_ffff
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
