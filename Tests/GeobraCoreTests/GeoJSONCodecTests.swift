import Foundation
import XCTest
@testable import GeobraCore

final class GeoJSONCodecTests: XCTestCase {
    func testImportsBareGeometry() throws {
        let folder = try decode(#"{"type":"Point","coordinates":[-46.63,-23.55,745]}"#)
        XCTAssertEqual(folder.features.first?.geometry, .point(Coordinate(longitude: -46.63, latitude: -23.55, altitude: 745)))
    }

    func testImportsFeatureCollectionWithNullGeometry() throws {
        let folder = try decode(#"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":null,"properties":null}]}"#)
        XCTAssertEqual(folder.features.count, 1)
    }

    func testPreservesNestedProperties() throws {
        let folder = try decode(#"{"type":"Feature","geometry":null,"properties":{"name":"Park","measurements":{"area":12.5,"surveyed":true,"notes":["a",null]}}}"#)
        XCTAssertEqual(folder.features.first?.properties["measurements"], .object([
            "area": .number(12.5), "surveyed": .bool(true), "notes": .array([.string("a"), .null])
        ]))
    }

    func testPreservesNumericSourceID() throws {
        let folder = try decode(#"{"type":"Feature","id":42,"geometry":null,"properties":{}}"#)
        let data = try GeoJSONCodec.encode(folder: folder)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try XCTUnwrap(json["features"] as? [[String: Any]])
        XCTAssertEqual(features.first?["id"] as? Int, 42)
    }

    func testPreservesIntegerIDBeyondDoublePrecision() throws {
        let folder = try decode(#"{"type":"Feature","id":9007199254740993,"geometry":null,"properties":{}}"#)
        let data = try GeoJSONCodec.encode(folder: folder)
        XCTAssertEqual(try GeoJSONCodec.decode(data: data, name: "Test").features.first?.sourceID, .integer(9_007_199_254_740_993))
    }

    func testPreservesIntegerPropertyBeyondDoublePrecision() throws {
        let folder = try decode(#"{"type":"Feature","geometry":null,"properties":{"parcel":9007199254740993}}"#)
        let data = try GeoJSONCodec.encode(folder: folder)
        XCTAssertEqual(try GeoJSONCodec.decode(data: data, name: "Test").features.first?.properties["parcel"], .integer(9_007_199_254_740_993))
    }

    func testPreservesMaximumUnsignedInteger() throws {
        let folder = try decode(#"{"type":"Feature","geometry":null,"properties":{"parcel":18446744073709551615}}"#)
        let data = try GeoJSONCodec.encode(folder: folder)
        XCTAssertEqual(try GeoJSONCodec.decode(data: data, name: "Test").features.first?.properties["parcel"], .unsignedInteger(UInt64.max))
    }

    func testPreservesHighPrecisionDecimalProperty() throws {
        let folder = try decode(#"{"type":"Feature","geometry":null,"properties":{"area":0.12345678901234567890123456789}}"#)
        let data = try GeoJSONCodec.encode(folder: folder)
        XCTAssertEqual(try GeoJSONCodec.decode(data: data, name: "Test").features.first?.properties["area"],
                       .decimal(try XCTUnwrap(Decimal(string: "0.12345678901234567890123456789"))))
    }

    func testPreservesStringSourceID() throws {
        let folder = try decode(#"{"type":"Feature","id":"survey-5","geometry":null,"properties":{}}"#)
        XCTAssertEqual(folder.features.first?.sourceID, .string("survey-5"))
    }

    func testPreservesEveryGeometryType() throws {
        let point = Coordinate(longitude: 0, latitude: 0)
        let second = Coordinate(longitude: 1, latitude: 0)
        let third = Coordinate(longitude: 1, latitude: 1)
        let ring = [point, second, third, point]
        let geometries: [GeoGeometry] = [
            .point(point), .multiPoint([point, second]), .lineString([point, second]),
            .multiLineString([[point, second], [second, third]]), .polygon([ring, ring]),
            .multiPolygon([[ring], [ring]]), .geometryCollection([.point(point), .polygon([ring])])
        ]
        let data = try JSONEncoder().encode(geometries)
        XCTAssertEqual(try JSONDecoder().decode([GeoGeometry].self, from: data), geometries)
    }

    func testExportPreservesFoldersStylesVisibilityAndIDs() throws {
        let feature = GeoFeature(name: "Park", geometry: .point(Coordinate(longitude: 0, latitude: 0)),
                                 properties: ["name": .string("Park")],
                                 style: FeatureStyle(colorHex: "#FFAABB", fillOpacity: 0.7, lineWidth: 4),
                                 isVisible: false, sourceID: .string("original"))
        let root = GeoFolder(name: "Places", isVisible: false, children: [
            GeoFolder(name: "Empty folder"), GeoFolder(name: "Survey", features: [feature])
        ])
        let data = try GeoJSONCodec.encode(folder: root)
        XCTAssertEqual(try GeoJSONCodec.decode(data: data, name: "Different file name"), root)
    }

    func testExportIncludesNullGeometryMember() throws {
        let data = try GeoJSONCodec.encode(folder: GeoFolder(features: [GeoFeature()]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try XCTUnwrap(json["features"] as? [[String: Any]])
        XCTAssertTrue(features.first?["geometry"] is NSNull)
    }

    func testExportUsesRenamedFeature() throws {
        let folder = GeoFolder(features: [GeoFeature(name: "New name", properties: ["name": .string("Old name")])])
        let data = try GeoJSONCodec.encode(folder: folder)
        XCTAssertEqual(try GeoJSONCodec.decode(data: data, name: "Test").features.first?.name, "New name")
    }

    func testExportPreservesNonStringNameProperty() throws {
        let folder = GeoFolder(features: [GeoFeature(name: "Feature 1", properties: ["name": .number(7)])])
        let data = try GeoJSONCodec.encode(folder: folder)
        XCTAssertEqual(try GeoJSONCodec.decode(data: data, name: "Test").features.first?.properties["name"], .number(7))
    }

    func testRejectsMissingGeometryMember() {
        XCTAssertThrowsError(try decode(#"{"type":"Feature","properties":{}}"#))
    }

    func testRejectsMissingPropertiesMember() {
        XCTAssertThrowsError(try decode(#"{"type":"Feature","geometry":null}"#))
    }

    func testRejectsObjectFeatureID() {
        XCTAssertThrowsError(try decode(#"{"type":"Feature","id":{},"geometry":null,"properties":{}}"#))
    }

    func testRejectsLongitudeOutsideRange() {
        XCTAssertThrowsError(try decode(#"{"type":"Point","coordinates":[181,0]}"#))
    }

    func testRejectsLatitudeOutsideRange() {
        XCTAssertThrowsError(try decode(#"{"type":"Point","coordinates":[0,-91]}"#))
    }

    func testRejectsExtraCoordinateDimensions() {
        XCTAssertThrowsError(try decode(#"{"type":"Point","coordinates":[0,0,0,0]}"#))
    }

    func testRejectsShortPath() {
        XCTAssertThrowsError(try decode(#"{"type":"LineString","coordinates":[[0,0]]}"#))
    }

    func testRejectsOpenPolygonRing() {
        XCTAssertThrowsError(try decode(#"{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,1]]]}"#))
    }

    func testRejectsEmptyPolygon() {
        XCTAssertThrowsError(try decode(#"{"type":"Polygon","coordinates":[]}"#))
    }

    func testRejectsUnsupportedGeometry() {
        XCTAssertThrowsError(try decode(#"{"type":"Circle","coordinates":[0,0]}"#))
    }

    func testRejectsProjectedCRS() {
        XCTAssertThrowsError(try decode(#"{"type":"Point","coordinates":[0,0],"crs":{"type":"name","properties":{"name":"EPSG:3857"}}}"#))
    }

    func testAcceptsLegacyWGS84CRS() throws {
        let folder = try decode(#"{"type":"Point","coordinates":[0,0],"crs":{"type":"name","properties":{"name":"EPSG:4326"}}}"#)
        XCTAssertEqual(folder.featureCount, 1)
    }

    func testRejectsInvalidGeometryOnExport() {
        let folder = GeoFolder(features: [GeoFeature(geometry: .point(Coordinate(longitude: .infinity, latitude: 0)))])
        XCTAssertThrowsError(try GeoJSONCodec.encode(folder: folder))
    }

    func testRejectsDuplicateInternalFeatureIDsOnRestore() throws {
        let feature = GeoFeature(name: "Repeated")
        let data = try GeoJSONCodec.encode(folder: GeoFolder(features: [feature, feature]))
        XCTAssertThrowsError(try GeoJSONCodec.decode(data: data, name: "Test"))
    }

    func testWorkspaceRoundTrip() throws {
        let workspace = GeoWorkspace(folders: [GeoFolder(name: "Work", children: [GeoFolder(name: "Nested")])])
        let data = try JSONEncoder().encode(workspace)
        XCTAssertEqual(try JSONDecoder().decode(GeoWorkspace.self, from: data), workspace)
    }

    private func decode(_ text: String) throws -> GeoFolder {
        try GeoJSONCodec.decode(data: Data(text.utf8), name: "Test")
    }
}
