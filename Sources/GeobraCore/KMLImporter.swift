import Foundation

enum KMLImporter {
    static func parse(data: Data, name: String) throws -> GeoFolder {
        let document = XMLDocumentReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = document
        let text = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw GeoImportError.invalidData("KML must not contain a document type or entity declaration.")
        }
        guard parser.parse(), document.failure == nil, let root = document.root,
              root.name == "kml", root.isKML else {
            throw GeoImportError.invalidData(document.failure ?? "The KML document is not valid.")
        }
        let unsupported = ["NetworkLink", "GroundOverlay", "PhotoOverlay", "ScreenOverlay", "Track", "MultiTrack", "Model"]
        guard !root.descendants.contains(where: {
            unsupported.contains($0.name) && ($0.isKML || $0.namespaceURI == "http://www.google.com/kml/ext/2.2")
        }) else {
            throw GeoImportError.invalidData("This KML contains an unsupported link, overlay, track, or model.")
        }
        let context = KMLContext(root: root)
        let containers = root.children.filter { $0.isKML && ["Document", "Folder"].contains($0.name) }
        if containers.count == 1 && root.elements("Placemark").isEmpty {
            return try context.folder(containers[0], fallback: name)
        }
        return try context.folder(root, fallback: name)
    }
}

private final class XMLNode {
    let name: String
    let namespaceURI: String?
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []

    init(name: String, namespaceURI: String?, attributes: [String: String]) {
        self.name = name
        self.namespaceURI = namespaceURI
        self.attributes = attributes
    }

    var isKML: Bool {
        namespaceURI == nil || namespaceURI == "" || [
            "http://www.opengis.net/kml/2.2",
            "http://earth.google.com/kml/2.0",
            "http://earth.google.com/kml/2.1",
            "http://earth.google.com/kml/2.2"
        ].contains(namespaceURI ?? "")
    }

    var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var descendants: [XMLNode] { children + children.flatMap(\.descendants) }
    func elements(_ name: String) -> [XMLNode] { children.filter { $0.isKML && $0.name == name } }
    func element(_ name: String) -> XMLNode? { children.first { $0.isKML && $0.name == name } }
    func value(_ name: String) -> String? { element(name)?.value }
}

private final class XMLDocumentReader: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var failure: String?
    private var stack: [XMLNode] = []
    private var nodeCount = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        nodeCount += 1
        guard stack.count < 128, nodeCount <= 500_000 else {
            failure = "The KML document contains too many nested elements."
            parser.abortParsing()
            return
        }
        let node = XMLNode(name: elementName, namespaceURI: namespaceURI, attributes: attributes)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        rejectEntity(parser)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                publicID: String?, systemID: String?) {
        rejectEntity(parser)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        rejectEntity(parser)
        return nil
    }

    private func rejectEntity(_ parser: XMLParser) {
        failure = "KML must not contain an entity declaration."
        parser.abortParsing()
    }
}

private struct KMLContext {
    private var styles: [String: XMLNode] = [:]
    private var styleMaps: [String: String] = [:]

    init(root: XMLNode) {
        for node in root.descendants {
            guard node.isKML, let id = node.attributes["id"] else { continue }
            if node.name == "Style" { styles[id] = node }
            if node.name == "StyleMap" {
                let normal = node.elements("Pair").first { $0.value("key") == "normal" }
                styleMaps[id] = normal?.value("styleUrl")
            }
        }
    }

    func folder(_ node: XMLNode, fallback: String) throws -> GeoFolder {
        let name = node.value("name").flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        let folders = try node.children.filter { $0.isKML && ["Document", "Folder"].contains($0.name) }
            .map { try folder($0, fallback: "Untitled folder") }
        return GeoFolder(
            id: node.attributes["id"].flatMap(UUID.init(uuidString:)) ?? UUID(),
            name: name,
            isVisible: node.value("visibility") != "0",
            children: folders,
            features: try node.elements("Placemark").map(feature)
        )
    }

    private func feature(_ node: XMLNode) throws -> GeoFeature {
        var properties: [String: JSONValue] = [:]
        if let sourceID = node.attributes["id"] { properties["kml:id"] = .string(sourceID) }
        if let sourceStyle = sourceStyle(for: node) { properties["kml:style"] = sourceStyle }
        for key in ["description", "address", "phoneNumber", "Snippet", "styleUrl"] {
            if let value = node.value(key) { properties[key] = .string(value) }
        }
        for key in ["altitudeMode", "extrude", "tessellate"] {
            let values = node.descendants.filter {
                $0.name == key && ($0.isKML || $0.namespaceURI == "http://www.google.com/kml/ext/2.2")
            }.map { JSONValue.string($0.value) }
            if values.count == 1 { properties["kml:\(key)"] = values[0] }
            if values.count > 1 { properties["kml:\(key)"] = .array(values) }
        }
        if let extendedData = node.element("ExtendedData") {
            for data in extendedData.elements("Data") {
                if let name = data.attributes["name"] {
                    properties[name] = .string(data.value("value") ?? "")
                }
            }
            for schema in extendedData.elements("SchemaData") {
                for data in schema.elements("SimpleData") {
                    if let name = data.attributes["name"] { properties[name] = .string(data.value) }
                }
            }
        }
        let geometries = try node.children.compactMap(geometry)
        return GeoFeature(
            id: node.attributes["id"].flatMap(UUID.init(uuidString:)) ?? UUID(),
            name: node.value("name").flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled feature",
            geometry: combine(geometries),
            properties: properties,
            style: style(for: node),
            isVisible: node.value("visibility") != "0",
            sourceID: node.attributes["id"].map(JSONValue.string)
        )
    }

    private func geometry(_ node: XMLNode) throws -> GeoGeometry? {
        guard node.isKML else { return nil }
        switch node.name {
        case "Point":
            let values = try coordinates(node)
            guard values.count == 1 else { throw invalidCoordinates() }
            return .point(values[0])
        case "LineString", "LinearRing":
            let values = try coordinates(node)
            guard values.count >= 2 else { throw invalidCoordinates() }
            return .lineString(values)
        case "Polygon":
            guard let outer = node.element("outerBoundaryIs")?.element("LinearRing") else {
                throw GeoImportError.invalidData("A KML polygon must contain an outer ring.")
            }
            let inner = node.elements("innerBoundaryIs")
            guard inner.allSatisfy({ $0.element("LinearRing") != nil }) else {
                throw GeoImportError.invalidData("A KML polygon contains an invalid inner ring.")
            }
            let rings = try ([outer] + inner.compactMap { $0.element("LinearRing") }).map { ring in
                let values = try coordinates(ring)
                guard values.count >= 4, values.first == values.last else {
                    throw GeoImportError.invalidData("A KML polygon ring must be closed and contain at least four positions.")
                }
                return values
            }
            return .polygon(rings)
        case "MultiGeometry":
            let geometries = try node.children.compactMap(geometry)
            return combine(geometries) ?? .geometryCollection([])
        default:
            return nil
        }
    }

    private func coordinates(_ node: XMLNode) throws -> [Coordinate] {
        guard node.elements("coordinates").count == 1,
              let text = node.value("coordinates"), !text.isEmpty else { throw invalidCoordinates() }
        return try text.split(whereSeparator: \.isWhitespace).map { position in
            let parts = position.split(separator: ",", omittingEmptySubsequences: false)
            guard (2...3).contains(parts.count),
                  let longitude = Double(parts[0]), let latitude = Double(parts[1]),
                  longitude.isFinite, latitude.isFinite,
                  (-180...180).contains(longitude), (-90...90).contains(latitude) else {
                throw invalidCoordinates()
            }
            var altitude: Double?
            if parts.count == 3 && !parts[2].isEmpty {
                guard let value = Double(parts[2]), value.isFinite else { throw invalidCoordinates() }
                altitude = value
            }
            return Coordinate(longitude: longitude, latitude: latitude, altitude: altitude)
        }
    }

    private func invalidCoordinates() -> GeoImportError {
        .invalidData("The KML geometry contains invalid coordinates.")
    }

    private func combine(_ values: [GeoGeometry]) -> GeoGeometry? {
        if values.isEmpty { return nil }
        if values.count == 1 { return values[0] }
        let points = values.compactMap { value -> Coordinate? in
            if case let .point(coordinate) = value { return coordinate }
            return nil
        }
        if points.count == values.count { return .multiPoint(points) }
        let lines = values.compactMap { value -> [Coordinate]? in
            if case let .lineString(coordinates) = value { return coordinates }
            return nil
        }
        if lines.count == values.count { return .multiLineString(lines) }
        let polygons = values.compactMap { value -> [[Coordinate]]? in
            if case let .polygon(coordinates) = value { return coordinates }
            return nil
        }
        if polygons.count == values.count { return .multiPolygon(polygons) }
        return .geometryCollection(values)
    }

    private func style(for feature: XMLNode) -> FeatureStyle {
        var style = FeatureStyle()
        if let url = feature.value("styleUrl"), let shared = resolveStyle(url, visited: []) {
            applyStyle(shared, to: &style)
        }
        if let inline = feature.element("Style") { applyStyle(inline, to: &style) }
        return style
    }

    private func sourceStyle(for feature: XMLNode) -> JSONValue? {
        var values: [String: JSONValue] = [:]
        if let url = feature.value("styleUrl"), let shared = resolveStyle(url, visited: []) {
            values["shared"] = xmlValue(shared)
        }
        if let inline = feature.element("Style") { values["inline"] = xmlValue(inline) }
        return values.isEmpty ? nil : .object(values)
    }

    private func xmlValue(_ node: XMLNode) -> JSONValue {
        if node.children.isEmpty && node.attributes.isEmpty { return .string(node.value) }
        var values = node.attributes.mapValues(JSONValue.string)
        if !node.value.isEmpty { values["#text"] = .string(node.value) }
        for (name, children) in Dictionary(grouping: node.children, by: \.name) {
            values[name] = children.count == 1 ? xmlValue(children[0]) : .array(children.map(xmlValue))
        }
        return .object(values)
    }

    private func resolveStyle(_ url: String, visited: Set<String>) -> XMLNode? {
        guard url.hasPrefix("#") else { return nil }
        let id = String(url.dropFirst())
        guard !visited.contains(id) else { return nil }
        if let style = styles[id] { return style }
        guard let mapped = styleMaps[id] else { return nil }
        return resolveStyle(mapped, visited: visited.union([id]))
    }

    private func applyStyle(_ node: XMLNode, to style: inout FeatureStyle) {
        let line = node.element("LineStyle")
        let polygon = node.element("PolyStyle")
        let icon = node.element("IconStyle")
        if let color = polygon?.value("color") ?? line?.value("color") ?? icon?.value("color"),
           color.count == 8, let value = UInt32(color, radix: 16) {
            let red = value & 0xff
            let green = (value >> 8) & 0xff
            let blue = (value >> 16) & 0xff
            style.colorHex = String(format: "#%02X%02X%02X", red, green, blue)
            style.fillOpacity = Double((value >> 24) & 0xff) / 255
        }
        if let width = line?.value("width").flatMap(Double.init), width.isFinite, width >= 0 {
            style.lineWidth = width
        }
        if polygon?.value("fill") == "0" { style.fillOpacity = 0 }
        if polygon?.value("outline") == "0" { style.lineWidth = 0 }
    }
}
