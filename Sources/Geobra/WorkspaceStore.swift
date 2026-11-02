import AppKit
import GeobraCore
import Observation
import UniformTypeIdentifiers

enum PlaceSelection: Hashable {
    case folder(UUID)
    case feature(UUID)
}

@MainActor @Observable
final class WorkspaceStore {
    var workspace = GeoWorkspace(folders: [])
    var selection: PlaceSelection?
    var search = ""
    var isImporting = false
    var errorMessage: String?
    var status = "Ready to explore"
    var showInspector = true
    var focusID: UUID?
    var focusGeometry: GeoGeometry?
    var focusRevision = 0
    var resetRevision = 0
    var zoomRevision = 0
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
        return workspace.folders.lazy.flatMap(\.allFeatures).first { $0.id == id }
    }

    var selectedFolder: GeoFolder? {
        guard case let .folder(id) = selection else { return nil }
        return findFolder(id, in: workspace.folders)
    }

    var selectedID: UUID? { selectedFeature?.id }
    var featureCount: Int { workspace.folders.reduce(0) { $0 + $1.featureCount } }
    var folderCount: Int { folderOptions.count }
    var visibleFeatures: [GeoFeature] { workspace.folders.flatMap { visibleFeatures(in: $0) } }
    var folderOptions: [(id: UUID, name: String)] { workspace.folders.flatMap { folderOptions(in: $0, prefix: "") } }

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
            workspace.folders.append(contentsOf: imported)
            if let first = imported.first {
                selection = .folder(first.id)
                focusGeometry = .geometryCollection(first.allFeatures.compactMap(\.geometry))
                focusRevision += 1
                persist()
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
                workspace.folders.append(folder)
                selection = .folder(folder.id)
                focusSelection()
                persist()
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
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let opened = try JSONDecoder().decode(GeoWorkspace.self, from: Data(contentsOf: url))
            guard persist() else { return }
            workspace = opened
            selection = nil
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
        let folder: GeoFolder
        if let selectedFolder { folder = selectedFolder }
        else if let feature = selectedFeature { folder = GeoFolder(name: feature.name, features: [feature]) }
        else { folder = GeoFolder(name: "My Places", children: workspace.folders) }
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
        if case let .folder(parentID) = selection {
            updateFolder(parentID) { $0.children.append(folder) }
        } else { workspace.folders.append(folder) }
        selection = .folder(folder.id)
        persist()
    }

    func renameSelection(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if case let .folder(id) = selection { updateFolder(id) { $0.name = name } }
        if case let .feature(id) = selection { updateFeature(id) { $0.name = name } }
        persist()
    }

    func toggleFolder(_ id: UUID) {
        updateFolder(id) { $0.isVisible.toggle() }
        persist()
    }

    func toggleFeature(_ id: UUID) {
        updateFeature(id) { $0.isVisible.toggle() }
        persist()
    }

    func setColor(_ hex: String) {
        guard let id = selectedID else { return }
        updateFeature(id) { $0.style.colorHex = hex }
        persist()
    }

    func deleteSelection() {
        guard let selection else { return }
        workspace.folders = removing(selection, from: workspace.folders)
        self.selection = nil
        persist()
    }

    func moveSelection(to folderID: UUID?) {
        guard let selection else { return }
        if let folderID, findFolder(folderID, in: workspace.folders) == nil { return }
        switch selection {
        case .folder(let id):
            guard let folder = findFolder(id, in: workspace.folders), folderID != id else { return }
            if let folderID, findFolder(folderID, in: folder.children) != nil { return }
            workspace.folders = removing(selection, from: workspace.folders)
            if let folderID { updateFolder(folderID) { $0.children.append(folder) } }
            else { workspace.folders.append(folder) }
        case .feature:
            guard let folderID, let feature = selectedFeature else { return }
            workspace.folders = removing(selection, from: workspace.folders)
            updateFolder(folderID) { $0.features.append(feature) }
        }
        persist()
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
        focusID = selectedFeature?.id ?? selectedFolder?.allFeatures.first?.id
        focusGeometry = selectedFeature?.geometry
            ?? selectedFolder.map { .geometryCollection($0.allFeatures.compactMap(\.geometry)) }
        focusRevision += 1
    }

    func resetGlobe() { resetRevision += 1 }

    func loadSample() {
        let folder = SampleWorkspace.folder()
        workspace.folders.append(folder)
        selection = .folder(folder.id)
        focusID = folder.allFeatures.first?.id
        focusGeometry = .geometryCollection(folder.allFeatures.compactMap(\.geometry))
        focusRevision += 1
        status = "Opened the sample project"
        persist()
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

    private func removing(_ selection: PlaceSelection, from folders: [GeoFolder]) -> [GeoFolder] {
        folders.compactMap { folder in
            if selection == .folder(folder.id) { return nil }
            var folder = folder
            folder.features.removeAll { selection == .feature($0.id) }
            folder.children = removing(selection, from: folder.children)
            return folder
        }
    }
}
