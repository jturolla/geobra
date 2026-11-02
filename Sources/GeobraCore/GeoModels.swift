import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case decimal(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    private static let maximumExactDoubleInteger: Int64 = 9_007_199_254_740_991

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self),
                value > Self.maximumExactDoubleInteger || value < -Self.maximumExactDoubleInteger {
            self = .integer(value)
        }
        else if let value = try? container.decode(UInt64.self), value > UInt64(Self.maximumExactDoubleInteger) {
            self = .unsignedInteger(value)
        }
        else if let value = try? container.decode(Decimal.self) {
            if let double = try? container.decode(Double.self),
               Decimal(string: String(double), locale: Locale(identifier: "en_US_POSIX")) == value {
                self = .number(double)
            } else {
                self = .decimal(value)
            }
        }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsignedInteger(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var displayText: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value.formatted(.number.precision(.fractionLength(0...8)))
        case .integer(let value): return String(value)
        case .unsignedInteger(let value): return String(value)
        case .decimal(let value): return NSDecimalNumber(decimal: value).stringValue
        case .string(let value): return value
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

public struct Coordinate: Codable, Equatable, Sendable {
    public var longitude: Double
    public var latitude: Double
    public var altitude: Double?

    public init(longitude: Double, latitude: Double, altitude: Double? = nil) {
        self.longitude = longitude
        self.latitude = latitude
        self.altitude = altitude
    }

    public var isValid: Bool {
        longitude.isFinite && latitude.isFinite && (-180...180).contains(longitude)
            && (-90...90).contains(latitude) && (altitude?.isFinite ?? true)
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        longitude = try container.decode(Double.self)
        latitude = try container.decode(Double.self)
        altitude = container.isAtEnd ? nil : try container.decode(Double.self)
        guard container.isAtEnd, isValid else {
            throw GeoImportError.invalidData("A coordinate is invalid. Use longitude, latitude, and an optional altitude.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard isValid else { throw GeoImportError.invalidData("A coordinate is outside the valid range.") }
        var container = encoder.unkeyedContainer()
        try container.encode(longitude)
        try container.encode(latitude)
        if let altitude { try container.encode(altitude) }
    }
}

public indirect enum GeoGeometry: Codable, Equatable, Sendable {
    case point(Coordinate)
    case multiPoint([Coordinate])
    case lineString([Coordinate])
    case multiLineString([[Coordinate]])
    case polygon([[Coordinate]])
    case multiPolygon([[[Coordinate]]])
    case geometryCollection([GeoGeometry])

    public var coordinates: [Coordinate] {
        switch self {
        case .point(let coordinate): return [coordinate]
        case .multiPoint(let coordinates), .lineString(let coordinates): return coordinates
        case .multiLineString(let lines), .polygon(let lines): return lines.flatMap { $0 }
        case .multiPolygon(let polygons): return polygons.flatMap { $0.flatMap { $0 } }
        case .geometryCollection(let geometries): return geometries.flatMap(\.coordinates)
        }
    }

    public var displayName: String {
        switch self {
        case .point: return "Point"
        case .multiPoint: return "Points"
        case .lineString: return "Path"
        case .multiLineString: return "Paths"
        case .polygon: return "Polygon"
        case .multiPolygon: return "Polygons"
        case .geometryCollection: return "Geometry collection"
        }
    }

    public func validate() throws {
        guard coordinates.allSatisfy(\.isValid) else {
            throw GeoImportError.invalidData("A coordinate is outside the valid range.")
        }
        switch self {
        case .point: break
        case .multiPoint(let points):
            guard !points.isEmpty else { throw GeoImportError.invalidData("A MultiPoint has no coordinates.") }
        case .lineString(let line): try Self.validateLine(line)
        case .multiLineString(let lines):
            guard !lines.isEmpty else { throw GeoImportError.invalidData("A MultiLineString has no paths.") }
            try lines.forEach(Self.validateLine)
        case .polygon(let rings): try Self.validatePolygon(rings)
        case .multiPolygon(let polygons):
            guard !polygons.isEmpty else { throw GeoImportError.invalidData("A MultiPolygon has no polygons.") }
            try polygons.forEach(Self.validatePolygon)
        case .geometryCollection(let geometries): try geometries.forEach { try $0.validate() }
        }
    }

    private static func validateLine(_ line: [Coordinate]) throws {
        guard line.count >= 2 else { throw GeoImportError.invalidData("A path needs at least two coordinates.") }
    }

    private static func validatePolygon(_ rings: [[Coordinate]]) throws {
        guard !rings.isEmpty else { throw GeoImportError.invalidData("A polygon has no outer boundary.") }
        for ring in rings {
            guard ring.count >= 4, ring.first == ring.last else {
                throw GeoImportError.invalidData("A polygon boundary needs at least four coordinates and must close.")
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case type, coordinates, geometries }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "Point": self = .point(try container.decode(Coordinate.self, forKey: .coordinates))
        case "MultiPoint": self = .multiPoint(try container.decode([Coordinate].self, forKey: .coordinates))
        case "LineString": self = .lineString(try container.decode([Coordinate].self, forKey: .coordinates))
        case "MultiLineString": self = .multiLineString(try container.decode([[Coordinate]].self, forKey: .coordinates))
        case "Polygon": self = .polygon(try container.decode([[Coordinate]].self, forKey: .coordinates))
        case "MultiPolygon": self = .multiPolygon(try container.decode([[[Coordinate]]].self, forKey: .coordinates))
        case "GeometryCollection": self = .geometryCollection(try container.decode([GeoGeometry].self, forKey: .geometries))
        default: throw GeoImportError.invalidData("The geometry type \(type) is not supported.")
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .point(let value):
            try container.encode("Point", forKey: .type)
            try container.encode(value, forKey: .coordinates)
        case .multiPoint(let value):
            try container.encode("MultiPoint", forKey: .type)
            try container.encode(value, forKey: .coordinates)
        case .lineString(let value):
            try container.encode("LineString", forKey: .type)
            try container.encode(value, forKey: .coordinates)
        case .multiLineString(let value):
            try container.encode("MultiLineString", forKey: .type)
            try container.encode(value, forKey: .coordinates)
        case .polygon(let value):
            try container.encode("Polygon", forKey: .type)
            try container.encode(value, forKey: .coordinates)
        case .multiPolygon(let value):
            try container.encode("MultiPolygon", forKey: .type)
            try container.encode(value, forKey: .coordinates)
        case .geometryCollection(let value):
            try container.encode("GeometryCollection", forKey: .type)
            try container.encode(value, forKey: .geometries)
        }
    }
}

public struct FeatureStyle: Codable, Equatable, Sendable {
    public var colorHex: String
    public var fillOpacity: Double
    public var lineWidth: Double

    public init(colorHex: String = "#75D9B1", fillOpacity: Double = 0.24, lineWidth: Double = 2) {
        self.colorHex = colorHex
        self.fillOpacity = fillOpacity
        self.lineWidth = lineWidth
    }
}

public struct GeoFeature: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var geometry: GeoGeometry?
    public var properties: [String: JSONValue]
    public var style: FeatureStyle
    public var isVisible: Bool
    public var sourceID: JSONValue?

    public init(id: UUID = UUID(), name: String = "Untitled feature", geometry: GeoGeometry? = nil,
                properties: [String: JSONValue] = [:], style: FeatureStyle = FeatureStyle(),
                isVisible: Bool = true, sourceID: JSONValue? = nil) {
        self.id = id
        self.name = name
        self.geometry = geometry
        self.properties = properties
        self.style = style
        self.isVisible = isVisible
        self.sourceID = sourceID
    }
}

public struct GeoFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isVisible: Bool
    public var children: [GeoFolder]
    public var features: [GeoFeature]

    public init(id: UUID = UUID(), name: String = "Untitled folder", isVisible: Bool = true,
                children: [GeoFolder] = [], features: [GeoFeature] = []) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.children = children
        self.features = features
    }

    public var allFeatures: [GeoFeature] { features + children.flatMap(\.allFeatures) }
    public var featureCount: Int { features.count + children.reduce(0) { $0 + $1.featureCount } }
}

public struct GeoWorkspace: Codable, Equatable, Sendable {
    public var folders: [GeoFolder]

    public init(folders: [GeoFolder] = []) { self.folders = folders }
}

public enum GeoImportError: Error, LocalizedError, Sendable {
    case unsupportedFormat(String)
    case invalidData(String)
    case fileTooLarge
    case archive(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): return "The file format \(format) is not supported. Select KML, KMZ, or GeoJSON."
        case .invalidData(let message), .archive(let message): return message
        case .fileTooLarge: return "The file exceeds the 100 MB import limit. Select a smaller file."
        }
    }
}
