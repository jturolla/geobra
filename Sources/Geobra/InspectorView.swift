import AppKit
import GeobraCore
import SwiftUI

@MainActor
struct InspectorView: View {
    @Bindable var store: WorkspaceStore
    @State private var draftName = ""
    @State private var editingSelection: PlaceSelection?
    @State private var confirmsDeletion = false
    @State private var deletionSelections = Set<PlaceSelection>()

    var body: some View {
        Group {
            if store.selections.count > 1 {
                multipleSelectionForm
            } else if store.selectedFeature != nil || store.selectedFolder != nil {
                inspectorForm
            } else {
                Text("Select an item to inspect it.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear(perform: synchronizeName)
        .onChange(of: selectedName) { _, _ in synchronizeName() }
        .onChange(of: store.selections) { _, _ in
            synchronizeName()
            confirmsDeletion = false
            deletionSelections.removeAll()
        }
        .confirmationDialog(deletionTitle, isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard store.selections == deletionSelections else { return }
                store.deleteSelections()
            }
        } message: {
            Text("This removes the selected items and their contents from the workspace. You can undo this change.")
        }
    }

    private var multipleSelectionForm: some View {
        Form {
            Section("Selection") {
                LabeledContent("Items", value: store.selections.count.formatted())
                LabeledContent("Features", value: store.selectedFeatureIDs.count.formatted())
            }
            organization
            visibilityActions
            selectionActions
        }
        .formStyle(.grouped)
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

            organization
            visibilityActions
            selectionActions
        }
        .formStyle(.grouped)
    }

    private var organization: some View {
        Section("Organization") {
            Menu("Move to Folder") {
                if store.canMove(store.selections, to: nil) {
                    Button("My Places") { store.move(store.selections, to: nil) }
                    Divider()
                }
                ForEach(availableFolders, id: \.id) { folder in
                    Button(folder.name) { store.move(store.selections, to: folder.id) }
                }
                if availableFolders.isEmpty {
                    Text("Create a destination folder first.")
                }
            }
            Button("New Folder with Selection", systemImage: "folder.badge.plus", action: store.groupSelection)
        }
    }

    private var visibilityActions: some View {
        Section("Visibility") {
            Button("Show on Map", systemImage: "eye") { store.setSelectedVisibility(true) }
            Button("Hide on Map", systemImage: "eye.slash") { store.setSelectedVisibility(false) }
        }
    }

    private var selectionActions: some View {
        Section("Actions") {
            Button("Show on Globe", systemImage: "scope", action: store.focusSelection)
                .disabled(!canFocusSelection)
            Button("Export GeoJSON…", systemImage: "square.and.arrow.up", action: store.exportGeoJSON)
            Button(deleteActionTitle, systemImage: "trash", role: .destructive) {
                deletionSelections = store.selections
                confirmsDeletion = true
            }
        }
    }

    private var deletionTitle: String {
        deletionSelections.count == 1 ? "Delete this item?" : "Delete these items?"
    }

    private var deleteActionTitle: String {
        store.selections.count == 1 ? "Delete Item…" : "Delete Items…"
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
        let selectedIDs = store.selectedFeatureIDs
        return store.workspace.folders.lazy.flatMap(\.allFeatures).contains {
            selectedIDs.contains($0.id) && $0.geometry != nil
        }
    }

    private var availableFolders: [(id: UUID, name: String)] {
        store.folderOptions.filter { store.canMove(store.selections, to: $0.id) }
    }

    private func synchronizeName() {
        editingSelection = store.selection
        draftName = selectedName
    }

    private var selectedName: String {
        store.selectedFeature?.name ?? store.selectedFolder?.name ?? ""
    }

    private var hasNameChange: Bool {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return editingSelection == store.selection && !name.isEmpty && name != selectedName
    }

    private func saveName() {
        guard let item = editingSelection, item == store.selection, hasNameChange else { return }
        store.rename(item, to: draftName)
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
