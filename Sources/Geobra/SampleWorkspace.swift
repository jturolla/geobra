import GeobraCore

enum SampleWorkspace {
    static func folder() -> GeoFolder {
        let protectedArea = GeoFeature(
            name: "Coastal reserve",
            geometry: .polygon([
                ring([(-43.92, -22.72), (-43.47, -22.66), (-43.28, -22.96),
                      (-43.55, -23.13), (-43.91, -23.02)]),
                ring([(-43.70, -22.82), (-43.69, -22.98), (-43.49, -22.95),
                      (-43.51, -22.80)])
            ]),
            properties: [
                "source": .string("Fictional sample data"),
                "status": .string("Draft boundary"),
                "note": .string("The inner boundary excludes a survey area.")
            ],
            style: FeatureStyle(colorHex: "#76C8A6", fillOpacity: 0.30, lineWidth: 2)
        )
        let studyArea = GeoFeature(
            name: "Eastern study area",
            geometry: .polygon([ring([
                (-43.03, -22.71), (-42.75, -22.72), (-42.61, -22.89),
                (-42.82, -23.00), (-43.08, -22.92)
            ])]),
            properties: [
                "source": .string("Fictional sample data"),
                "status": .string("Planned survey"),
                "team": .string("Field team B")
            ],
            style: FeatureStyle(colorHex: "#E7B86A", fillOpacity: 0.28, lineWidth: 2)
        )
        let route = GeoFeature(
            name: "Survey route",
            geometry: .lineString([
                coordinate(-43.75, -23.12), coordinate(-43.46, -23.15),
                coordinate(-43.19, -23.02), coordinate(-42.97, -23.06),
                coordinate(-42.75, -23.04)
            ]),
            properties: [
                "source": .string("Fictional sample data"),
                "status": .string("Proposed route")
            ],
            style: FeatureStyle(colorHex: "#8CB7F0", lineWidth: 3)
        )
        let base = GeoFeature(
            name: "Field base",
            geometry: .point(coordinate(-43.32, -22.93)),
            properties: [
                "source": .string("Fictional sample data"),
                "role": .string("Meeting point")
            ],
            style: FeatureStyle(colorHex: "#E7B86A")
        )
        let lookout = GeoFeature(
            name: "Observation point",
            geometry: .point(coordinate(-42.87, -22.87)),
            properties: [
                "source": .string("Fictional sample data"),
                "role": .string("Survey reference")
            ],
            style: FeatureStyle(colorHex: "#D5A2DF")
        )
        return GeoFolder(name: "Rio coastal survey · Sample", children: [
            GeoFolder(name: "Study boundaries", features: [protectedArea, studyArea]),
            GeoFolder(name: "Field work", features: [route, base, lookout])
        ])
    }

    private static func coordinate(_ longitude: Double, _ latitude: Double) -> Coordinate {
        Coordinate(longitude: longitude, latitude: latitude)
    }

    private static func ring(_ pairs: [(Double, Double)]) -> [Coordinate] {
        let coordinates = pairs.map { coordinate($0.0, $0.1) }
        guard let first = coordinates.first else { return [] }
        return coordinates + [first]
    }
}
