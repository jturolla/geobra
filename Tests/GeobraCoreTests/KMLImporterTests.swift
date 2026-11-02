import XCTest
@testable import GeobraCore

final class KMLImporterTests: XCTestCase {
    func testPreservesFolderHierarchy() throws {
        let folder = try parse("""
        <Document><name>Survey</name><Folder><name>Sites</name>
        <Placemark><name>A</name><Point><coordinates>-46,-23,12</coordinates></Point></Placemark>
        </Folder></Document>
        """)
        XCTAssertEqual(folder.children.first?.features.first?.name, "A")
    }

    func testPreservesFolderVisibility() throws {
        let folder = try parse("<Document><visibility>0</visibility></Document>")
        XCTAssertFalse(folder.isVisible)
    }

    func testPreservesFeatureVisibility() throws {
        let folder = try parse("<Document><Placemark><visibility>0</visibility></Placemark></Document>")
        XCTAssertEqual(folder.features.first?.isVisible, false)
    }

    func testPreservesPolygonHoles() throws {
        let folder = try parse("""
        <Document><Placemark><Polygon>
        <outerBoundaryIs><LinearRing><coordinates>0,0 4,0 4,4 0,4 0,0</coordinates></LinearRing></outerBoundaryIs>
        <innerBoundaryIs><LinearRing><coordinates>1,1 1,2 2,2 2,1 1,1</coordinates></LinearRing></innerBoundaryIs>
        </Polygon></Placemark></Document>
        """)
        let expected = GeoGeometry.polygon([
            [Coordinate(longitude: 0, latitude: 0), Coordinate(longitude: 4, latitude: 0),
             Coordinate(longitude: 4, latitude: 4), Coordinate(longitude: 0, latitude: 4),
             Coordinate(longitude: 0, latitude: 0)],
            [Coordinate(longitude: 1, latitude: 1), Coordinate(longitude: 1, latitude: 2),
             Coordinate(longitude: 2, latitude: 2), Coordinate(longitude: 2, latitude: 1),
             Coordinate(longitude: 1, latitude: 1)]
        ])
        XCTAssertEqual(folder.features.first?.geometry, expected)
    }

    func testResolvesSharedStyleMap() throws {
        let folder = try parse("""
        <Document>
        <Style id="green"><LineStyle><width>3</width></LineStyle><PolyStyle><color>7f00ff00</color></PolyStyle></Style>
        <StyleMap id="map"><Pair><key>normal</key><styleUrl>#green</styleUrl></Pair></StyleMap>
        <Placemark><styleUrl>#map</styleUrl></Placemark>
        </Document>
        """)
        XCTAssertEqual(folder.features.first?.style,
                       FeatureStyle(colorHex: "#00FF00", fillOpacity: 127.0 / 255, lineWidth: 3))
    }

    func testInlineStyleOverridesSharedStyle() throws {
        let folder = try parse("""
        <Document><Style id="blue"><LineStyle><color>ffff0000</color></LineStyle></Style>
        <Placemark><styleUrl>#blue</styleUrl><Style><PolyStyle><fill>0</fill></PolyStyle></Style></Placemark>
        </Document>
        """)
        XCTAssertEqual(folder.features.first?.style.fillOpacity, 0)
    }

    func testPreservesExtendedData() throws {
        let folder = try parse("""
        <Document><Placemark><ExtendedData>
        <Data name="owner"><value>Ana</value></Data>
        <SchemaData><SimpleData name="area">12</SimpleData></SchemaData>
        </ExtendedData></Placemark></Document>
        """)
        XCTAssertEqual(folder.features.first?.properties, ["owner": .string("Ana"), "area": .string("12")])
    }

    func testPreservesMixedGeometry() throws {
        let folder = try parse("""
        <Document><Placemark><MultiGeometry>
        <Point><coordinates>0,1</coordinates></Point>
        <LineString><coordinates>0,0 1,1</coordinates></LineString>
        </MultiGeometry></Placemark></Document>
        """)
        XCTAssertEqual(folder.features.first?.geometry, .geometryCollection([
            .point(Coordinate(longitude: 0, latitude: 1)),
            .lineString([Coordinate(longitude: 0, latitude: 0), Coordinate(longitude: 1, latitude: 1)])
        ]))
    }

    func testPreservesUUID() throws {
        let id = UUID()
        let folder = try parse("<Document><Placemark id=\"\(id.uuidString)\"/></Document>")
        XCTAssertEqual(folder.features.first?.id, id)
    }

    func testPreservesSeparateLineAndFillColors() throws {
        let folder = try parse("""
        <Document><Placemark><Style>
        <LineStyle><color>ff0000ff</color></LineStyle>
        <PolyStyle><color>7f00ff00</color></PolyStyle>
        </Style></Placemark></Document>
        """)
        XCTAssertEqual(folder.features.first?.properties["kml:style"], .object([
            "inline": .object([
                "LineStyle": .object(["color": .string("ff0000ff")]),
                "PolyStyle": .object(["color": .string("7f00ff00")])
            ])
        ]))
    }

    func testIgnoresForeignPoint() throws {
        let folder = try parse("""
        <Document><Placemark><x:Point xmlns:x="urn:foreign">
        <x:coordinates>1,2</x:coordinates></x:Point></Placemark></Document>
        """)
        XCTAssertNil(folder.features.first?.geometry)
    }

    func testRejectsForeignRoot() {
        let data = Data("<kml xmlns=\"urn:foreign\"><Document/></kml>".utf8)
        XCTAssertThrowsError(try KMLImporter.parse(data: data, name: "Test"))
    }

    func testRejectsOutOfRangeCoordinates() {
        XCTAssertThrowsError(try parse("<Placemark><Point><coordinates>200,0</coordinates></Point></Placemark>"))
    }

    func testRejectsUnclosedRing() {
        XCTAssertThrowsError(try parse("""
        <Placemark><Polygon><outerBoundaryIs><LinearRing>
        <coordinates>0,0 4,0 4,4 0,4</coordinates>
        </LinearRing></outerBoundaryIs></Polygon></Placemark>
        """))
    }

    func testRejectsEntityDeclaration() {
        let data = Data("<!DOCTYPE kml [<!ENTITY x 'expanded'>]><kml><name>&x;</name></kml>".utf8)
        XCTAssertThrowsError(try KMLImporter.parse(data: data, name: "Test"))
    }

    func testRejectsExternalDocumentType() {
        let data = Data("<!DOCTYPE kml SYSTEM 'file:///etc/passwd'><kml/>".utf8)
        XCTAssertThrowsError(try KMLImporter.parse(data: data, name: "Test"))
    }

    func testRejectsUTF16DocumentTypeWithoutBOM() {
        let xml = "<!DOCTYPE kml><kml/>"
        let data = xml.data(using: .utf16LittleEndian)!
        XCTAssertThrowsError(try KMLImporter.parse(data: data, name: "Test"))
    }

    func testRejectsUnsupportedOverlay() {
        XCTAssertThrowsError(try parse("<Document><GroundOverlay><name>Image</name></GroundOverlay></Document>"))
    }

    func testRejectsMalformedXML() {
        XCTAssertThrowsError(try KMLImporter.parse(data: Data("<kml><Document></kml>".utf8), name: "Test"))
    }

    private func parse(_ body: String) throws -> GeoFolder {
        try KMLImporter.parse(data: Data("<kml xmlns=\"http://www.opengis.net/kml/2.2\">\(body)</kml>".utf8), name: "Test")
    }
}
