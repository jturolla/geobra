import Foundation
import GeobraCore
import XCTest
@testable import Geobra

final class WorkspaceOrganizationTests: XCTestCase {
    @MainActor
    func testBatchMoveUsesTreeOrderInsteadOfSelectionOrder() async throws {
        let context = try makeContext()
        let source = context.source
        let items: Set<PlaceSelection> = [.feature(source.features[2].id), .feature(source.features[0].id)]

        context.store.move(items, to: context.destination.id)

        XCTAssertEqual(context.store.workspace.folders[1].features, [source.features[0], source.features[2]])
    }

    @MainActor
    func testBatchMoveRemovesOnlyTheMovedFeatures() async throws {
        let context = try makeContext()
        let source = context.source

        context.store.move([.feature(source.features[0].id), .feature(source.features[2].id)], to: context.destination.id)

        XCTAssertEqual(context.store.workspace.folders[0].features, [source.features[1]])
    }

    @MainActor
    func testAncestorSelectionDoesNotMoveItsFeatureTwice() async throws {
        let context = try makeContext()
        let source = context.source
        let nestedFeature = source.children[0].features[0]

        context.store.move([.folder(source.id), .feature(nestedFeature.id)], to: context.destination.id)

        XCTAssertEqual(context.store.workspace.folders[0].children, [source])
    }

    @MainActor
    func testBatchMoveRejectsTheEntireOperationWhenAnItemIsMissing() async throws {
        let context = try makeContext()
        let original = context.store.workspace

        context.store.move([.feature(context.source.features[0].id), .feature(UUID())], to: context.destination.id)

        XCTAssertEqual(context.store.workspace, original)
    }

    @MainActor
    func testMoveRejectsAnAncestorAndItsDescendantDestination() async throws {
        let context = try makeContext()

        let allowed = context.store.canMove([.folder(context.source.id)], to: context.source.children[0].id)

        XCTAssertFalse(allowed)
    }

    @MainActor
    func testRootDropRejectsLooseFeatures() async throws {
        let context = try makeContext()

        let allowed = context.store.canMove([.feature(context.source.features[0].id)], to: nil)

        XCTAssertFalse(allowed)
    }

    @MainActor
    func testInvalidMoveCreatesNoUndoEntry() async throws {
        let context = try makeContext()

        context.store.move([.folder(context.source.id)], to: context.source.children[0].id)

        XCTAssertFalse(context.undo.canUndo)
    }

    @MainActor
    func testSameFolderMovePlacesFeatureAfterItsSiblings() async throws {
        let context = try makeContext()
        let source = context.source
        let endIndex = source.children.count + source.features.count

        context.store.move([.feature(source.features[0].id)], to: source.id, at: endIndex)

        XCTAssertEqual(context.store.workspace.folders[0].features.map(\.id),
                       [source.features[1].id, source.features[2].id, source.features[0].id])
    }

    @MainActor
    func testSameFolderMovePlacesFeatureBeforeItsSiblings() async throws {
        let context = try makeContext()
        let source = context.source

        context.store.move([.feature(source.features[2].id)], to: source.id, at: source.children.count)

        XCTAssertEqual(context.store.workspace.folders[0].features.map(\.id),
                       [source.features[2].id, source.features[0].id, source.features[1].id])
    }

    @MainActor
    func testUnchangedOrderCreatesNoUndoEntry() async throws {
        let context = try makeContext()
        let source = context.source

        context.store.move([.feature(source.features[0].id)], to: source.id, at: source.children.count)

        XCTAssertFalse(context.undo.canUndo)
    }

    @MainActor
    func testRootMoveReordersFolders() async throws {
        let context = try makeContext()

        context.store.move([.folder(context.destination.id)], to: nil, at: 0)

        XCTAssertEqual(context.store.workspace.folders.map(\.id), [context.destination.id, context.source.id])
    }

    @MainActor
    func testRenameUsesTheItemIdentityInsteadOfTheCurrentSelection() async throws {
        let context = try makeContext()
        context.store.selection = .folder(context.destination.id)
        let item = context.source.features[0]

        context.store.rename(.feature(item.id), to: "Updated boundary")

        XCTAssertEqual(context.store.workspace.folders[0].features[0].name, "Updated boundary")
    }

    @MainActor
    func testUnchangedNameCreatesNoUndoEntry() async throws {
        let context = try makeContext()
        let feature = context.source.features[0]

        context.store.rename(.feature(feature.id), to: feature.name)

        XCTAssertFalse(context.undo.canUndo)
    }

    @MainActor
    func testBatchDeleteNormalizesAncestorSelection() async throws {
        let context = try makeContext()
        context.store.selections = [.folder(context.source.id), .feature(context.source.children[0].features[0].id)]

        context.store.deleteSelections()

        XCTAssertEqual(context.store.workspace.folders, [context.destination])
    }

    @MainActor
    func testUndoRestoresTheWorkspaceAfterBatchMove() async throws {
        let context = try makeContext()
        let original = context.store.workspace
        context.store.selections = [.feature(context.source.features[0].id), .feature(context.source.features[2].id)]
        context.store.move(context.store.selections, to: context.destination.id)

        context.undo.undo()

        XCTAssertEqual(context.store.workspace, original)
    }

    @MainActor
    func testUndoRestoresTheSelectionAfterBatchDelete() async throws {
        let context = try makeContext()
        let selection: Set<PlaceSelection> = [.feature(context.source.features[0].id), .folder(context.source.children[0].id)]
        context.store.selections = selection
        context.store.deleteSelections()

        context.undo.undo()

        XCTAssertEqual(context.store.selections, selection)
    }

    @MainActor
    func testRedoRestoresTheMovedData() async throws {
        let context = try makeContext()
        context.store.move([.feature(context.source.features[0].id)], to: context.destination.id)
        let moved = context.store.workspace
        context.undo.undo()

        context.undo.redo()

        XCTAssertEqual(context.store.workspace, moved)
    }

    @MainActor
    func testUndoPersistsTheRestoredWorkspace() async throws {
        let context = try makeContext()
        let original = context.store.workspace
        context.store.move([.feature(context.source.features[0].id)], to: context.destination.id)
        context.undo.undo()

        let restored = WorkspaceStore(storageURL: context.storageURL)

        XCTAssertEqual(restored.workspace, original)
    }

    @MainActor
    func testRedoPersistsTheMovedWorkspace() async throws {
        let context = try makeContext()
        context.store.move([.feature(context.source.features[0].id)], to: context.destination.id)
        let moved = context.store.workspace
        context.undo.undo()
        context.undo.redo()

        let restored = WorkspaceStore(storageURL: context.storageURL)

        XCTAssertEqual(restored.workspace, moved)
    }

    @MainActor
    func testGroupingPreservesSelectedFeatureIdentitiesAndData() async throws {
        let context = try makeContext()
        let features = [context.source.features[0], context.source.features[2]]
        context.store.selections = Set(features.map { .feature($0.id) })

        context.store.groupSelection()

        let groups = allFolders(context.store.workspace.folders).filter { $0.features == features }
        XCTAssertEqual(groups.count, 1)
    }

    @MainActor
    func testGroupingUsesOneUndoStep() async throws {
        let context = try makeContext()
        let original = context.store.workspace
        context.store.selections = [.feature(context.source.features[0].id), .feature(context.source.features[2].id)]
        context.store.groupSelection()

        context.undo.undo()

        XCTAssertEqual(context.store.workspace, original)
    }

    @MainActor
    func testBatchVisibilityUsesEverySelectedItem() async throws {
        let context = try makeContext()
        context.store.selections = [.feature(context.source.features[0].id), .folder(context.source.children[0].id)]

        context.store.setSelectedVisibility(false)

        XCTAssertEqual(Set(context.store.visibleFeatures.map(\.id)), Set(context.source.features.dropFirst().map(\.id)))
    }

    @MainActor
    func testUndoRestoresBatchVisibility() async throws {
        let context = try makeContext()
        let original = context.store.workspace
        context.store.selections = [.folder(context.source.id)]
        context.store.setSelectedVisibility(false)

        context.undo.undo()

        XCTAssertEqual(context.store.workspace, original)
    }

    @MainActor
    func testSelectedFolderIncludesItsDescendantFeatures() async throws {
        let context = try makeContext()
        context.store.selections = [.folder(context.source.id), .feature(context.source.features[0].id)]

        let selected = context.store.selectedFeatureIDs

        XCTAssertEqual(selected, Set(context.source.allFeatures.map(\.id)))
    }

    @MainActor
    func testFocusIncludesAllSelectedGeometryWithoutDuplicates() async throws {
        let context = try makeContext()
        context.store.selections = [.folder(context.source.id), .feature(context.source.children[0].features[0].id)]

        context.store.focusSelection()

        XCTAssertEqual(context.store.focusGeometry?.coordinates.count,
                       context.source.allFeatures.compactMap(\.geometry).flatMap(\.coordinates).count)
    }

    @MainActor
    private func makeContext() throws -> Context {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeobraOrganizationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("workspace.geobra")
        let store = WorkspaceStore(storageURL: storageURL)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let nested = GeoFolder(name: "Observations", features: [feature("Observation", longitude: -43.1)])
        let source = GeoFolder(name: "Survey", children: [nested], features: [
            feature("West boundary", longitude: -43.4),
            feature("Central boundary", longitude: -43.3),
            feature("East boundary", longitude: -43.2)
        ])
        let destination = GeoFolder(name: "Reviewed")
        store.workspace = GeoWorkspace(folders: [source, destination])
        return Context(store: store, undo: undo, storageURL: storageURL, source: source, destination: destination)
    }

    private func feature(_ name: String, longitude: Double) -> GeoFeature {
        GeoFeature(
            name: name,
            geometry: .point(Coordinate(longitude: longitude, latitude: -22.9)),
            properties: ["owner": .string("Field team"), "checked": .bool(false)],
            style: FeatureStyle(colorHex: "#76C8A6", fillOpacity: 0.3, lineWidth: 2),
            sourceID: .string("source-\(name)")
        )
    }

    private func allFolders(_ folders: [GeoFolder]) -> [GeoFolder] {
        folders.flatMap { [$0] + allFolders($0.children) }
    }

    @MainActor
    private struct Context {
        let store: WorkspaceStore
        let undo: UndoManager
        let storageURL: URL
        let source: GeoFolder
        let destination: GeoFolder
    }
}
