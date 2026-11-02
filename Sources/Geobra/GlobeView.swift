import AppKit
import SceneKit
import SwiftUI
import GeobraCore

struct GlobeView: NSViewRepresentable {
    let features: [GeoFeature]
    let selectedID: UUID?
    var selectedIDs: Set<UUID> = []
    let focusID: UUID?
    var focusGeometry: GeoGeometry? = nil
    let focusRevision: Int
    let resetRevision: Int
    let zoomRevision: Int
    var mapConfiguration = MapConfiguration()
    let onSelect: (UUID?) -> Void
    var onMapStatus: ((String) -> Void)? = nil
    var onMapAttribution: ((MapAttribution) -> Void)? = nil

    func makeNSView(context: Context) -> GlobeSceneView {
        GlobeSceneView(frame: .zero)
    }

    func updateNSView(_ view: GlobeSceneView, context: Context) {
        view.onSelect = onSelect
        view.onMapStatus = onMapStatus
        view.onMapAttribution = onMapAttribution
        view.updateMap(configuration: mapConfiguration)
        view.update(features: features, selectedID: selectedID, selectedIDs: selectedIDs)
        if view.focusRevision != focusRevision {
            view.focusRevision = focusRevision
            if let geometry = focusGeometry {
                view.focus(on: GeoFeature(name: "Selection", geometry: geometry))
            } else if let feature = features.first(where: { $0.id == focusID }) {
                view.focus(on: feature)
            }
        }
        if view.resetRevision != resetRevision {
            view.resetRevision = resetRevision
            view.resetCamera()
        }
        if view.zoomRevision != zoomRevision {
            let difference = zoomRevision - view.zoomRevision
            view.zoomRevision = zoomRevision
            view.zoom(by: pow(0.74, Double(difference)))
        }
    }
}

final class GlobeSceneView: SCNView {
    var onSelect: ((UUID?) -> Void)?
    var onMapStatus: ((String) -> Void)?
    var onMapAttribution: ((MapAttribution) -> Void)?
    var focusRevision = 0
    var resetRevision = 0
    var zoomRevision = 0

    private let globe = SCNNode()
    private let overlays = SCNNode()
    private let cameraNode = SCNNode()
    private let grid = SCNNode()
    private var tileLayer: GlobeTileLayer?
    private var mapConfiguration = MapConfiguration()
    private var mapUpdate: Task<Void, Never>?
    private var features: [GeoFeature] = []
    private var selectedIDs = Set<UUID>()
    private var polygonTextureDimension = 1536
    private var selectedPolygonTextureDimension = 1536
    private var longitude = -48.0
    private var latitude = -14.0
    private var distance = 3.15
    private var pointNodes: [SCNNode] = []
    private var surfaceNodes: [(node: SCNNode, radius: Double)] = []
    private var lineNodes: [(node: SCNNode, coordinates: [Coordinate], radius: Double, material: SCNMaterial)] = []
    private var gridPaths: [[Coordinate]] = []
    private var lineClip: GlobeLineClip?
    private var dragStart: NSPoint?
    private var dragDistance: CGFloat = 0

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        configureScene()
        setAccessibilityLabel("Interactive Earth globe")
        setAccessibilityHelp("Drag to rotate. Scroll to zoom. Click a feature to select it.")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureScene()
    }

    private func configureScene() {
        let scene = SCNScene()
        scene.background.contents = NSColor(red: 0.025, green: 0.038, blue: 0.055, alpha: 1)
        self.scene = scene
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
        rendersContinuously = false
        allowsCameraControl = false
        autoenablesDefaultLighting = false
        usesReverseZ = true

        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 42
        cameraNode.camera?.zNear = 0.0001
        cameraNode.camera?.zFar = 150
        cameraNode.camera?.wantsHDR = false
        cameraNode.camera?.exposureOffset = 0.12
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode

        let surface = GlobeMesh.geometry(
            minLongitude: -180, maxLongitude: 180,
            minLatitude: -90, maxLatitude: 90,
            radius: 1, longitudeSteps: 256, latitudeSteps: 128
        )
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(white: 0.17, alpha: 1)
        material.diffuse.wrapS = .repeat
        material.diffuse.magnificationFilter = .linear
        material.diffuse.minificationFilter = .linear
        material.diffuse.mipFilter = .linear
        surface.materials = [material]
        globe.geometry = surface
        globe.name = "earth"
        globe.categoryBitMask = 1
        globe.renderingOrder = -10
        scene.rootNode.addChildNode(globe)
        scene.rootNode.addChildNode(overlays)
        scene.rootNode.addChildNode(grid)
        configureGrid()
        tileLayer = GlobeTileLayer(parent: scene.rootNode)
        tileLayer?.onStatus = { [weak self] in self?.onMapStatus?($0) }
        tileLayer?.onAttribution = { [weak self] in self?.onMapAttribution?($0) }
        addAtmosphere(to: scene)
        addStars(to: scene)
        updateCamera(animated: false)
    }

    private func addAtmosphere(to scene: SCNScene) {
        for index in 1...8 {
            let sphere = SCNSphere(radius: 1 + CGFloat(index) * 0.002)
            sphere.segmentCount = 128
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor(red: 0.18, green: 0.5, blue: 0.8, alpha: 1)
            material.transparency = CGFloat(9 - index) * 0.012
            material.cullMode = .front
            material.blendMode = .alpha
            material.writesToDepthBuffer = false
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.categoryBitMask = 4
            node.renderingOrder = -5
            scene.rootNode.addChildNode(node)
        }
    }

    private func addStars(to scene: SCNScene) {
        var vertices: [SCNVector3] = []
        for index in 0..<520 {
            let y = 1 - 2 * (Double(index) + 0.5) / 520
            let angle = Double(index) * 2.399963229728653
            let radial = sqrt(1 - y * y)
            vertices.append(SCNVector3(70 * radial * cos(angle), 70 * y, 70 * radial * sin(angle)))
        }
        let source = SCNGeometrySource(vertices: vertices)
        let indices = (0..<vertices.count).map { Int32($0) }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 1.1
        element.minimumPointScreenSpaceRadius = 0.45
        element.maximumPointScreenSpaceRadius = 0.9
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(white: 0.4, alpha: 1)
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = 4
        scene.rootNode.addChildNode(node)
    }

    func update(features: [GeoFeature], selectedID: UUID?, selectedIDs: Set<UUID> = []) {
        let selection = selectedIDs.union(selectedID.map { [$0] } ?? [])
        guard self.features != features || self.selectedIDs != selection else { return }
        self.features = features
        self.selectedIDs = selection
        let selectedCount = features.filter { selection.contains($0.id) }.reduce(0) { $0 + polygonCount($1.geometry) }
        let otherCount = features.filter { !selection.contains($0.id) }.reduce(0) { $0 + polygonCount($1.geometry) }
        let sharedPixelBudget = 8_000_000.0
        let normalPixelBudget = selectedCount > 0 ? sharedPixelBudget / 2 : sharedPixelBudget
        polygonTextureDimension = textureDimension(count: otherCount, pixelBudget: normalPixelBudget)
        selectedPolygonTextureDimension = textureDimension(count: selectedCount, pixelBudget: sharedPixelBudget / 2)
        overlays.childNodes.forEach { $0.removeFromParentNode() }
        pointNodes.removeAll()
        surfaceNodes.removeAll()
        lineNodes.removeAll()
        for feature in features {
            guard let geometry = feature.geometry else { continue }
            addGeometry(geometry, feature: feature, selected: selection.contains(feature.id))
        }
        updatePointScale()
    }

    private func textureDimension(count: Int, pixelBudget: Double) -> Int {
        max(64, min(1536, Int(sqrt(pixelBudget / Double(max(1, count))))))
    }

    private func polygonCount(_ geometry: GeoGeometry?) -> Int {
        guard let geometry else { return 0 }
        switch geometry {
        case .polygon: return 1
        case .multiPolygon(let polygons): return polygons.count
        case .geometryCollection(let geometries): return geometries.reduce(0) { $0 + polygonCount($1) }
        default: return 0
        }
    }

    private func addGeometry(_ geometry: GeoGeometry, feature: GeoFeature, selected: Bool) {
        switch geometry {
        case .point(let coordinate):
            addPoint(coordinate, feature: feature, selected: selected)
        case .multiPoint(let coordinates):
            coordinates.forEach { addPoint($0, feature: feature, selected: selected) }
        case .lineString(let coordinates):
            addLine(coordinates, feature: feature, selected: selected)
        case .multiLineString(let lines):
            lines.forEach { addLine($0, feature: feature, selected: selected) }
        case .polygon(let rings):
            addPolygon(rings, feature: feature, selected: selected)
        case .multiPolygon(let polygons):
            polygons.forEach { addPolygon($0, feature: feature, selected: selected) }
        case .geometryCollection(let geometries):
            geometries.forEach { addGeometry($0, feature: feature, selected: selected) }
        }
    }

    private func addPoint(_ coordinate: Coordinate, feature: GeoFeature, selected: Bool) {
        let sphere = SCNSphere(radius: selected ? 0.009 : 0.006)
        sphere.segmentCount = 12
        let material = overlayMaterial(color: selected ? .controlAccentColor : feature.style.colorHex.globeColor)
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        node.position = GlobeMesh.position(longitude: coordinate.longitude, latitude: coordinate.latitude, radius: 1.0006)
        node.name = feature.id.uuidString
        node.categoryBitMask = 2
        node.renderingOrder = 150
        overlays.addChildNode(node)
        pointNodes.append(node)
    }

    private func addLine(_ coordinates: [Coordinate], feature: GeoFeature, selected: Bool) {
        guard coordinates.count > 1, feature.style.lineWidth > 0 else { return }
        let radius = selected ? 1.0007 : 1.0004
        let geometry = pathGeometry([coordinates], radius: radius)
        let material = overlayMaterial(color: selected ? .controlAccentColor : feature.style.colorHex.globeColor)
        geometry?.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = feature.id.uuidString
        node.categoryBitMask = 2
        node.renderingOrder = 150
        overlays.addChildNode(node)
        surfaceNodes.append((node, radius))
        lineNodes.append((node, coordinates, radius, material))
    }

    private func addPolygon(_ rings: [[Coordinate]], feature: GeoFeature, selected: Bool) {
        guard let patch = PolygonPatch(rings: rings),
              let texture = patch.texture(
                style: feature.style, selected: selected,
                maximumDimension: selected ? selectedPolygonTextureDimension : polygonTextureDimension
              ) else { return }
        let geometry = GlobeMesh.geometry(
            minLongitude: patch.minLongitude, maxLongitude: patch.maxLongitude,
            minLatitude: patch.minLatitude, maxLatitude: patch.maxLatitude,
            radius: selected ? 1.0007 : 1.0004,
            longitudeSteps: max(2, Int(ceil(patch.longitudeSpan / 1.5))),
            latitudeSteps: max(2, Int(ceil(patch.latitudeSpan / 1.5)))
        )
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = texture
        material.isDoubleSided = false
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.transparencyMode = .aOne
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = feature.id.uuidString
        node.categoryBitMask = 4
        node.renderingOrder = selected ? 120 : 100
        overlays.addChildNode(node)
        surfaceNodes.append((node, selected ? 1.0007 : 1.0004))
        rings.forEach { addLine($0, feature: feature, selected: selected) }
    }

    private func overlayMaterial(color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.isDoubleSided = true
        return material
    }

    func focus(on feature: GeoFeature) {
        guard let coordinates = feature.geometry?.coordinates, !coordinates.isEmpty else { return }
        let longitudeRadians = coordinates.map { $0.longitude * .pi / 180 }
        let sinSum = longitudeRadians.reduce(0) { $0 + sin($1) }
        let cosSum = longitudeRadians.reduce(0) { $0 + cos($1) }
        longitude = atan2(sinSum, cosSum) * 180 / .pi
        let minimumLatitude = coordinates.map(\.latitude).min() ?? 0
        let maximumLatitude = coordinates.map(\.latitude).max() ?? 0
        latitude = (minimumLatitude + maximumLatitude) / 2
        let longitudeSpan = coordinates.map { abs(GlobeMesh.longitudeDifference($0.longitude, longitude)) }.max() ?? 0
        let angularSpan = max(maximumLatitude - minimumLatitude, longitudeSpan * 2 * cos(latitude * .pi / 180))
        distance = min(3.2, max(1.00003, 1 + angularSpan / 40))
        updateCamera(animated: true)
    }

    func resetCamera() {
        longitude = -48
        latitude = -14
        distance = 3.15
        updateCamera(animated: true)
    }

    func zoom(by factor: Double) {
        distance = min(8, max(1.0000005, 1 + (distance - 1) * factor))
        updateCamera(animated: false)
    }

    private func updateCamera(animated: Bool) {
        latitude = min(89.5, max(-89.5, latitude))
        longitude = WebMercator.normalizedLongitude(longitude)
        cameraNode.camera?.zNear = min(0.0001, max(0.0000000001, (distance - 1) * 0.002))
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.65 : 0
        cameraNode.position = GlobeMesh.position(longitude: longitude, latitude: latitude, radius: distance)
        cameraNode.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        updatePointScale()
        SCNTransaction.commit()
        setNeedsDisplay(bounds)
        scheduleMapUpdate(delay: animated ? 0.75 : 0.18)
    }

    private func updatePointScale() {
        let scale = max(0.0000001, (distance - 1) / 2.15)
        let surfaceRadius = 1 + min(0.0001, (distance - 1) * 0.002)
        for node in pointNodes {
            node.scale = SCNVector3(scale, scale, scale)
            let length = sqrt(node.position.x * node.position.x + node.position.y * node.position.y + node.position.z * node.position.z)
            if length > 0 {
                node.position = SCNVector3(
                    node.position.x / length * surfaceRadius,
                    node.position.y / length * surfaceRadius,
                    node.position.z / length * surfaceRadius
                )
            }
        }
        for surface in surfaceNodes {
            let scale = surfaceRadius / surface.radius
            surface.node.scale = SCNVector3(scale, scale, scale)
        }
        grid.scale = SCNVector3(surfaceRadius, surfaceRadius, surfaceRadius)
    }

    func updateMap(configuration: MapConfiguration) {
        guard configuration != mapConfiguration else { return }
        mapConfiguration = configuration
        grid.isHidden = !configuration.showsGrid
        scheduleMapUpdate(delay: 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            mapUpdate?.cancel()
            tileLayer?.suspend()
        } else {
            scheduleMapUpdate(delay: 0.1)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { scheduleMapUpdate(delay: 0.2) }
    }

    private func scheduleMapUpdate(delay: Double) {
        mapUpdate?.cancel()
        guard window != nil else { return }
        mapUpdate = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.refreshPaths()
            let plan = GlobeProjection.plan(
                in: self, longitude: self.longitude, latitude: self.latitude,
                distance: self.distance, maximumZoom: self.mapConfiguration.source.maximumZoom
            )
            self.tileLayer?.update(configuration: self.mapConfiguration, plan: plan)
            self.setNeedsDisplay(self.bounds)
        }
    }

    private func configureGrid() {
        for longitude in stride(from: -180, to: 180, by: 30) {
            gridPaths.append((-90...90).map { Coordinate(longitude: Double(longitude), latitude: Double($0)) })
        }
        for latitude in stride(from: -60, through: 60, by: 30) {
            gridPaths.append((-180...180).map { Coordinate(longitude: Double($0), latitude: Double(latitude)) })
        }
        grid.geometry = pathGeometry(gridPaths, radius: 1)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(white: 0.55, alpha: 0.55)
        material.writesToDepthBuffer = false
        grid.geometry?.materials = [material]
        grid.categoryBitMask = 4
        grid.renderingOrder = 50
        grid.isHidden = !mapConfiguration.showsGrid
    }

    private func refreshPaths() {
        lineClip = GlobeProjection.lineClip(in: self, longitude: longitude)
        for line in lineNodes {
            line.node.geometry = pathGeometry([line.coordinates], radius: line.radius)
            line.node.geometry?.materials = [line.material]
        }
        let material = grid.geometry?.firstMaterial ?? overlayMaterial(color: NSColor(white: 0.55, alpha: 0.55))
        grid.geometry = pathGeometry(gridPaths, radius: 1)
        grid.geometry?.materials = [material]
    }

    private func pathGeometry(_ paths: [[Coordinate]], radius: Double) -> SCNGeometry? {
        let offset = min(0.0001, (distance - 1) * 0.002)
        let maximumAngle = min(0.5, max(0.00001, sqrt(8 * offset) * 180 / .pi * 0.7))
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        for coordinates in paths where coordinates.count > 1 {
            for index in 1..<coordinates.count {
                let start = coordinates[index - 1]
                let end = coordinates[index]
                let clipped: [Coordinate]
                if let lineClip {
                    guard let segment = lineClip.clip(start, end) else { continue }
                    clipped = segment
                } else {
                    clipped = [start, end]
                }
                let points = GlobeMesh.subdivide(clipped, maximumAngle: lineClip == nil ? 0.5 : maximumAngle)
                let firstIndex = vertices.count
                vertices += points.map { GlobeMesh.position(longitude: $0.longitude, latitude: $0.latitude, radius: radius) }
                for pointIndex in 0..<(points.count - 1) {
                    indices += [Int32(firstIndex + pointIndex), Int32(firstIndex + pointIndex + 1)]
                }
            }
        }
        guard !vertices.isEmpty else { return nil }
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .line)]
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil)
        dragDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        let sensitivity = max(0.00000002, min(0.3, (distance - 1) * 0.13))
        longitude -= Double(event.deltaX) * sensitivity
        latitude += Double(event.deltaY) * sensitivity
        dragDistance += abs(event.deltaX) + abs(event.deltaY)
        updateCamera(animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard dragStart != nil, dragDistance < 4 else { return }
        let point = convert(event.locationInWindow, from: nil)
        select(at: point)
    }

    override func scrollWheel(with event: NSEvent) {
        let amount = event.hasPreciseScrollingDeltas ? 0.008 : 0.08
        zoom(by: exp(Double(-event.scrollingDeltaY) * amount))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: exp(-Double(event.magnification) * 2))
    }

    override var acceptsFirstResponder: Bool { true }

    private func select(at point: NSPoint) {
        let pointHits = hitTest(point, options: [.categoryBitMask: 2, .searchMode: SCNHitTestSearchMode.all.rawValue])
        guard let intersection = GlobeProjection.intersection(at: point, in: self) else {
            onSelect?(nil)
            return
        }
        let earthPoint = SCNVector3(intersection.x, intersection.y, intersection.z)
        if let hit = pointHits.first,
           distanceToCamera(hit.worldCoordinates) <= distanceToCamera(earthPoint) + max(0.00000001, (distance - 1) * 0.005),
           let name = hit.node.name, let id = UUID(uuidString: name) {
            onSelect?(id)
            return
        }
        let clickedLongitude = atan2(intersection.x, intersection.z) * 180 / .pi
        let clickedLatitude = asin(min(1, max(-1, intersection.y))) * 180 / .pi
        for feature in features.reversed() {
            if let geometry = feature.geometry,
               contains(geometry, longitude: clickedLongitude, latitude: clickedLatitude) {
                onSelect?(feature.id)
                return
            }
        }
        onSelect?(nil)
    }

    private func distanceToCamera(_ position: SCNVector3) -> Double {
        let camera = cameraNode.presentation.worldPosition
        let x = Double(position.x - camera.x)
        let y = Double(position.y - camera.y)
        let z = Double(position.z - camera.z)
        return sqrt(x * x + y * y + z * z)
    }

    private func contains(_ geometry: GeoGeometry, longitude: Double, latitude: Double) -> Bool {
        switch geometry {
        case .polygon(let rings):
            return PolygonPatch(rings: rings)?.contains(longitude: longitude, latitude: latitude) ?? false
        case .multiPolygon(let polygons):
            return polygons.contains { PolygonPatch(rings: $0)?.contains(longitude: longitude, latitude: latitude) ?? false }
        case .geometryCollection(let geometries):
            return geometries.contains { contains($0, longitude: longitude, latitude: latitude) }
        default:
            return false
        }
    }
}

private enum GlobeMesh {
    static func position(longitude: Double, latitude: Double, radius: Double) -> SCNVector3 {
        let phi = latitude * .pi / 180
        let theta = longitude * .pi / 180
        return SCNVector3(radius * cos(phi) * sin(theta), radius * sin(phi), radius * cos(phi) * cos(theta))
    }

    static func longitudeDifference(_ longitude: Double, _ reference: Double) -> Double {
        var difference = (longitude - reference).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        return difference
    }

    static func geometry(
        minLongitude: Double, maxLongitude: Double,
        minLatitude: Double, maxLatitude: Double,
        radius: Double, longitudeSteps: Int, latitudeSteps: Int
    ) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var textureCoordinates: [CGPoint] = []
        for row in 0...latitudeSteps {
            let v = Double(row) / Double(latitudeSteps)
            let latitude = maxLatitude - (maxLatitude - minLatitude) * v
            for column in 0...longitudeSteps {
                let u = Double(column) / Double(longitudeSteps)
                let longitude = minLongitude + (maxLongitude - minLongitude) * u
                vertices.append(position(longitude: longitude, latitude: latitude, radius: radius))
                normals.append(position(longitude: longitude, latitude: latitude, radius: 1))
                textureCoordinates.append(CGPoint(x: u, y: v))
            }
        }
        var indices: [Int32] = []
        let rowSize = longitudeSteps + 1
        for row in 0..<latitudeSteps {
            for column in 0..<longitudeSteps {
                let topLeft = Int32(row * rowSize + column)
                let bottomLeft = Int32((row + 1) * rowSize + column)
                indices += [topLeft, bottomLeft, topLeft + 1, topLeft + 1, bottomLeft, bottomLeft + 1]
            }
        }
        return SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: textureCoordinates)
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
    }

    static func subdivide(_ coordinates: [Coordinate], maximumAngle: Double = 0.5) -> [Coordinate] {
        guard let first = coordinates.first else { return [] }
        var result = [first]
        for index in 1..<coordinates.count {
            let start = coordinates[index - 1]
            let end = coordinates[index]
            let longitudeDelta = longitudeDifference(end.longitude, start.longitude)
            let latitudeDelta = end.latitude - start.latitude
            let count = max(1, Int(ceil(max(abs(longitudeDelta), abs(latitudeDelta)) / maximumAngle)))
            for step in 1...count {
                let fraction = Double(step) / Double(count)
                result.append(Coordinate(
                    longitude: start.longitude + longitudeDelta * fraction,
                    latitude: start.latitude + latitudeDelta * fraction
                ))
            }
        }
        return result
    }
}

private struct PolygonPatch {
    let minLongitude: Double
    let maxLongitude: Double
    let minLatitude: Double
    let maxLatitude: Double
    private let rings: [[CGPoint]]

    var longitudeSpan: Double { maxLongitude - minLongitude }
    var latitudeSpan: Double { maxLatitude - minLatitude }

    init?(rings coordinates: [[Coordinate]]) {
        guard let outer = coordinates.first, outer.count >= 4 else { return nil }
        var unwrapped: [[CGPoint]] = []
        let anchor = outer[0].longitude
        for ring in coordinates where ring.count >= 4 {
            var previous = anchor
            let points = ring.map { coordinate -> CGPoint in
                let longitude = previous + GlobeMesh.longitudeDifference(coordinate.longitude, previous)
                previous = longitude
                return CGPoint(x: longitude, y: coordinate.latitude)
            }
            unwrapped.append(points)
        }
        guard let exterior = unwrapped.first else { return nil }
        let longitudes = exterior.map(\.x)
        let latitudes = exterior.map(\.y)
        minLongitude = longitudes.min() ?? 0
        maxLongitude = max(minLongitude + 0.000001, longitudes.max() ?? 0)
        minLatitude = latitudes.min() ?? 0
        maxLatitude = max(minLatitude + 0.000001, latitudes.max() ?? 0)
        rings = unwrapped
    }

    func texture(style: FeatureStyle, selected: Bool, maximumDimension: Int) -> CGImage? {
        let ratio = longitudeSpan / latitudeSpan
        let dimension = Double(maximumDimension)
        let width = max(16, min(maximumDimension, Int(dimension * min(1, ratio))))
        let height = max(16, min(maximumDimension, Int(dimension / max(1, ratio))))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let path = makePath(width: Double(width), height: Double(height))
        context.addPath(path)
        let color = selected ? NSColor.controlAccentColor : style.colorHex.globeColor
        let opacity = max(0, min(1, style.fillOpacity))
        context.setFillColor(color.withAlphaComponent(selected ? max(0.2, opacity) : opacity).cgColor)
        context.fillPath(using: .evenOdd)
        if style.lineWidth > 0 {
            context.addPath(path)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(style.lineWidth * (selected ? 1.8 : 1))
            context.setLineJoin(.round)
            context.strokePath()
        }
        return context.makeImage()
    }

    func contains(longitude: Double, latitude: Double) -> Bool {
        let center = (minLongitude + maxLongitude) / 2
        let adjustedLongitude = center + GlobeMesh.longitudeDifference(longitude, center)
        let path = makePath(width: 1, height: 1)
        let point = CGPoint(
            x: (adjustedLongitude - minLongitude) / longitudeSpan,
            y: (maxLatitude - latitude) / latitudeSpan
        )
        return path.contains(point, using: .evenOdd)
    }

    private func makePath(width: Double, height: Double) -> CGPath {
        let path = CGMutablePath()
        for ring in rings {
            for (index, point) in ring.enumerated() {
                let projected = CGPoint(
                    x: (point.x - minLongitude) / longitudeSpan * width,
                    y: (maxLatitude - point.y) / latitudeSpan * height
                )
                if index == 0 { path.move(to: projected) } else { path.addLine(to: projected) }
            }
            path.closeSubpath()
        }
        return path
    }
}

private extension String {
    var globeColor: NSColor {
        let value = trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let number = UInt32(value, radix: 16) else {
            return NSColor(red: 0.32, green: 0.82, blue: 0.7, alpha: 1)
        }
        return NSColor(
            red: CGFloat((number >> 16) & 255) / 255,
            green: CGFloat((number >> 8) & 255) / 255,
            blue: CGFloat(number & 255) / 255,
            alpha: 1
        )
    }
}
