import AppKit
import GeobraCore
import SwiftUI

@MainActor
struct InspectorView: View {
    @Bindable var store: WorkspaceStore
    @State private var draftName = ""
    @State private var editingSelection: PlaceSelection?
    @State private var confirmsDeletion = false

    var body: some View {
        Group {
            if store.selectedFeature != nil || store.selectedFolder != nil {
                inspectorForm
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.right",
                    description: Text("Select a folder or feature to inspect its details.")
                )
            }
        }
        .onAppear(perform: synchronizeName)
        .onChange(of: store.selection) { _, _ in synchronizeName() }
        .confirmationDialog("Delete this item?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.deleteSelection() }
        } message: {
            Text("This removes the selected item and its contents from the workspace.")
        }
    }

    private var inspectorForm: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $draftName)
                    .onSubmit(saveName)
                Button("Apply Name", action: saveName)
                    .disabled(!hasNameChange)
            }

            if let feature = store.selectedFeature {
                featureDetails(feature)
            }

            if let folder = store.selectedFolder {
                Section("Contents") {
                    LabeledContent("Features", value: folder.featureCount.formatted())
                    LabeledContent("Folders", value: folder.children.count.formatted())
                    LabeledContent("Visibility", value: folder.isVisible ? "Visible" : "Hidden")
                }
            }

            Section("Organization") {
                Menu("Move to Folder") {
                    if store.selectedFolder != nil {
                        Button("My Places") { store.moveSelection(to: nil) }
                        Divider()
                    }
                    ForEach(availableFolders, id: \.id) { folder in
                        Button(folder.name) { store.moveSelection(to: folder.id) }
                    }
                    if availableFolders.isEmpty {
                        Text("Create a destination folder first.")
                    }
                }
            }

            Section("Actions") {
                Button("Show on Globe", systemImage: "scope", action: store.focusSelection)
                    .disabled(!canFocusSelection)
                Button("Export GeoJSON…", systemImage: "square.and.arrow.up", action: store.exportGeoJSON)
                Button("Delete Item…", systemImage: "trash", role: .destructive) {
                    confirmsDeletion = true
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func featureDetails(_ feature: GeoFeature) -> some View {
        Section("Geometry") {
            LabeledContent("Type", value: feature.geometry?.displayName ?? "No geometry")
            LabeledContent("Coordinates", value: (feature.geometry?.coordinates.count ?? 0).formatted())
            if case let .point(coordinate) = feature.geometry {
                LabeledContent("Latitude", value: coordinate.latitude.formatted(.number.precision(.fractionLength(5))))
                LabeledContent("Longitude", value: coordinate.longitude.formatted(.number.precision(.fractionLength(5))))
                if let altitude = coordinate.altitude {
                    LabeledContent("Altitude", value: "\(altitude.formatted()) m")
                }
            }
        }

        Section("Style") {
            ColorPicker("Color", selection: featureColor(for: feature), supportsOpacity: false)
        }

        Section("Properties") {
            if feature.properties.isEmpty {
                Text("This feature has no properties.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(feature.properties.keys.sorted(), id: \.self) { key in
                    LabeledContent(key) {
                        Text(feature.properties[key]?.displayText ?? "")
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var canFocusSelection: Bool {
        store.selectedFeature?.geometry != nil
            || store.selectedFolder?.allFeatures.contains { $0.geometry != nil } == true
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

    private func featureColor(for feature: GeoFeature) -> Binding<Color> {
        Binding {
            color(from: feature.style.colorHex)
        } set: { selectedColor in
            guard store.selectedID == feature.id,
                  let color = NSColor(selectedColor).usingColorSpace(.sRGB) else { return }
            let components = [color.redComponent, color.greenComponent, color.blueComponent]
                .map { Int((min(1, max(0, $0)) * 255).rounded()) }
            let hex = String(format: "#%02X%02X%02X", components[0], components[1], components[2])
            store.setColor(hex)
        }
    }

    private func color(from hex: String) -> Color {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .accentColor }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255
        )
    }
}
