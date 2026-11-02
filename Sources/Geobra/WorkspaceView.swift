import GeobraCore
import SwiftUI

enum GeobraTheme {
    static let background = Color(red: 0.055, green: 0.075, blue: 0.085)
    static let panel = Color(red: 0.085, green: 0.11, blue: 0.12)
    static let accent = Color(red: 0.91, green: 0.72, blue: 0.40)
    static let secondary = Color(red: 0.54, green: 0.61, blue: 0.61)
}

struct WorkspaceView: View {
    @Bindable var store: WorkspaceStore
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            HSplitView {
                sidebar.frame(minWidth: 240, idealWidth: 275, maxWidth: 360)
                globe.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
                if store.showInspector {
                    InspectorView(store: store)
                        .frame(minWidth: 245, idealWidth: 265, maxWidth: 310)
                        .background(GeobraTheme.panel)
                }
            }
            footer
        }
        .background(GeobraTheme.background)
        .tint(GeobraTheme.accent)
        .dropDestination(for: URL.self) { urls, _ in
            store.importURLs(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(GeobraTheme.accent, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .alert("Geobra", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(GeobraTheme.accent)
            Text("Geobra").font(.system(size: 19, weight: .semibold, design: .rounded))
            Text("PLACES, IN PERSPECTIVE")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(GeobraTheme.secondary)
                .padding(.leading, 8)
            Spacer()
            Button(action: store.addFolder) {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("Create a folder (⇧⌘N)")
            Button(action: store.exportGeoJSON) {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export GeoJSON (⇧⌘E)")
            Button { store.showInspector.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Show or hide the inspector")
            Divider().frame(height: 20).padding(.horizontal, 3)
            Button(action: store.chooseImport) {
                Label("Import", systemImage: "plus")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(GeobraTheme.background)
            .disabled(store.isImporting)
            .help("Import KML, KMZ, or GeoJSON (⌘I)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(GeobraTheme.panel)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MY PLACES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.8)
                Spacer()
                Text("\(store.featureCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.06), in: Capsule())
            }
            .foregroundStyle(GeobraTheme.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 22)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(GeobraTheme.secondary)
                TextField("Filter places", text: $store.search)
                    .textFieldStyle(.plain)
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(GeobraTheme.secondary)
                        .help("Clear the filter")
                }
            }
            .font(.system(size: 12))
            .padding(10)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            Divider().opacity(0.35)
            if store.workspace.folders.isEmpty { emptyLibrary }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(store.workspace.folders) { folder in
                            FolderRow(folder: folder, store: store)
                        }
                        if !store.search.isEmpty && !store.workspace.folders.contains(where: { matches($0, query: store.search) }) {
                            Text("No places match this filter.")
                                .font(.system(size: 12))
                                .foregroundStyle(GeobraTheme.secondary)
                                .padding()
                        }
                    }
                    .padding(10)
                }
            }
            Spacer(minLength: 0)
            Divider().opacity(0.35)
            VStack(alignment: .leading, spacing: 7) {
                Label("Local workspace", systemImage: "internaldrive")
                    .font(.system(size: 11, weight: .medium))
                Text("Changes save automatically on this Mac.")
                    .font(.system(size: 10))
                    .foregroundStyle(GeobraTheme.secondary)
            }
            .padding(18)
        }
        .background(GeobraTheme.panel)
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 27, weight: .ultraLight))
                .foregroundStyle(GeobraTheme.accent)
            Text("Start with your places")
                .font(.system(size: 15, weight: .medium))
            Text("Import a file or drop it into this window. Your folders and features will appear here.")
                .font(.system(size: 12))
                .foregroundStyle(GeobraTheme.secondary)
                .lineSpacing(5)
            Text("KML  ·  KMZ  ·  GEOJSON")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundStyle(GeobraTheme.secondary)
            Button("Open Sample Project", action: store.loadSample)
                .controlSize(.small)
                .padding(.top, 6)
        }
        .padding(24)
        .padding(.top, 12)
    }

    private var globe: some View {
        ZStack(alignment: .topLeading) {
            GlobeView(
                features: store.visibleFeatures,
                selectedID: store.selectedID,
                focusID: store.focusID,
                focusGeometry: store.focusGeometry,
                focusRevision: store.focusRevision,
                resetRevision: store.resetRevision,
                zoomRevision: store.zoomRevision,
                onSelect: { store.selection = $0.map(PlaceSelection.feature) }
            )
            .accessibilityLabel("Interactive globe")
            .accessibilityHint("Drag to rotate. Scroll to zoom. Select a feature to inspect it.")
            VStack(alignment: .leading, spacing: 8) {
                Text("THE WORLD, ORGANIZED")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(2.6)
                    .foregroundStyle(GeobraTheme.secondary)
                Text(store.selectedFolder?.name ?? "My Places")
                    .font(.system(size: 25, weight: .light))
                Text("\(store.visibleFeatures.count) visible features")
                    .font(.system(size: 11))
                    .foregroundStyle(GeobraTheme.secondary)
            }
            .padding(28)
            .allowsHitTesting(false)
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Drag to orbit · Scroll to zoom", systemImage: "cursorarrow.motionlines")
                        Text("NASA Blue Marble · Offline imagery")
                            .foregroundStyle(GeobraTheme.secondary)
                    }
                    .font(.system(size: 10))
                    .padding(13)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    VStack(spacing: 0) {
                        globeButton("plus", help: "Zoom in") { store.zoomRevision += 1 }
                        Divider().frame(width: 20)
                        globeButton("minus", help: "Zoom out") { store.zoomRevision -= 1 }
                        Divider().frame(width: 20)
                        globeButton("globe", help: "Reset globe (⌘0)", action: store.resetGlobe)
                    }
                    .background(GeobraTheme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.08)))
                }
                .padding(24)
            }
            if store.isImporting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Importing geographic files…").font(.system(size: 12))
                }
                .padding(16)
                .background(GeobraTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
    }

    private func globeButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 37, height: 35)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(GeobraTheme.accent).frame(width: 4, height: 4)
            Text(store.status)
            Spacer()
            Text("\(store.folderCount) folders")
            Text("·")
            Text("\(store.featureCount) features")
            Divider().frame(height: 11).padding(.horizontal, 5)
            Text("WGS 84").font(.system(size: 9, design: .monospaced))
        }
        .font(.system(size: 10))
        .foregroundStyle(GeobraTheme.secondary)
        .padding(.horizontal, 18)
        .frame(height: 29)
        .background(GeobraTheme.panel)
    }
}

private struct FolderRow: View {
    let folder: GeoFolder
    @Bindable var store: WorkspaceStore
    @State private var isExpanded = true

    var body: some View {
        if matches(folder, query: store.search) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Button { isExpanded.toggle() } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .frame(width: 10)
                    }
                    .help(isExpanded ? "Collapse folder" : "Expand folder")
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(GeobraTheme.accent)
                    Text(folder.name).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(folder.featureCount)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(GeobraTheme.secondary)
                    visibilityButton(folder.isVisible) { store.toggleFolder(folder.id) }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
                .onTapGesture { store.selection = .folder(folder.id) }
                .onTapGesture(count: 2) { store.selection = .folder(folder.id); store.focusSelection() }
                .background(store.selection == .folder(folder.id) ? GeobraTheme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contextMenu {
                    Button("Show on Globe") { store.selection = .folder(folder.id); store.focusSelection() }
                    Button("Export GeoJSON…") { store.selection = .folder(folder.id); store.exportGeoJSON() }
                }
                if isExpanded || !store.search.isEmpty {
                    ForEach(folder.children) { child in
                        FolderRow(folder: child, store: store).padding(.leading, 14)
                    }
                    ForEach(folder.features.filter { store.search.isEmpty || $0.name.localizedCaseInsensitiveContains(store.search) }) { feature in
                        featureRow(feature).padding(.leading, 19)
                    }
                }
            }
            .buttonStyle(.plain)
            .opacity(folder.isVisible ? 1 : 0.5)
        }
    }

    private func featureRow(_ feature: GeoFeature) -> some View {
        HStack(spacing: 9) {
            Image(systemName: geometrySymbol(feature.geometry))
                .font(.system(size: 12))
                .foregroundStyle(GeobraTheme.accent.opacity(0.8))
                .frame(width: 14)
            Text(feature.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
            visibilityButton(feature.isVisible) { store.toggleFeature(feature.id) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .opacity(feature.isVisible ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { store.selection = .feature(feature.id) }
        .onTapGesture(count: 2) { store.selection = .feature(feature.id); store.focusSelection() }
        .background(store.selection == .feature(feature.id) ? GeobraTheme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Show on Globe") { store.selection = .feature(feature.id); store.focusSelection() }
            Button("Export GeoJSON…") { store.selection = .feature(feature.id); store.exportGeoJSON() }
        }
    }

    private func visibilityButton(_ visible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: visible ? "eye" : "eye.slash")
                .font(.system(size: 10))
                .foregroundStyle(GeobraTheme.secondary)
                .frame(width: 18, height: 16)
        }
        .help(visible ? "Hide on globe" : "Show on globe")
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
