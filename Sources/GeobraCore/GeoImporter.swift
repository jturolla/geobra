import Foundation

public enum GeoImporter {
    public static let maximumFileSize = 100 * 1024 * 1024

    public static func importFile(at url: URL) throws -> GeoFolder {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw GeoImportError.invalidData("Select a regular KML, KMZ, or GeoJSON file.")
        }
        guard let size = values.fileSize, size <= maximumFileSize else { throw GeoImportError.fileTooLarge }
        let format = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        switch format {
        case "kmz":
            return try KMLImporter.parse(data: KMZReader.kmlData(at: url), name: name)
        case "kml":
            return try KMLImporter.parse(data: boundedData(at: url), name: name)
        case "geojson", "json":
            do {
                return try GeoJSONCodec.decode(data: boundedData(at: url), name: name)
            } catch let error as GeoImportError {
                throw error
            } catch {
                throw GeoImportError.invalidData("The GeoJSON file is invalid. \(error.localizedDescription)")
            }
        default: throw GeoImportError.unsupportedFormat(format.isEmpty ? "without an extension" : format.uppercased())
        }
    }

    private static func boundedData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            guard data.count + chunk.count <= maximumFileSize else { throw GeoImportError.fileTooLarge }
            data.append(chunk)
        }
        return data
    }
}
