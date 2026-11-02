import AppKit
import GeobraCore
import SwiftUI

struct WorkspaceView: View {
    @Bindable var store: WorkspaceStore
    @Bindable var maps: MapSettings
    @Environment(\.undoManager) private var undoManager
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isDropTargeted = false
    @State private var showsDataSourceSheet = false
    @State private var mapStatus = "Loading map…"
    @State private var mapAttribution = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            globe
                .navigationTitle("Geobra")
                .navigationSubtitle(store.selections.count > 1
                                    ? "\(store.selections.count) places selected"
                                    : store.selectedFeature?.name ?? store.selectedFolder?.name ?? "My Places")
                .toolbar { workspaceToolbar }
        }
        .inspector(isPresented: $store.showInspector) {
            InspectorView(store: store)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .onAppear { store.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in store.undoManager = manager }
        .sheet(isPresented: $showsDataSourceSheet) {
            AddDataSourceView(store: store)
        }
        .onChange(of: maps.source) { _, _ in
            mapAttribution = ""
            mapStatus = maps.needsGoogleKey ? "Configure a Google Maps API key in Settings." : "Loading map…"
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importURLs(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .alert("Geobra", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if store.workspace.folders.isEmpty {
                ContentUnavailableView {
                    Label("My Places", systemImage: "folder")
                } description: {
                    Text("Import geographic files to organize your places.")
                } actions: {
                    Button("Import Files…", action: store.chooseImport)
                        .disabled(store.isImporting)
                    Button("Open Sample Project", action: store.loadSample)
                }
            } else {
                PlacesOutlineView(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $store.search, placement: .sidebar, prompt: "Filter Places")
        .overlay {
            if !store.search.isEmpty && !store.workspace.folders.contains(where: { matches($0, query: store.search) }) {
                ContentUnavailableView.search(text: store.search)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text(store.selections.isEmpty
                     ? "\(store.featureCount) features"
                     : "\(store.selections.count) selected")
                Spacer()
                Menu {
                    Button("New Folder", action: store.addFolder)
                    Button("New Folder with Selection", action: store.groupSelection)
                        .disabled(store.selections.isEmpty)
                    Divider()
                    Button("Export GeoJSON…", action: store.exportGeoJSON)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Place actions")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle("My Places")
    }

    private var globe: some View {
        GlobeView(
            features: store.visibleFeatures,
            selectedID: store.selectedID,
            selectedIDs: store.selectedFeatureIDs,
            focusID: store.focusID,
            focusGeometry: store.focusGeometry,
            focusRevision: store.focusRevision,
            resetRevision: store.resetRevision,
            zoomRevision: store.zoomRevision,
            mapConfiguration: maps.configuration,
            onSelect: { id in
                if NSEvent.modifierFlags.contains(.command) {
                    if let id {
                        let item = PlaceSelection.feature(id)
                        if store.selections.contains(item) { store.selections.remove(item) }
                        else { store.selections.insert(item) }
                    }
                } else {
                    store.selection = id.map(PlaceSelection.feature)
                }
            },
            onMapStatus: { mapStatus = $0 },
            onMapAttribution: { mapAttribution = $0.text }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Interactive globe")
        .accessibilityHint("Drag to rotate. Scroll to zoom. Select a feature to inspect it.")
        .overlay {
            if maps.isBasemapVisible && maps.needsGoogleKey {
                ContentUnavailableView {
                    Label("Configure Google Maps", systemImage: "key")
                } description: {
                    Text("Add a Google Maps Tile API key in Source Settings, or select OpenStreetMap.")
                } actions: {
                    SettingsLink { Text("Source Settings…") }
                    Button("Use OpenStreetMap") { maps.source = .openStreetMap }
                }
                .padding()
                .background(.regularMaterial)
            } else if store.isImporting {
                ProgressView("Importing geographic files…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(maps.isBasemapVisible ? mapStatus : "Basemap hidden").lineLimit(1)
                        .help(mapStatus)
                    Spacer()
                    Text("\(store.visibleFeatures.count) data features visible")
                }
                MapAttributionView(source: maps.source, isVisible: maps.isBasemapVisible, text: mapAttribution)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.bar)
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Import Files…", action: store.chooseImport)
                Button("Add GeoJSON URL…") { showsDataSourceSheet = true }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .disabled(store.isImporting)
            .help("Import KML, KMZ, or GeoJSON (⌘I)")
            Button(action: store.addFolder) {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("Create a folder (⇧⌘N)")
            Button(action: store.focusSelection) {
                Label("Show Selection", systemImage: "scope")
            }
            .disabled(store.selectedFeatureIDs.isEmpty)
            .help("Show the selected places on the globe (⌘J)")
        }
        ToolbarItem {
            Menu {
                Picker("Source", selection: $maps.source) {
                    ForEach(MapSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Divider()
                Toggle("Show Basemap", isOn: $maps.isBasemapVisible)
                Toggle("Show Coordinate Grid", isOn: $maps.showsGrid)
                Divider()
                Button("Reload Map", action: maps.reloadMap)
                    .keyboardShortcut("r", modifiers: .command)
                SettingsLink { Text("Source Settings…") }
            } label: {
                Label(maps.source.displayName, systemImage: "map")
            }
            .help("Map source and reference layers")
        }
        ToolbarItemGroup {
            Button { store.zoomRevision -= 1 } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            Button { store.zoomRevision += 1 } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            Button(action: store.resetGlobe) {
                Label("Reset Globe", systemImage: "globe")
            }
            .help("Reset globe (⌘0)")
        }
        ToolbarItem {
            Button { store.showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide the inspector")
        }
    }
}

private func matches(_ folder: GeoFolder, query: String) -> Bool {
    query.isEmpty || folder.name.localizedCaseInsensitiveContains(query)
        || folder.features.contains { $0.name.localizedCaseInsensitiveContains(query) }
        || folder.children.contains { matches($0, query: query) }
}
