import Foundation

enum MapSource: String, CaseIterable, Identifiable, Sendable {
    case openStreetMap
    case googleRoadmap
    case googleSatellite
    case googleHybrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openStreetMap: return "OpenStreetMap"
        case .googleRoadmap: return "Google Maps"
        case .googleSatellite: return "Google Satellite"
        case .googleHybrid: return "Google Hybrid"
        }
    }

    var requiresAPIKey: Bool { self != .openStreetMap }
    var maximumZoom: Int { self == .openStreetMap ? 19 : 22 }

    var attributionName: String {
        requiresAPIKey ? "Google Maps" : "© OpenStreetMap contributors"
    }
}

struct MapConfiguration: Equatable, Sendable {
    var source: MapSource
    var isBasemapVisible: Bool
    var showsGrid: Bool
    var credentialRevision: Int

    init(source: MapSource = .openStreetMap, isBasemapVisible: Bool = true,
         showsGrid: Bool = false, credentialRevision: Int = 0) {
        self.source = source
        self.isBasemapVisible = isBasemapVisible
        self.showsGrid = showsGrid
        self.credentialRevision = credentialRevision
    }
}

struct MapAttribution: Equatable, Sendable {
    var text: String
    var maximumZoom: Int?

    init(text: String, maximumZoom: Int? = nil) {
        self.text = text
        self.maximumZoom = maximumZoom
    }
}
