import XCTest
@testable import GeobraCore

final class MapTileTests: XCTestCase {
    func testWorldTileLongitudeBounds() {
        let bounds = MapTile(zoom: 0, x: 0, y: 0).bounds
        XCTAssertEqual([bounds.west, bounds.east], [-180, 180])
    }

    func testWorldTileLatitudeBounds() {
        let bounds = MapTile(zoom: 0, x: 0, y: 0).bounds
        XCTAssertEqual(bounds.north, WebMercator.maximumLatitude, accuracy: 0.000000001)
    }

    func testWorldTileSouthernLatitude() {
        XCTAssertEqual(MapTile(zoom: 0, x: 0, y: 0).bounds.south, -WebMercator.maximumLatitude, accuracy: 0.000000001)
    }

    func testEquatorAndPrimeMeridianMeetAtWorldCenter() {
        XCTAssertEqual(WebMercator.tileCoordinate(longitude: 0, latitude: 0, zoom: 1), MapTileCoordinate(x: 1, y: 1))
    }

    func testNorthernWesternTileHasExpectedBounds() {
        let bounds = MapTile(zoom: 1, x: 0, y: 0).bounds
        XCTAssertEqual([bounds.west, bounds.east, bounds.south], [-180, 0, 0])
    }

    func testAntimeridianUsesTheFirstTileColumn() {
        XCTAssertEqual(WebMercator.tile(longitude: 180, latitude: 0, zoom: 3).x, 0)
    }

    func testLongitudeWrapsAcrossMultipleWorlds() {
        XCTAssertEqual(WebMercator.tile(longitude: 540, latitude: 0, zoom: 4), WebMercator.tile(longitude: -180, latitude: 0, zoom: 4))
    }

    func testNegativeLongitudeWrapsAcrossMultipleWorlds() {
        XCTAssertEqual(WebMercator.tile(longitude: -541, latitude: 0, zoom: 4), WebMercator.tile(longitude: 179, latitude: 0, zoom: 4))
    }

    func testNorthPoleClampsToFirstTileRow() {
        XCTAssertEqual(WebMercator.tile(longitude: 0, latitude: 90, zoom: 8).y, 0)
    }

    func testSouthPoleClampsToLastTileRow() {
        XCTAssertEqual(WebMercator.tile(longitude: 0, latitude: -90, zoom: 8).y, 255)
    }

    func testHighZoomLongitudeRoundTrip() {
        let position = WebMercator.tileCoordinate(longitude: -43.2096, latitude: -22.9035, zoom: 22)
        XCTAssertEqual(WebMercator.coordinate(x: position.x, y: position.y, zoom: 22).longitude, -43.2096, accuracy: 0.000000001)
    }

    func testHighZoomLatitudeRoundTrip() {
        let position = WebMercator.tileCoordinate(longitude: -43.2096, latitude: -22.9035, zoom: 22)
        XCTAssertEqual(WebMercator.coordinate(x: position.x, y: position.y, zoom: 22).latitude, -22.9035, accuracy: 0.000000001)
    }

    func testMaximumZoomTileRemainsValid() {
        XCTAssertTrue(MapTile(zoom: 22, x: 4_194_303, y: 4_194_303).isValid)
    }

    func testNegativeZoomIsInvalid() {
        XCTAssertFalse(MapTile(zoom: -1, x: 0, y: 0).isValid)
    }

    func testExcessiveZoomIsInvalid() {
        XCTAssertFalse(MapTile(zoom: 23, x: 0, y: 0).isValid)
    }

    func testNegativeColumnIsInvalid() {
        XCTAssertFalse(MapTile(zoom: 3, x: -1, y: 0).isValid)
    }

    func testColumnOutsideTheWorldIsInvalid() {
        XCTAssertFalse(MapTile(zoom: 3, x: 8, y: 0).isValid)
    }

    func testRowOutsideTheWorldIsInvalid() {
        XCTAssertFalse(MapTile(zoom: 3, x: 0, y: 8).isValid)
    }

    func testExtremeInvalidBoundsRemainFinite() {
        let bounds = MapTile(zoom: Int.max, x: Int.max, y: Int.min).bounds
        XCTAssertTrue([bounds.west, bounds.east, bounds.north, bounds.south].allSatisfy(\.isFinite))
    }

    func testNonFiniteCoordinatesProduceAValidTile() {
        XCTAssertTrue(WebMercator.tile(longitude: .infinity, latitude: .nan, zoom: 5).isValid)
    }

    func testViewportCanCrossTheAntimeridian() {
        XCTAssertTrue(MapViewport(zoom: 4, north: 20, south: -20, east: -170, west: 170).isValid)
    }

    func testViewportRejectsInvertedLatitudeBounds() {
        XCTAssertFalse(MapViewport(zoom: 4, north: -20, south: 20, east: 10, west: -10).isValid)
    }

    func testViewportRejectsNonFiniteCoordinates() {
        XCTAssertFalse(MapViewport(zoom: 4, north: 20, south: -20, east: .nan, west: 10).isValid)
    }
}
