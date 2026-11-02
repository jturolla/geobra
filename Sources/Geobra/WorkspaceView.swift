import GeobraCore
import SwiftUI

struct WorkspaceView: View {
    @Bindable var store: WorkspaceStore
    @Bindable var maps: MapSettings
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
                .navigationSubtitle(store.selectedFeature?.name ?? store.selectedFolder?.name ?? "My Places")
                .toolbar { workspaceToolbar }
        }
        .inspector(isPresented: $store.showInspector) {
            InspectorView(store: store)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
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
        List(selection: $store.selection) {
            Section("Map Source") {
                Picker("Source", selection: $maps.source) {
                    ForEach(MapSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Toggle("Basemap", isOn: $maps.isBasemapVisible)
                Toggle("Coordinate Grid", isOn: $maps.showsGrid)
                SettingsLink {
                    Label("Source Settings…", systemImage: "gearshape")
                }
            }
            Section("Data Layers") {
                ForEach(store.workspace.folders) { folder in
                    FolderRow(folder: folder, store: store)
                }
                if store.workspace.folders.isEmpty {
                    Text("No data layers")
                        .foregroundStyle(.secondary)
                    Button("Open Sample Project", action: store.loadSample)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $store.search, placement: .sidebar, prompt: "Filter Places")
        .overlay {
            if !store.search.isEmpty && !store.workspace.folders.contains(where: { matches($0, query: store.search) }) {
                ContentUnavailableView.search(text: store.search)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("\(store.featureCount) features")
                Spacer()
                Image(systemName: "internaldrive")
                    .help("The workspace saves automatically on this Mac.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .background(.bar)
        }
        .navigationTitle("Places")
    }

    private var globe: some View {
        GlobeView(
            features: store.visibleFeatures,
            selectedID: store.selectedID,
            focusID: store.focusID,
            focusGeometry: store.focusGeometry,
            focusRevision: store.focusRevision,
            resetRevision: store.resetRevision,
            zoomRevision: store.zoomRevision,
            mapConfiguration: maps.configuration,
            onSelect: { store.selection = $0.map(PlaceSelection.feature) },
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
            Button(action: store.exportGeoJSON) {
                Label("Export GeoJSON", systemImage: "square.and.arrow.up")
            }
            .help("Export GeoJSON (⇧⌘E)")
        }
        ToolbarItem {
            Picker("Map Source", selection: $maps.source) {
                ForEach(MapSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .help("Select the basemap source")
        }
        ToolbarItemGroup {
            Button(action: maps.reloadMap) {
                Label("Reload Map", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Reload the map after a connection failure (⌘R)")
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

private struct FolderRow: View {
    let folder: GeoFolder
    @Bindable var store: WorkspaceStore
    @State private var isExpanded = true

    var body: some View {
        if matches(folder, query: store.search) {
            DisclosureGroup(isExpanded: Binding(
                get: { isExpanded || !store.search.isEmpty },
                set: { isExpanded = $0 }
            )) {
                ForEach(folder.children) { child in
                    FolderRow(folder: child, store: store)
                }
                ForEach(folder.features.filter { store.search.isEmpty || $0.name.localizedCaseInsensitiveContains(store.search) }) { feature in
                    placeLabel(feature.name, symbol: geometrySymbol(feature.geometry), visible: feature.isVisible) {
                        store.toggleFeature(feature.id)
                    }
                    .tag(PlaceSelection.feature(feature.id))
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        store.selection = .feature(feature.id)
                        store.focusSelection()
                    })
                    .contextMenu { actions(for: .feature(feature.id)) }
                }
            } label: {
                placeLabel(folder.name, symbol: "folder", visible: folder.isVisible) {
                    store.toggleFolder(folder.id)
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    store.selection = .folder(folder.id)
                    store.focusSelection()
                })
            }
            .tag(PlaceSelection.folder(folder.id))
            .contextMenu { actions(for: .folder(folder.id)) }
        }
    }

    private func placeLabel(_ name: String, symbol: String, visible: Bool, toggle: @escaping () -> Void) -> some View {
        HStack {
            Label(name, systemImage: symbol)
                .lineLimit(1)
                .foregroundStyle(visible ? .primary : .secondary)
            Spacer(minLength: 4)
            Toggle("Show \(name) on Globe", isOn: Binding(
                get: { visible },
                set: { _ in toggle() }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help(visible ? "Hide on globe" : "Show on globe")
        }
    }

    @ViewBuilder
    private func actions(for selection: PlaceSelection) -> some View {
        Button("Show on Globe") {
            store.selection = selection
            store.focusSelection()
        }
        Button("Export GeoJSON…") {
            store.selection = selection
            store.exportGeoJSON()
        }
    }

    private func geometrySymbol(_ geometry: GeoGeometry?) -> String {
        switch geometry {
        case .point, .multiPoint: return "mappin"
        case .lineString, .multiLineString: return "point.topleft.down.to.point.bottomright.curvepath"
        case .polygon, .multiPolygon: return "pentagon"
        case .geometryCollection: return "square.stack.3d.up"
        case nil: return "doc"
        }
    }
}

private func matches(_ folder: GeoFolder, query: String) -> Bool {
    query.isEmpty || folder.name.localizedCaseInsensitiveContains(query)
        || folder.features.contains { $0.name.localizedCaseInsensitiveContains(query) }
        || folder.children.contains { matches($0, query: query) }
}
