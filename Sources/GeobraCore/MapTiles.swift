import Foundation

public struct MapTile: Hashable, Sendable {
    public let zoom: Int
    public let x: Int
    public let y: Int

    public init(zoom: Int, x: Int, y: Int) {
        self.zoom = zoom
        self.x = x
        self.y = y
    }

    public var isValid: Bool {
        guard WebMercator.zoomRange.contains(zoom) else { return false }
        let count = 1 << zoom
        return (0..<count).contains(x) && (0..<count).contains(y)
    }

    public var bounds: TileBounds {
        let safeZoom = WebMercator.clampedZoom(zoom)
        let count = 1 << safeZoom
        let column = min(count - 1, max(0, x))
        let row = min(count - 1, max(0, y))
        let northwest = WebMercator.coordinate(x: Double(column), y: Double(row), zoom: safeZoom)
        let southeast = WebMercator.coordinate(x: Double(column + 1), y: Double(row + 1), zoom: safeZoom)
        return TileBounds(
            west: northwest.longitude, east: southeast.longitude,
            north: northwest.latitude, south: southeast.latitude
        )
    }
}

public struct TileBounds: Equatable, Sendable {
    public let west: Double
    public let east: Double
    public let north: Double
    public let south: Double

    public init(west: Double, east: Double, north: Double, south: Double) {
        self.west = west
        self.east = east
        self.north = north
        self.south = south
    }
}

public struct MapViewport: Equatable, Sendable {
    public let zoom: Int
    public let north: Double
    public let south: Double
    public let east: Double
    public let west: Double

    public init(zoom: Int, north: Double, south: Double, east: Double, west: Double) {
        self.zoom = zoom
        self.north = north
        self.south = south
        self.east = east
        self.west = west
    }

    public var isValid: Bool {
        WebMercator.zoomRange.contains(zoom)
            && [north, south, east, west].allSatisfy(\.isFinite)
            && (-90...90).contains(south) && (-90...90).contains(north)
            && (-180...180).contains(west) && (-180...180).contains(east)
            && north >= south
    }
}

public struct MapTileCoordinate: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum WebMercator {
    public static let maximumLatitude = 85.0511287798066
    public static let zoomRange = 0...22

    public static func tileCoordinate(longitude: Double, latitude: Double, zoom: Int) -> MapTileCoordinate {
        let scale = Double(1 << clampedZoom(zoom))
        let longitude = normalizedLongitude(longitude)
        let latitude = min(maximumLatitude, max(-maximumLatitude, latitude.isFinite ? latitude : 0))
        let radians = latitude * .pi / 180
        let x = (longitude + 180) / 360 * scale
        let y = (1 - asinh(tan(radians)) / .pi) / 2 * scale
        return MapTileCoordinate(x: x, y: min(scale, max(0, y)))
    }

    public static func coordinate(x: Double, y: Double, zoom: Int) -> Coordinate {
        let scale = Double(1 << clampedZoom(zoom))
        let x = min(scale, max(0, x.isFinite ? x : scale / 2))
        let y = min(scale, max(0, y.isFinite ? y : scale / 2))
        return Coordinate(
            longitude: x / scale * 360 - 180,
            latitude: atan(sinh(.pi * (1 - 2 * y / scale))) * 180 / .pi
        )
    }

    public static func tile(longitude: Double, latitude: Double, zoom: Int) -> MapTile {
        let safeZoom = clampedZoom(zoom)
        let count = 1 << safeZoom
        let position = tileCoordinate(longitude: longitude, latitude: latitude, zoom: safeZoom)
        return MapTile(
            zoom: safeZoom,
            x: min(count - 1, max(0, Int(floor(position.x)))),
            y: min(count - 1, max(0, Int(floor(position.y))))
        )
    }

    public static func normalizedLongitude(_ longitude: Double) -> Double {
        guard longitude.isFinite else { return 0 }
        var wrapped = longitude.truncatingRemainder(dividingBy: 360)
        if wrapped < -180 { wrapped += 360 }
        if wrapped >= 180 { wrapped -= 360 }
        return wrapped
    }

    static func clampedZoom(_ zoom: Int) -> Int {
        min(zoomRange.upperBound, max(zoomRange.lowerBound, zoom))
    }
}
