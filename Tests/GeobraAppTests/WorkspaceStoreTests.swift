import Foundation
import GeobraCore
import XCTest
@testable import Geobra

final class WorkspaceStoreTests: XCTestCase {
    @MainActor
    func testFolderMoveToMissingDestinationPreservesWorkspace() async throws {
        let (store, _) = try makeStore()
        let folder = sourceFolder()
        store.workspace = GeoWorkspace(folders: [folder])
        store.selection = .folder(folder.id)
        let original = store.workspace

        store.moveSelection(to: UUID())

        XCTAssertEqual(store.workspace, original)
    }

    @MainActor
    func testFeatureMoveToMissingDestinationPreservesWorkspace() async throws {
        let (store, _) = try makeStore()
        let folder = sourceFolder()
        store.workspace = GeoWorkspace(folders: [folder])
        store.selection = .feature(folder.features[0].id)
        let original = store.workspace

        store.moveSelection(to: UUID())

        XCTAssertEqual(store.workspace, original)
    }

    @MainActor
    func testFolderCannotMoveIntoItsDescendant() async throws {
        let (store, _) = try makeStore()
        let folder = sourceFolder()
        store.workspace = GeoWorkspace(folders: [folder])
        store.selection = .folder(folder.id)
        let original = store.workspace

        store.moveSelection(to: folder.children[0].id)

        XCTAssertEqual(store.workspace, original)
    }

    @MainActor
    func testFeatureMovePreservesItsData() async throws {
        let (store, _) = try makeStore()
        let source = sourceFolder()
        let destination = GeoFolder(name: "Destination")
        let feature = source.features[0]
        store.workspace = GeoWorkspace(folders: [source, destination])
        store.selection = .feature(feature.id)

        store.moveSelection(to: destination.id)

        XCTAssertEqual(store.workspace.folders[1].features, [feature])
    }

    @MainActor
    func testFeatureMoveRemovesTheOriginalEntry() async throws {
        let (store, _) = try makeStore()
        let source = sourceFolder()
        let destination = GeoFolder(name: "Destination")
        store.workspace = GeoWorkspace(folders: [source, destination])
        store.selection = .feature(source.features[0].id)

        store.moveSelection(to: destination.id)

        XCTAssertTrue(store.workspace.folders[0].features.isEmpty)
    }

    @MainActor
    func testFeatureMovePreservesSelection() async throws {
        let (store, _) = try makeStore()
        let source = sourceFolder()
        let destination = GeoFolder(name: "Destination")
        let selection = PlaceSelection.feature(source.features[0].id)
        store.workspace = GeoWorkspace(folders: [source, destination])
        store.selection = selection

        store.moveSelection(to: destination.id)

        XCTAssertEqual(store.selection, selection)
    }

    @MainActor
    func testHiddenParentHidesNestedFeatures() async throws {
        let (store, _) = try makeStore()
        let folder = sourceFolder()
        store.workspace = GeoWorkspace(folders: [folder])

        store.toggleFolder(folder.id)

        XCTAssertTrue(store.visibleFeatures.isEmpty)
    }

    @MainActor
    func testHiddenFeatureDoesNotHideItsSibling() async throws {
        let (store, _) = try makeStore()
        let folder = sourceFolder()
        store.workspace = GeoWorkspace(folders: [folder])

        store.toggleFeature(folder.features[0].id)

        XCTAssertEqual(store.visibleFeatures, folder.children[0].features)
    }

    @MainActor
    func testSavedWorkspaceRestoresDataAndOrganization() async throws {
        let (store, storageURL) = try makeStore()
        let folder = sourceFolder()
        store.workspace = GeoWorkspace(folders: [folder])
        store.selection = .folder(folder.id)
        store.renameSelection("Renamed survey")

        let restored = WorkspaceStore(storageURL: storageURL)

        XCTAssertEqual(restored.workspace, store.workspace)
    }

    @MainActor
    func testCorruptWorkspaceGetsRecoveryCopyBeforeSave() async throws {
        let (initialStore, storageURL) = try makeStore()
        _ = initialStore
        let original = Data("This is not a workspace.".utf8)
        try original.write(to: storageURL)
        let store = WorkspaceStore(storageURL: storageURL)

        store.addFolder()

        let files = try FileManager.default.contentsOfDirectory(
            at: storageURL.deletingLastPathComponent(), includingPropertiesForKeys: nil
        )
        let copies = try files.filter { $0.lastPathComponent.hasPrefix("workspace-recovery-") }
            .map { try Data(contentsOf: $0) }
        XCTAssertEqual(copies, [original])
    }

    @MainActor
    func testRecoverySaveCreatesAReadableWorkspace() async throws {
        let (_, storageURL) = try makeStore()
        try Data("Invalid data".utf8).write(to: storageURL)
        let store = WorkspaceStore(storageURL: storageURL)

        store.addFolder()

        let saved = try JSONDecoder().decode(GeoWorkspace.self, from: Data(contentsOf: storageURL))
        XCTAssertEqual(saved, store.workspace)
    }

    @MainActor
    func testRepeatedImportsHaveDistinctInternalIdentities() async throws {
        let (store, _) = try makeStore()
        let source = sourceFolder()

        let first = store.importedCopy(of: source)
        let second = store.importedCopy(of: source)

        let identifiers = [first.id, first.children[0].id, second.id, second.children[0].id]
            + first.allFeatures.map(\.id) + second.allFeatures.map(\.id)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    @MainActor
    func testImportedCopyPreservesSourceIdentifiers() async throws {
        let (store, _) = try makeStore()
        let source = sourceFolder()

        let copy = store.importedCopy(of: source)

        XCTAssertEqual(copy.allFeatures.map(\.sourceID), source.allFeatures.map(\.sourceID))
    }

    @MainActor
    func testImportedCopyPreservesProperties() async throws {
        let (store, _) = try makeStore()
        let source = sourceFolder()

        let copy = store.importedCopy(of: source)

        XCTAssertEqual(copy.allFeatures.map(\.properties), source.allFeatures.map(\.properties))
    }

    @MainActor
    func testImportedCopyPreservesStyles() async throws {
        let (store, _) = try makeStore()
        let source = sourceFolder()

        let copy = store.importedCopy(of: source)

        XCTAssertEqual(copy.allFeatures.map(\.style), source.allFeatures.map(\.style))
    }

    @MainActor
    private func makeStore() throws -> (WorkspaceStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeobraStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("workspace.geobra")
        return (WorkspaceStore(storageURL: storageURL), storageURL)
    }

    private func sourceFolder() -> GeoFolder {
        GeoFolder(name: "Source survey", children: [
            GeoFolder(name: "Observations", features: [
                GeoFeature(
                    name: "Observation",
                    geometry: .point(Coordinate(longitude: -43.2, latitude: -22.9)),
                    properties: ["status": .string("Draft")],
                    style: FeatureStyle(colorHex: "#E7B86A", fillOpacity: 0.4, lineWidth: 3),
                    sourceID: .string("observation-17")
                )
            ])
        ], features: [
            GeoFeature(
                name: "Survey route",
                geometry: .lineString([
                    Coordinate(longitude: -43.3, latitude: -22.9),
                    Coordinate(longitude: -43.2, latitude: -22.8)
                ]),
                properties: ["owner": .string("Field team"), "checked": .bool(false)],
                style: FeatureStyle(colorHex: "#76C8A6", fillOpacity: 0.3, lineWidth: 2),
                sourceID: .string("route-8")
            )
        ])
    }
}
