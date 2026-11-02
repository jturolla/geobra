import Foundation

public enum GeoJSONCodec {
    public static func decode(data: Data, name: String) throws -> GeoFolder {
        let decoder = JSONDecoder()
        let header = try decoder.decode(DocumentHeader.self, from: data)
        try header.validateCRS()
        switch header.type {
        case "FeatureCollection":
            let collection = try decoder.decode(FeatureCollection.self, from: data)
            let features = try collection.features.enumerated().map { try $0.element.feature(index: $0.offset) }
            if let metadata = collection.geobra, metadata.schemaVersion == 1 {
                return try metadata.folder.restore(features: features)
            }
            return GeoFolder(name: collection.name ?? name, features: features)
        case "Feature":
            let feature = try decoder.decode(FeatureDocument.self, from: data).feature(index: 0)
            return GeoFolder(name: name, features: [feature])
        default:
            let geometry = try decoder.decode(GeoGeometry.self, from: data)
            return GeoFolder(name: name, features: [GeoFeature(name: name, geometry: geometry)])
        }
    }

    public static func encode(folder: GeoFolder) throws -> Data {
        let collection = FeatureCollection(
            name: folder.name,
            features: folder.allFeatures.map(FeatureDocument.init),
            geobra: CollectionMetadata(schemaVersion: 1, folder: FolderMetadata(folder))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(collection)
    }
}

private struct DocumentHeader: Decodable {
    let type: String
    let crs: JSONValue?

    func validateCRS() throws {
        guard let crs, crs != .null else { return }
        guard case .object(let definition) = crs,
              case .object(let properties) = definition["properties"],
              case .string(let name) = properties["name"],
              ["urn:ogc:def:crs:OGC:1.3:CRS84", "EPSG:4326", "urn:ogc:def:crs:EPSG::4326"].contains(name) else {
            throw GeoImportError.invalidData("Convert the GeoJSON coordinates to WGS 84 before import.")
        }
    }
}

private struct FeatureCollection: Codable {
    var type = "FeatureCollection"
    var name: String?
    var features: [FeatureDocument]
    var geobra: CollectionMetadata?
}

private struct FeatureDocument: Codable {
    var type: String
    var id: JSONValue?
    var geometry: GeoGeometry?
    var properties: [String: JSONValue]?
    var geobra: FeatureMetadata?

    private enum CodingKeys: String, CodingKey { case type, id, geometry, properties, geobra }

    init(_ feature: GeoFeature) {
        type = "Feature"
        id = feature.sourceID ?? .string(feature.id.uuidString)
        geometry = feature.geometry
        properties = feature.properties
        if case .string = properties?["name"] {
            properties?["name"] = .string(feature.name)
        } else if properties?["name"] == nil {
            properties?["name"] = .string(feature.name)
        }
        geobra = FeatureMetadata(id: feature.id, name: feature.name, style: feature.style, isVisible: feature.isVisible)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        guard type == "Feature", container.contains(.geometry), container.contains(.properties) else {
            throw GeoImportError.invalidData("Each GeoJSON feature needs a type, geometry, and properties member.")
        }
        id = try container.decodeIfPresent(JSONValue.self, forKey: .id)
        if let id {
            switch id {
            case .number, .integer, .unsignedInteger, .decimal, .string: break
            default: throw GeoImportError.invalidData("A GeoJSON feature ID must be a number or a string.")
            }
        }
        geometry = try container.decodeIfPresent(GeoGeometry.self, forKey: .geometry)
        properties = try container.decodeIfPresent([String: JSONValue].self, forKey: .properties)
        geobra = try container.decodeIfPresent(FeatureMetadata.self, forKey: .geobra)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(geometry, forKey: .geometry)
        try container.encode(properties, forKey: .properties)
        try container.encodeIfPresent(geobra, forKey: .geobra)
    }

    func feature(index: Int) throws -> GeoFeature {
        let properties = properties ?? [:]
        let name = geobra?.name ?? string(properties["name"]) ?? string(properties["title"]) ?? "Feature \(index + 1)"
        let sourceUUID = string(id).flatMap(UUID.init(uuidString:))
        return GeoFeature(
            id: geobra?.id ?? sourceUUID ?? UUID(),
            name: name,
            geometry: geometry,
            properties: properties,
            style: geobra?.style ?? FeatureStyle(),
            isVisible: geobra?.isVisible ?? true,
            sourceID: id
        )
    }

    private func string(_ value: JSONValue?) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }
}

private struct FeatureMetadata: Codable {
    var id: UUID
    var name: String
    var style: FeatureStyle
    var isVisible: Bool
}

private struct CollectionMetadata: Codable {
    var schemaVersion: Int
    var folder: FolderMetadata
}

private struct FolderMetadata: Codable {
    var id: UUID
    var name: String
    var isVisible: Bool
    var featureIDs: [UUID]
    var children: [FolderMetadata]

    init(_ folder: GeoFolder) {
        id = folder.id
        name = folder.name
        isVisible = folder.isVisible
        featureIDs = folder.features.map(\.id)
        children = folder.children.map(FolderMetadata.init)
    }

    func restore(features: [GeoFeature]) throws -> GeoFolder {
        var featuresByID: [UUID: GeoFeature] = [:]
        for feature in features {
            guard featuresByID.updateValue(feature, forKey: feature.id) == nil else {
                throw GeoImportError.invalidData("The GeoJSON file contains duplicate Geobra feature IDs.")
            }
        }
        var folderIDs = Set<UUID>()
        let folder = try restore(featuresByID: &featuresByID, folderIDs: &folderIDs)
        guard featuresByID.isEmpty else {
            throw GeoImportError.invalidData("The Geobra folder data does not include every feature.")
        }
        return folder
    }

    private func restore(featuresByID: inout [UUID: GeoFeature], folderIDs: inout Set<UUID>) throws -> GeoFolder {
        guard folderIDs.insert(id).inserted else {
            throw GeoImportError.invalidData("The GeoJSON file contains duplicate Geobra folder IDs.")
        }
        var features: [GeoFeature] = []
        for featureID in featureIDs {
            guard let feature = featuresByID.removeValue(forKey: featureID) else {
                throw GeoImportError.invalidData("The Geobra folder data refers to a missing or repeated feature.")
            }
            features.append(feature)
        }
        var folders: [GeoFolder] = []
        for child in children {
            folders.append(try child.restore(featuresByID: &featuresByID, folderIDs: &folderIDs))
        }
        return GeoFolder(id: id, name: name, isVisible: isVisible, children: folders, features: features)
    }
}
