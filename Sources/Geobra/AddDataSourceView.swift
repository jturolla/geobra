import Foundation
import SwiftUI

struct AddDataSourceView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("URL", text: $address, prompt: Text("https://example.com/data.geojson"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addSource)
                    if let validationError {
                        Text(validationError).foregroundStyle(.red)
                    }
                } header: {
                    Text("GeoJSON Data Source")
                } footer: {
                    Text("Import a snapshot of this HTTPS GeoJSON source into a separate data layer. The workspace preserves its properties and geometry.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Data Source", action: addSource)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isImporting)
            }
            .padding()
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("Add Data Source")
    }

    private func addSource() {
        guard !store.isImporting else { return }
        do {
            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw RemoteGeoJSONError.invalidURL
            }
            try RemoteGeoJSON.validate(url)
            store.importRemoteGeoJSON(from: url)
            address = ""
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}
