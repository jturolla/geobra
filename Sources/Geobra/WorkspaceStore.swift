import AppKit
import GeobraCore
import Observation
import UniformTypeIdentifiers

enum PlaceSelection: Hashable, Codable, Sendable {
    case folder(UUID)
    case feature(UUID)
}

@MainActor @Observable
final class WorkspaceStore {
    var workspace = GeoWorkspace(folders: [])
    var selections: Set<PlaceSelection> = []
    var selection: PlaceSelection? {
        get { selections.count == 1 ? selections.first : nil }
        set { selections = newValue.map { Set([$0]) } ?? [] }
    }
    var renameRequest: PlaceSelection?
    var search = ""
    var isImporting = false
    var errorMessage: String?
    var status = "Ready to explore"
    var showInspector = false
    var focusID: UUID?
    var focusGeometry: GeoGeometry?
    var focusRevision = 0
    var resetRevision = 0
    var zoomRevision = 0
    @ObservationIgnored weak var undoManager: UndoManager?
    private let storageURL: URL
    private var needsRecoveryCopy = false

    init(storageURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageURL = storageURL ?? support.appendingPathComponent("Geobra/workspace.geobra")
        guard FileManager.default.fileExists(atPath: self.storageURL.path) else { return }
        do {
            workspace = try JSONDecoder().decode(GeoWorkspace.self, from: Data(contentsOf: self.storageURL))
            status = "Workspace restored"
        } catch {
            needsRecoveryCopy = true
            errorMessage = "Geobra could not read the saved workspace. It will preserve a recovery copy before saving changes. \(error.localizedDescription)"
        }
    }

    var selectedFeature: GeoFeature? {
        guard case let .feature(id) = selection else { return nil }
        return findFeature(id)
    }

    var selectedFolder: GeoFolder? {
        guard case let .folder(id) = selection else { return nil }
        return findFolder(id, in: workspace.folders)
    }

    var selectedID: UUID? { selectedFeature?.id }
    var selectedFeatureIDs: Set<UUID> { Set(selectedFeatures.map(\.id)) }
    var featureCount: Int { workspace.folders.reduce(0) { $0 + $1.featureCount } }
    var folderCount: Int { folderOptions.count }
    var visibleFeatures: [GeoFeature] { workspace.folders.flatMap { visibleFeatures(in: $0) } }
    var folderOptions: [(id: UUID, name: String)] { workspace.folders.flatMap { folderOptions(in: $0, prefix: "") } }

    var exportSelectionFolder: GeoFolder {
        let places = normalizedPlaces(selections)
        if places.count == 1 {
            switch places[0].content {
            case .folder(let folder): return folder
            case .feature(let feature): return GeoFolder(name: feature.name, features: [feature])
            }
        }
        if places.isEmpty { return GeoFolder(name: "My Places", children: workspace.folders) }
        return GeoFolder(name: "Selected Places", children: places.compactMap(\.folder), features: places.compactMap(\.feature))
    }

    func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Geographic Files"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["kml", "kmz", "geojson", "json"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }

    func importURLs(_ urls: [URL]) {
        guard !isImporting, !urls.isEmpty else { return }
        isImporting = true
        status = "Importing \(urls.count) file\(urls.count == 1 ? "" : "s")…"
        Task {
            var imported: [GeoFolder] = []
            var failures: [String] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                do {
                    let folder = try await Task.detached(priority: .userInitiated) {
                        try GeoImporter.importFile(at: url)
                    }.value
                    imported.append(importedCopy(of: folder))
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                if access { url.stopAccessingSecurityScopedResource() }
            }
            if !imported.isEmpty {
                edit("Import Files") {
                    workspace.folders.append(contentsOf: imported)
                    selections = Set(imported.map { .folder($0.id) })
                }
                focusSelection()
            }
            isImporting = false
            status = "Imported \(imported.reduce(0) { $0 + $1.featureCount }) features"
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
        }
    }

    func importRemoteGeoJSON(from url: URL) {
        guard !isImporting else { return }
        isImporting = true
        status = "Loading the GeoJSON data source…"
        Task {
            defer { isImporting = false }
            do {
                let loaded = try await RemoteGeoJSON.load(from: url)
                let folder = importedCopy(of: loaded)
                edit("Import Data Source") {
                    workspace.folders.append(folder)
                    selection = .folder(folder.id)
                }
                focusSelection()
                status = "Loaded \(folder.featureCount) features from the data source"
            } catch {
                errorMessage = error.localizedDescription
                status = "The data source could not load"
            }
        }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Open Workspace"
        panel.allowedContentTypes = [UTType(filenameExtension: "geobra") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWorkspace(at: url)
    }

    func openURL(_ url: URL) {
        if url.pathExtension.lowercased() == "geobra" { openWorkspace(at: url) }
        else { importURLs([url]) }
    }

    private func openWorkspace(at url: URL) {
        guard !isImporting else {
            errorMessage = "Wait for the current import to finish before opening another workspace."
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let opened = try JSONDecoder().decode(GeoWorkspace.self, from: Data(contentsOf: url))
            guard persist() else { return }
            workspace = opened
            selections = []
            renameRequest = nil
            undoManager?.removeAllActions()
            persist()
            status = "Opened \(url.lastPathComponent)"
        } catch { errorMessage = error.localizedDescription }
    }

    func saveWorkspaceAs() {
        let panel = NSSavePanel()
        panel.title = "Save Workspace"
        panel.nameFieldStringValue = "My Places.geobra"
        panel.allowedContentTypes = [UTType(filenameExtension: "geobra") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try workspaceData().write(to: url, options: .atomic)
            status = "Saved \(url.lastPathComponent)"
        } catch { errorMessage = error.localizedDescription }
    }

    func exportGeoJSON() {
        let folder = exportSelectionFolder
        let panel = NSSavePanel()
        panel.title = "Export GeoJSON"
        panel.nameFieldStringValue = "\(folder.name).geojson"
        panel.allowedContentTypes = [UTType(filenameExtension: "geojson") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try GeoJSONCodec.encode(folder: folder).write(to: url, options: .atomic)
            status = "Exported \(folder.featureCount) features"
        } catch { errorMessage = error.localizedDescription }
    }

    func addFolder() {
        let folder = GeoFolder(name: "Untitled Folder")
        let parentID = selectedFolder?.id
        edit("Add Folder") {
            if let parentID { updateFolder(parentID) { $0.children.append(folder) } }
            else { workspace.folders.append(folder) }
            selection = .folder(folder.id)
        }
        renameRequest = .folder(folder.id)
    }

    func requestRename() {
        guard let selection else { return }
        renameRequest = selection
    }

    func renameSelection(_ name: String) {
        guard let selection else { return }
        rename(selection, to: name)
    }

    func rename(_ item: PlaceSelection, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        edit("Rename Place") {
            switch item {
            case .folder(let id): updateFolder(id) { $0.name = name }
            case .feature(let id): updateFeature(id) { $0.name = name }
            }
        }
        if renameRequest == item { renameRequest = nil }
    }

    func toggleFolder(_ id: UUID) {
        edit("Change Visibility") { updateFolder(id) { $0.isVisible.toggle() } }
    }

    func toggleFeature(_ id: UUID) {
        edit("Change Visibility") { updateFeature(id) { $0.isVisible.toggle() } }
    }

    func setSelectedVisibility(_ visible: Bool) {
        let places = normalizedPlaces(selections)
        edit("Change Visibility") {
            for place in places {
                switch place.content {
                case .folder(let folder): updateFolder(folder.id) { $0.isVisible = visible }
                case .feature(let feature): updateFeature(feature.id) { $0.isVisible = visible }
                }
            }
        }
    }

    func setColor(_ hex: String) {
        let featureIDs = selectedFeatureIDs
        edit("Change Color") {
            for id in featureIDs { updateFeature(id) { $0.style.colorHex = hex } }
        }
    }

    func deleteSelection() { deleteSelections() }

    func deleteSelections() {
        let items = Set(normalizedPlaces(selections).map(\.selection))
        guard !items.isEmpty else { return }
        edit("Delete Places") {
            workspace.folders = removing(items, from: workspace.folders)
            selections = []
            renameRequest = nil
        }
    }

    func moveSelection(to folderID: UUID?) { move(selections, to: folderID) }

    func canMove(_ items: Set<PlaceSelection>, to folderID: UUID?) -> Bool {
        let places = allPlaces()
        let existing = Set(places.map(\.selection))
        guard !items.isEmpty, items.isSubset(of: existing) else { return false }
        let normalized = normalizedPlaces(items, in: places)
        if let folderID {
            guard let destination = places.first(where: { $0.selection == .folder(folderID) }) else { return false }
            return normalized.allSatisfy { place in
                guard case .folder(let folder) = place.content else { return true }
                return folder.id != folderID && !destination.ancestors.contains(folder.id)
            }
        }
        return normalized.allSatisfy { $0.folder != nil }
    }

    func move(_ items: Set<PlaceSelection>, to folderID: UUID?, at index: Int? = nil) {
        guard canMove(items, to: folderID) else { return }
        let places = normalizedPlaces(items)
        let indexes = insertionIndexes(for: places, in: folderID, at: index)
        edit("Move Places") {
            workspace.folders = removing(Set(places.map(\.selection)), from: workspace.folders)
            insert(places, into: folderID, at: indexes)
            selections = Set(places.map(\.selection))
        }
    }

    func groupSelection() {
        let places = normalizedPlaces(selections)
        guard !places.isEmpty else { return }
        let firstParent = places[0].parentID
        let parentID = places.allSatisfy { $0.parentID == firstParent } ? firstParent : nil
        let firstIndex = places.filter { $0.parentID == parentID }.map(\.index).min()
        let indexes = insertionIndexes(for: places, in: parentID, at: firstIndex)
        let folder = GeoFolder(name: "Untitled Folder", children: places.compactMap(\.folder), features: places.compactMap(\.feature))
        edit("Group Places") {
            workspace.folders = removing(Set(places.map(\.selection)), from: workspace.folders)
            if let parentID {
                updateFolder(parentID) {
                    $0.children.insert(folder, at: min(indexes.folders ?? $0.children.count, $0.children.count))
                }
            } else {
                workspace.folders.insert(folder, at: min(indexes.folders ?? workspace.folders.count, workspace.folders.count))
            }
            selection = .folder(folder.id)
        }
        renameRequest = .folder(folder.id)
    }

    func importedCopy(of source: GeoFolder) -> GeoFolder {
        var folder = source
        folder.id = UUID()
        folder.features = source.features.map { feature in
            var feature = feature
            feature.id = UUID()
            return feature
        }
        folder.children = source.children.map { importedCopy(of: $0) }
        return folder
    }

    func focusSelection() {
        let geometries = selectedFeatures.compactMap(\.geometry)
        guard !geometries.isEmpty else { return }
        focusID = selectedFeature?.id
        focusGeometry = geometries.count == 1 ? geometries[0] : .geometryCollection(geometries)
        focusRevision += 1
    }

    func resetGlobe() { resetRevision += 1 }

    func loadSample() {
        let folder = SampleWorkspace.folder()
        edit("Add Sample Project") {
            workspace.folders.append(folder)
            selection = .folder(folder.id)
        }
        focusSelection()
        status = "Opened the sample project"
    }

    private var selectedFeatures: [GeoFeature] {
        normalizedPlaces(selections).flatMap { place in
            switch place.content {
            case .folder(let folder): return folder.allFeatures
            case .feature(let feature): return [feature]
            }
        }
    }

    private func edit(_ actionName: String, change: () -> Void) {
        let before = Snapshot(workspace: workspace, selections: selections)
        change()
        guard workspace != before.workspace else { return }
        registerUndo(before, actionName: actionName)
        persist()
    }

    private func restore(_ snapshot: Snapshot, actionName: String) {
        let inverse = Snapshot(workspace: workspace, selections: selections)
        workspace = snapshot.workspace
        selections = snapshot.selections
        renameRequest = nil
        registerUndo(inverse, actionName: actionName)
        persist()
    }

    private func registerUndo(_ snapshot: Snapshot, actionName: String) {
        guard let undoManager else { return }
        let startsGroup = undoManager.groupingLevel == 0 && !undoManager.isUndoing && !undoManager.isRedoing
        if startsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(snapshot, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        if startsGroup { undoManager.endUndoGrouping() }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if needsRecoveryCopy {
                let recovery = storageURL.deletingLastPathComponent().appendingPathComponent("workspace-recovery-\(UUID().uuidString).geobra")
                try FileManager.default.copyItem(at: storageURL, to: recovery)
                needsRecoveryCopy = false
            }
            try workspaceData().write(to: storageURL, options: .atomic)
            return true
        } catch {
            errorMessage = "Geobra could not save the workspace. \(error.localizedDescription)"
            return false
        }
    }

    private func workspaceData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(workspace)
    }

    private func allPlaces() -> [LocatedPlace] {
        func descendants(_ folder: GeoFolder, parentID: UUID?, index: Int, ancestors: Set<UUID>) -> [LocatedPlace] {
            let place = LocatedPlace(content: .folder(folder), parentID: parentID, index: index, ancestors: ancestors)
            let childAncestors = ancestors.union([folder.id])
            let children = folder.children.enumerated().flatMap {
                descendants($0.element, parentID: folder.id, index: $0.offset, ancestors: childAncestors)
            }
            let features = folder.features.enumerated().map {
                LocatedPlace(content: .feature($0.element), parentID: folder.id,
                             index: folder.children.count + $0.offset, ancestors: childAncestors)
            }
            return [place] + children + features
        }
        return workspace.folders.enumerated().flatMap {
            descendants($0.element, parentID: nil, index: $0.offset, ancestors: [])
        }
    }

    private func normalizedPlaces(_ items: Set<PlaceSelection>, in places: [LocatedPlace]? = nil) -> [LocatedPlace] {
        let selectedFolders = Set(items.compactMap { item -> UUID? in
            guard case .folder(let id) = item else { return nil }
            return id
        })
        return (places ?? allPlaces()).filter {
            items.contains($0.selection) && $0.ancestors.isDisjoint(with: selectedFolders)
        }
    }

    private func insertionIndexes(for places: [LocatedPlace], in folderID: UUID?, at index: Int?) -> InsertionIndexes {
        guard let index else { return InsertionIndexes(folders: nil, features: nil) }
        let destination = folderID.flatMap { findFolder($0, in: workspace.folders) }
        let folderCount = destination?.children.count ?? workspace.folders.count
        let featureCount = destination?.features.count ?? 0
        let position = max(0, min(index, folderCount + featureCount))
        let folderPosition = min(position, folderCount)
        let featurePosition = max(0, position - folderCount)
        let direct = places.filter { $0.parentID == folderID }
        let removedFolders = direct.filter { $0.folder != nil && $0.index < folderPosition }.count
        let removedFeatures = direct.filter { $0.feature != nil && $0.index < folderCount + featurePosition }.count
        return InsertionIndexes(folders: folderPosition - removedFolders, features: featurePosition - removedFeatures)
    }

    private func insert(_ places: [LocatedPlace], into folderID: UUID?, at indexes: InsertionIndexes) {
        let folders = places.compactMap(\.folder)
        let features = places.compactMap(\.feature)
        if let folderID {
            updateFolder(folderID) {
                $0.children.insert(contentsOf: folders, at: min(indexes.folders ?? $0.children.count, $0.children.count))
                $0.features.insert(contentsOf: features, at: min(indexes.features ?? $0.features.count, $0.features.count))
            }
        } else {
            workspace.folders.insert(contentsOf: folders, at: min(indexes.folders ?? workspace.folders.count, workspace.folders.count))
        }
    }

    private func visibleFeatures(in folder: GeoFolder) -> [GeoFeature] {
        guard folder.isVisible else { return [] }
        return folder.features.filter(\.isVisible) + folder.children.flatMap { visibleFeatures(in: $0) }
    }

    private func folderOptions(in folder: GeoFolder, prefix: String) -> [(id: UUID, name: String)] {
        let path = prefix.isEmpty ? folder.name : "\(prefix) / \(folder.name)"
        return [(folder.id, path)] + folder.children.flatMap { folderOptions(in: $0, prefix: path) }
    }

    private func findFolder(_ id: UUID, in folders: [GeoFolder]) -> GeoFolder? {
        for folder in folders {
            if folder.id == id { return folder }
            if let found = findFolder(id, in: folder.children) { return found }
        }
        return nil
    }

    private func findFeature(_ id: UUID) -> GeoFeature? {
        workspace.folders.lazy.flatMap(\.allFeatures).first { $0.id == id }
    }

    private func updateFolder(_ id: UUID, _ change: (inout GeoFolder) -> Void) {
        func update(_ folders: inout [GeoFolder]) {
            for index in folders.indices {
                if folders[index].id == id { change(&folders[index]); return }
                update(&folders[index].children)
            }
        }
        update(&workspace.folders)
    }

    private func updateFeature(_ id: UUID, _ change: (inout GeoFeature) -> Void) {
        func update(_ folders: inout [GeoFolder]) {
            for index in folders.indices {
                if let featureIndex = folders[index].features.firstIndex(where: { $0.id == id }) {
                    change(&folders[index].features[featureIndex])
                    return
                }
                update(&folders[index].children)
            }
        }
        update(&workspace.folders)
    }

    private func removing(_ items: Set<PlaceSelection>, from folders: [GeoFolder]) -> [GeoFolder] {
        folders.compactMap { folder in
            if items.contains(.folder(folder.id)) { return nil }
            var folder = folder
            folder.features.removeAll { items.contains(.feature($0.id)) }
            folder.children = removing(items, from: folder.children)
            return folder
        }
    }

    private struct Snapshot: Sendable {
        let workspace: GeoWorkspace
        let selections: Set<PlaceSelection>
    }

    private struct InsertionIndexes {
        let folders: Int?
        let features: Int?
    }

    private struct LocatedPlace {
        let content: PlaceContent
        let parentID: UUID?
        let index: Int
        let ancestors: Set<UUID>

        var selection: PlaceSelection {
            switch content {
            case .folder(let folder): return .folder(folder.id)
            case .feature(let feature): return .feature(feature.id)
            }
        }

        var folder: GeoFolder? {
            guard case .folder(let folder) = content else { return nil }
            return folder
        }

        var feature: GeoFeature? {
            guard case .feature(let feature) = content else { return nil }
            return feature
        }
    }

    private enum PlaceContent {
        case folder(GeoFolder)
        case feature(GeoFeature)
    }
}
