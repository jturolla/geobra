import GeobraCore
import XCTest
@testable import Geobra

final class GlobeLineClipTests: XCTestCase {
    func testTrimsSegmentToViewport() {
        let viewport = GlobeLineClip(reference: 0, west: -1, east: 1, north: 1, south: -1)

        let clipped = viewport.clip(
            Coordinate(longitude: -2, latitude: -2),
            Coordinate(longitude: 2, latitude: 2)
        )

        XCTAssertEqual(clipped, [
            Coordinate(longitude: -1, latitude: -1),
            Coordinate(longitude: 1, latitude: 1)
        ])
    }

    func testRejectsSegmentOutsideViewport() {
        let viewport = GlobeLineClip(reference: 0, west: -1, east: 1, north: 1, south: -1)

        let clipped = viewport.clip(
            Coordinate(longitude: -3, latitude: 2),
            Coordinate(longitude: 3, latitude: 2)
        )

        XCTAssertNil(clipped)
    }

    func testClipsAntimeridianCrossingInContinuousLongitudeSpace() {
        let viewport = GlobeLineClip(reference: 179, west: 178, east: 182, north: 1, south: -1)

        let clipped = viewport.clip(
            Coordinate(longitude: 177, latitude: 0),
            Coordinate(longitude: -177, latitude: 0)
        )

        XCTAssertEqual(clipped, [
            Coordinate(longitude: 178, latitude: 0),
            Coordinate(longitude: 182, latitude: 0)
        ])
    }
}
