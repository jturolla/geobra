import AppKit
import GeobraCore
import SceneKit

struct GlobeTilePlan: Equatable {
    let tiles: [MapTile]
    let viewport: MapViewport
}

@MainActor
final class GlobeTileLayer {
    var onStatus: ((String) -> Void)?
    var onAttribution: ((MapAttribution) -> Void)?

    private let node = SCNNode()
    private let client = MapTileClient()
    private var configuration = MapConfiguration()
    private var request: Task<Void, Never>?
    private var generation = 0
    private var tileNodes: [MapTile: SCNNode] = [:]
    private var wantedTiles = Set<MapTile>()
    private var plan: GlobeTilePlan?
    private let maximumRetainedTiles = 192

    init(parent: SCNNode) {
        parent.addChildNode(node)
    }

    deinit { request?.cancel() }

    func update(configuration: MapConfiguration, plan: GlobeTilePlan?) {
        let sourceChanged = self.configuration.source != configuration.source
            || self.configuration.credentialRevision != configuration.credentialRevision
        let visibilityChanged = self.configuration.isBasemapVisible != configuration.isBasemapVisible
        self.configuration = configuration
        if sourceChanged || visibilityChanged {
            request?.cancel()
            generation += 1
            tileNodes.removeAll()
            wantedTiles.removeAll()
            node.childNodes.forEach { $0.removeFromParentNode() }
            self.plan = nil
        }
        node.isHidden = !configuration.isBasemapVisible
        guard configuration.isBasemapVisible else {
            onStatus?("Base map hidden")
            onAttribution?(MapAttribution(text: ""))
            return
        }
        guard let plan, !plan.tiles.isEmpty else {
            suspend()
            node.isHidden = true
            onAttribution?(MapAttribution(text: ""))
            onStatus?("Move the globe to view map coverage.")
            return
        }
        guard self.plan != plan else { return }
        self.plan = plan
        request?.cancel()
        generation += 1
        let currentGeneration = generation
        let source = configuration.source
        request = Task { [weak self] in
            guard let self else { return }
            self.onStatus?("Loading \(source.displayName)…")
            do {
                var attribution = try await self.client.attribution(for: plan.viewport, source: source)
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }
                let displayPlan = Self.limit(plan, to: attribution.maximumZoom)
                if displayPlan.viewport.zoom != plan.viewport.zoom {
                    attribution = try await self.client.attribution(for: displayPlan.viewport, source: source)
                    try Task.checkCancellation()
                    guard self.generation == currentGeneration else { return }
                }
                self.onAttribution?(attribution)
                self.wantedTiles = Set(displayPlan.tiles)
                let missing = displayPlan.tiles.filter { self.tileNodes[$0] == nil }
                var failureMessage: String?
                await withTaskGroup(of: TileResult.self) { group in
                    var nextIndex = 0
                    func addRequest(_ tile: MapTile) {
                        group.addTask { [client = self.client] in
                            do {
                                return .loaded(tile, try await client.tileData(for: tile, source: source))
                            } catch {
                                return .failed(error.localizedDescription)
                            }
                        }
                    }
                    while nextIndex < min(4, missing.count) {
                        addRequest(missing[nextIndex])
                        nextIndex += 1
                    }
                    while let result = await group.next() {
                        guard !Task.isCancelled, self.generation == currentGeneration else {
                            group.cancelAll()
                            break
                        }
                        switch result {
                        case .loaded(let tile, let data):
                            if let image = NSImage(data: data) {
                                self.install(tile: tile, image: image)
                            } else {
                                failureMessage = "A map tile could not be read."
                            }
                        case .failed(let message):
                            failureMessage = message
                        }
                        if nextIndex < missing.count {
                            addRequest(missing[nextIndex])
                            nextIndex += 1
                        }
                    }
                }
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                let wanted = Set(displayPlan.tiles)
                if failureMessage == nil {
                    self.removeTiles(except: wanted)
                }
                self.onStatus?(failureMessage ?? source.displayName)
            } catch {
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                self.onStatus?(error.localizedDescription)
            }
        }
    }

    func suspend() {
        request?.cancel()
        request = nil
        generation += 1
        plan = nil
        wantedTiles.removeAll()
    }

    private func install(tile: MapTile, image: NSImage) {
        let geometry = Self.geometry(for: tile)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.diffuse.minificationFilter = .linear
        material.diffuse.magnificationFilter = .linear
        material.diffuse.mipFilter = .linear
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        // Tiles replace the coarse sphere depth before the feature overlays render.
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = true
        geometry.materials = [material]
        let tileNode = SCNNode(geometry: geometry)
        tileNode.categoryBitMask = 8
        tileNode.renderingOrder = tile.zoom
        node.addChildNode(tileNode)
        tileNodes[tile] = tileNode
        if tileNodes.count > maximumRetainedTiles {
            let candidates = tileNodes.keys.filter { !wantedTiles.contains($0) }
            for oldTile in candidates.prefix(tileNodes.count - maximumRetainedTiles) {
                tileNodes.removeValue(forKey: oldTile)?.removeFromParentNode()
            }
        }
    }

    private func removeTiles(except wanted: Set<MapTile>) {
        for tile in Array(tileNodes.keys) where !wanted.contains(tile) {
            tileNodes.removeValue(forKey: tile)?.removeFromParentNode()
        }
    }

    private static func limit(_ plan: GlobeTilePlan, to maximumZoom: Int?) -> GlobeTilePlan {
        guard let maximumZoom, maximumZoom >= 0, maximumZoom < plan.viewport.zoom else { return plan }
        let shift = plan.viewport.zoom - maximumZoom
        var seen = Set<MapTile>()
        let tiles = plan.tiles.compactMap { tile -> MapTile? in
            let parent = MapTile(zoom: maximumZoom, x: tile.x >> shift, y: tile.y >> shift)
            return seen.insert(parent).inserted ? parent : nil
        }
        let viewport = MapViewport(
            zoom: maximumZoom, north: plan.viewport.north, south: plan.viewport.south,
            east: plan.viewport.east, west: plan.viewport.west
        )
        return GlobeTilePlan(tiles: tiles, viewport: viewport)
    }

    private static func geometry(for tile: MapTile) -> SCNGeometry {
        let bounds = tile.bounds
        let columns = max(2, min(128, Int(ceil((bounds.east - bounds.west) / 0.75))))
        let rows = max(2, min(128, Int(ceil((bounds.north - bounds.south) / 0.75))))
        var vertices: [SCNVector3] = []
        var textureCoordinates: [CGPoint] = []
        for row in 0...rows {
            let v = Double(row) / Double(rows)
            for column in 0...columns {
                let u = Double(column) / Double(columns)
                let coordinate = WebMercator.coordinate(
                    x: Double(tile.x) + u, y: Double(tile.y) + v, zoom: tile.zoom
                )
                vertices.append(GlobeProjection.position(coordinate))
                textureCoordinates.append(CGPoint(x: u, y: v))
            }
        }
        var indices: [Int32] = []
        let stride = columns + 1
        for row in 0..<rows {
            for column in 0..<columns {
                let topLeft = Int32(row * stride + column)
                let bottomLeft = Int32((row + 1) * stride + column)
                indices += [topLeft, bottomLeft, topLeft + 1, topLeft + 1, bottomLeft, bottomLeft + 1]
            }
        }
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(textureCoordinates: textureCoordinates)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
    }

    private enum TileResult: Sendable {
        case loaded(MapTile, Data)
        case failed(String)
    }
}

struct GlobeLineClip {
    let reference: Double
    let west: Double
    let east: Double
    let north: Double
    let south: Double

    func clip(_ start: Coordinate, _ end: Coordinate) -> [Coordinate]? {
        let startLongitude = reference + Self.difference(start.longitude, reference)
        let longitudeDelta = Self.difference(end.longitude, start.longitude)
        let latitudeDelta = end.latitude - start.latitude
        let directions = [-longitudeDelta, longitudeDelta, -latitudeDelta, latitudeDelta]
        let distances = [startLongitude - west, east - startLongitude, start.latitude - south, north - start.latitude]
        var first = 0.0
        var last = 1.0
        for index in directions.indices {
            let direction = directions[index]
            let distance = distances[index]
            if abs(direction) < 0.000000000001 {
                if distance < 0 { return nil }
            } else {
                let fraction = distance / direction
                if direction < 0 { first = max(first, fraction) }
                else { last = min(last, fraction) }
                if first > last { return nil }
            }
        }
        return [first, last].map { fraction in
            Coordinate(longitude: startLongitude + longitudeDelta * fraction,
                       latitude: start.latitude + latitudeDelta * fraction)
        }
    }

    private static func difference(_ longitude: Double, _ reference: Double) -> Double {
        var difference = (longitude - reference).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        return difference
    }
}

@MainActor
enum GlobeProjection {
    static func position(_ coordinate: Coordinate, radius: Double = 1) -> SCNVector3 {
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        return SCNVector3(
            radius * cos(latitude) * sin(longitude),
            radius * sin(latitude),
            radius * cos(latitude) * cos(longitude)
        )
    }

    static func coordinate(at point: CGPoint, in view: SCNView) -> Coordinate? {
        guard let position = intersection(at: point, in: view) else { return nil }
        return Coordinate(
            longitude: atan2(position.x, position.z) * 180 / .pi,
            latitude: asin(min(1, max(-1, position.y))) * 180 / .pi
        )
    }

    static func intersection(at point: CGPoint, in view: SCNView,
                             usePresentation: Bool = true) -> SIMD3<Double>? {
        guard let cameraNode = view.pointOfView else { return nil }
        let camera = usePresentation ? cameraNode.presentation : cameraNode
        guard let lens = camera.camera,
              view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let tangent = tan(lens.fieldOfView * .pi / 360)
        let aspect = view.bounds.width / view.bounds.height
        let x = (point.x - view.bounds.midX) / (view.bounds.width / 2)
        let y = (view.isFlipped ? view.bounds.midY - point.y : point.y - view.bounds.midY) / (view.bounds.height / 2)
        let vector = camera.convertVector(SCNVector3(x * tangent * aspect, y * tangent, -1), to: nil)
        let eye = camera.worldPosition
        let origin = SIMD3(Double(eye.x), Double(eye.y), Double(eye.z))
        let direction = SIMD3(Double(vector.x), Double(vector.y), Double(vector.z))
        let length = sqrt(dot(direction, direction))
        guard length.isFinite, length > 0 else { return nil }
        let ray = direction / length
        let projection = dot(origin, ray)
        let discriminant = projection * projection - dot(origin, origin) + 1
        guard discriminant >= 0 else { return nil }
        let distance = -projection - sqrt(discriminant)
        guard distance >= 0 else { return nil }
        return origin + ray * distance
    }

    static func lineClip(in view: SCNView, longitude: Double) -> GlobeLineClip? {
        let corners = [
            CGPoint(x: view.bounds.minX, y: view.bounds.minY),
            CGPoint(x: view.bounds.maxX, y: view.bounds.minY),
            CGPoint(x: view.bounds.minX, y: view.bounds.maxY),
            CGPoint(x: view.bounds.maxX, y: view.bounds.maxY)
        ]
        let positions = corners.compactMap { intersection(at: $0, in: view, usePresentation: false) }
        guard positions.count == 4 else { return nil }
        let longitudes = positions.map { longitude + longitudeDifference(atan2($0.x, $0.z) * 180 / .pi, longitude) }
        let latitudes = positions.map { asin(min(1, max(-1, $0.y))) * 180 / .pi }
        let west = longitudes.min() ?? longitude
        let east = longitudes.max() ?? longitude
        let south = latitudes.min() ?? 0
        let north = latitudes.max() ?? 0
        let margin = max(east - west, north - south) * 0.1
        return GlobeLineClip(reference: longitude, west: west - margin, east: east + margin,
                             north: min(90, north + margin), south: max(-90, south - margin))
    }

    static func plan(in view: SCNView, longitude: Double, latitude: Double,
                     distance: Double, maximumZoom: Int) -> GlobeTilePlan? {
        guard view.bounds.width > 1, view.bounds.height > 1 else { return nil }
        var coordinates: [Coordinate] = []
        let sampleCount = 24
        for row in 0...sampleCount {
            for column in 0...sampleCount {
                let point = CGPoint(
                    x: view.bounds.width * Double(column) / Double(sampleCount),
                    y: view.bounds.height * Double(row) / Double(sampleCount)
                )
                if let coordinate = coordinate(at: point, in: view) { coordinates.append(coordinate) }
            }
        }
        guard !coordinates.isEmpty else { return nil }
        let altitude = max(0.00000001, distance - 1)
        let unitsPerPixel = 2 * altitude * tan(21 * .pi / 180) / view.bounds.height
        let cosine = max(0.05, cos(latitude * .pi / 180))
        let preferredZoom = Int(floor(log2(2 * .pi * cosine / (256 * unitsPerPixel))))
        var zoom = min(maximumZoom, max(2, preferredZoom))
        let reference = WebMercator.normalizedLongitude(longitude)
        var west = coordinates.map { reference + longitudeDifference($0.longitude, reference) }.min() ?? reference
        var east = coordinates.map { reference + longitudeDifference($0.longitude, reference) }.max() ?? reference
        for poleLatitude in [-90.0, 90.0] {
            if visible(position(Coordinate(longitude: 0, latitude: poleLatitude)), in: view) {
                west = reference - 180
                east = reference + 180
            }
        }
        let north = min(WebMercator.maximumLatitude, coordinates.map(\.latitude).max() ?? latitude)
        let south = max(-WebMercator.maximumLatitude, coordinates.map(\.latitude).min() ?? latitude)
        guard north >= south else { return nil }
        var tiles: [MapTile] = []
        while zoom >= 0 {
            let count = 1 << zoom
            let top = WebMercator.tile(longitude: 0, latitude: north, zoom: zoom).y
            let bottom = WebMercator.tile(longitude: 0, latitude: south, zoom: zoom).y
            let firstColumn = Int(floor((west + 180) / 360 * Double(count)))
            let lastColumn = Int(floor((east + 180) / 360 * Double(count)))
            let candidateCount = (bottom - top + 1) * (lastColumn - firstColumn + 1)
            if candidateCount > 512 { zoom -= 1; continue }
            var candidates = Set<MapTile>()
            for row in top...bottom {
                for column in firstColumn...lastColumn {
                    let x = ((column % count) + count) % count
                    candidates.insert(MapTile(zoom: zoom, x: x, y: row))
                }
            }
            let touched = Set(coordinates.map { WebMercator.tile(longitude: $0.longitude, latitude: $0.latitude, zoom: zoom) })
            tiles = candidates.filter { touched.contains($0) || visible($0, in: view) }
            if tiles.count <= 96 || zoom == 0 { break }
            zoom -= 1
        }
        let center = WebMercator.tileCoordinate(longitude: reference, latitude: latitude, zoom: zoom)
        let count = Double(1 << zoom)
        tiles.sort {
            func squaredDistance(_ tile: MapTile) -> Double {
                let dx = abs(Double(tile.x) + 0.5 - center.x)
                let wrappedDX = min(dx, count - dx)
                let dy = Double(tile.y) + 0.5 - center.y
                return wrappedDX * wrappedDX + dy * dy
            }
            return squaredDistance($0) < squaredDistance($1)
        }
        let viewport = MapViewport(
            zoom: zoom, north: north, south: south,
            east: east - west >= 359 ? 180 : WebMercator.normalizedLongitude(east),
            west: east - west >= 359 ? -180 : WebMercator.normalizedLongitude(west)
        )
        return GlobeTilePlan(tiles: tiles, viewport: viewport)
    }

    private static func visible(_ tile: MapTile, in view: SCNView) -> Bool {
        for row in 0...4 {
            for column in 0...4 {
                let coordinate = WebMercator.coordinate(
                    x: Double(tile.x) + Double(column) / 4,
                    y: Double(tile.y) + Double(row) / 4, zoom: tile.zoom
                )
                if visible(position(coordinate), in: view) { return true }
            }
        }
        return false
    }

    private static func visible(_ position: SCNVector3, in view: SCNView) -> Bool {
        guard let camera = view.pointOfView?.presentation.worldPosition else { return false }
        let point = SIMD3(Double(position.x), Double(position.y), Double(position.z))
        let eye = SIMD3(Double(camera.x), Double(camera.y), Double(camera.z))
        guard dot(point, eye - point) > 0 else { return false }
        let projected = view.projectPoint(position)
        return projected.z >= 0 && projected.z <= 1
            && projected.x >= 0 && projected.x <= view.bounds.width
            && projected.y >= 0 && projected.y <= view.bounds.height
    }

    private static func longitudeDifference(_ longitude: Double, _ reference: Double) -> Double {
        var difference = (longitude - reference).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        return difference
    }

    private static func dot(_ first: SIMD3<Double>, _ second: SIMD3<Double>) -> Double {
        first.x * second.x + first.y * second.y + first.z * second.z
    }
}
