import GeobraCore
import SwiftUI

@MainActor
struct InspectorView: View {
    @Bindable var store: WorkspaceStore
    @State private var draftName = ""
    @State private var editingSelection: PlaceSelection?
    @State private var confirmsDeletion = false

    private let accent = Color(red: 0.91, green: 0.72, blue: 0.42)
    private let palette = ["#76C8A6", "#E7B86A", "#8CB7F0", "#D5A2DF", "#EF9383", "#E5E9EC"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("INSPECTOR")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { store.showInspector = false } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Hide the inspector")
                .accessibilityLabel("Hide the inspector")
            }
            .padding(20)
            Divider().opacity(0.45)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if store.selection != nil {
                        selectionHeader
                        nameEditor
                        if let feature = store.selectedFeature { featureDetails(feature) }
                        if let folder = store.selectedFolder { folderDetails(folder) }
                        organization
                        actions
                    } else {
                        emptyInspector
                    }
                }
                .padding(20)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "externaldrive")
                Text("Stored on this Mac")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(20)
        }
        .background(Color(red: 0.09, green: 0.105, blue: 0.12))
        .onAppear { synchronizeName() }
        .onChange(of: store.selection) { _, _ in synchronizeName() }
        .confirmationDialog("Delete this item?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.deleteSelection() }
        } message: {
            Text("This removes the selected item and its contents from the workspace.")
        }
    }

    private var selectionHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: store.selectedFeature == nil ? "folder" : geometrySymbol)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(accent)
                .frame(width: 48, height: 48)
                .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            Text(store.selectedFeature?.name ?? store.selectedFolder?.name ?? "Selection")
                .font(.system(size: 19, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(store.selectedFeature?.geometry?.displayName ?? (store.selectedFolder == nil ? "Feature" : "Folder"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("NAME")
            HStack(spacing: 8) {
                TextField("Item name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveName)
                    .accessibilityLabel("Item name")
                Button("Save", action: saveName)
                    .controlSize(.small)
                    .disabled(!hasNameChange)
                    .help("Save the item name")
            }
        }
    }

    private func featureDetails(_ feature: GeoFeature) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("GEOMETRY")
                detailRow("Type", feature.geometry?.displayName ?? "No geometry")
                detailRow("Coordinates", (feature.geometry?.coordinates.count ?? 0).formatted())
                if case let .point(coordinate) = feature.geometry {
                    detailRow("Latitude", coordinate.latitude.formatted(.number.precision(.fractionLength(5))))
                    detailRow("Longitude", coordinate.longitude.formatted(.number.precision(.fractionLength(5))))
                    if let altitude = coordinate.altitude { detailRow("Altitude", "\(altitude.formatted()) m") }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("COLOR")
                HStack(spacing: 10) {
                    ForEach(palette, id: \.self) { hex in
                        Button { store.setColor(hex) } label: {
                            Circle()
                                .fill(color(hex))
                                .frame(width: 21, height: 21)
                                .padding(3)
                                .overlay {
                                    Circle().strokeBorder(
                                        feature.style.colorHex.caseInsensitiveCompare(hex) == .orderedSame
                                            ? Color.white.opacity(0.8) : .clear,
                                        lineWidth: 1
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                        .help("Set color to \(hex)")
                        .accessibilityLabel("Set color to \(hex)")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("PROPERTIES")
                if feature.properties.isEmpty {
                    Text("This feature has no properties.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(feature.properties.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(feature.properties[key]?.displayText ?? "")
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func folderDetails(_ folder: GeoFolder) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("CONTENTS")
            detailRow("Features", folder.featureCount.formatted())
            detailRow("Direct folders", folder.children.count.formatted())
            detailRow("Visibility", folder.isVisible ? "Visible" : "Hidden")
        }
    }

    private var organization: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("ORGANIZE")
            Menu {
                if store.selectedFolder != nil {
                    Button("My Places") { store.moveSelection(to: nil) }
                    Divider()
                }
                ForEach(availableFolders, id: \.id) { folder in
                    Button(folder.name) { store.moveSelection(to: folder.id) }
                }
                if availableFolders.isEmpty { Text("Create a destination folder first.") }
            } label: {
                Label("Move to Folder", systemImage: "folder.badge.arrow.forward")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .padding(9)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.5)
            Button(action: store.focusSelection) {
                Label("Show on Globe", systemImage: "scope")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(store.selectedFeature?.geometry == nil && store.selectedFolder?.allFeatures.first?.geometry == nil)
            Button(action: store.exportGeoJSON) {
                Label("Export GeoJSON…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(role: .destructive) { confirmsDeletion = true } label: {
                Label("Delete Item…", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Color(red: 0.87, green: 0.48, blue: 0.45))
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
    }

    private var emptyInspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "cursorarrow.click")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(accent)
            Text("A closer look")
                .font(.system(size: 20, weight: .medium))
            Text("Select a folder or feature to see its details.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            sectionLabel("WORK WITH YOUR PLACES")
            hint("folder", "Organize features in folders.")
            hint("eye", "Control visibility from the sidebar.")
            hint("scope", "Show a feature on the globe.")
            hint("square.and.arrow.up", "Export your selection as GeoJSON.")
        }
    }

    private var geometrySymbol: String {
        switch store.selectedFeature?.geometry {
        case .point, .multiPoint: return "mappin.and.ellipse"
        case .lineString, .multiLineString: return "point.topleft.down.to.point.bottomright.curvepath"
        case .polygon, .multiPolygon: return "pentagon"
        default: return "square.stack.3d.up"
        }
    }

    private var availableFolders: [(id: UUID, name: String)] {
        guard let selected = store.selectedFolder else { return store.folderOptions }
        let excluded = descendantIDs(selected)
        return store.folderOptions.filter { !excluded.contains($0.id) }
    }

    private func descendantIDs(_ folder: GeoFolder) -> Set<UUID> {
        folder.children.reduce(into: Set([folder.id])) { result, child in
            result.formUnion(descendantIDs(child))
        }
    }

    private func synchronizeName() {
        editingSelection = store.selection
        draftName = store.selectedFeature?.name ?? store.selectedFolder?.name ?? ""
    }

    private var hasNameChange: Bool {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentName = store.selectedFeature?.name ?? store.selectedFolder?.name ?? ""
        return editingSelection == store.selection && !name.isEmpty && name != currentName
    }

    private func saveName() {
        guard editingSelection == store.selection, hasNameChange else { return }
        store.renameSelection(draftName)
        synchronizeName()
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(.tertiary)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 11))
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
    }

    private func color(_ hex: String) -> Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xE7B86A
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
}
