import SwiftUI

@MainActor
struct MapSettingsView: View {
    @Bindable var settings: MapSettings
    @State private var draftKey = ""
    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Map") {
                Picker("Source", selection: $settings.source) {
                    ForEach(MapSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Toggle("Show Base Map", isOn: $settings.isBasemapVisible)
                Toggle("Show Coordinate Grid", isOn: $settings.showsGrid)
            }

            Section {
                LabeledContent("API key", value: settings.hasGoogleKey ? "Saved in Keychain" : "Not configured")
                SecureField("Google Maps API key", text: $draftKey)
                    .onSubmit(saveKey)
                HStack {
                    Button("Save Key", action: saveKey)
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Delete Key", role: .destructive, action: deleteKey)
                        .disabled(!settings.hasGoogleKey && settings.credentialError == nil)
                }
                if let message {
                    Text(message).foregroundStyle(.secondary)
                }
                if let error = errorMessage ?? settings.credentialError {
                    Text(error).foregroundStyle(.red)
                }
                Link("Google Maps API setup", destination: URL(string: "https://developers.google.com/maps/documentation/tile/get-api-key")!)
            } header: {
                Text("Google Maps")
            } footer: {
                Text("Enable the Map Tiles API for this key. Google Maps usage can incur charges. The key stays in this Mac’s Keychain.")
            }

            Section("Map Data") {
                Text("OpenStreetMap works without an API key. Both map sources need an internet connection.")
                    .foregroundStyle(.secondary)
                Link("OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("Maps")
        .onAppear { settings.reloadCredentials() }
        .onDisappear { draftKey = "" }
    }

    private func saveKey() {
        do {
            try GoogleMapsCredentialStore.save(draftKey)
            draftKey = ""
            settings.reloadCredentials()
            errorMessage = nil
            message = "The API key is saved in Keychain."
        } catch {
            errorMessage = error.localizedDescription
            message = nil
        }
    }

    private func deleteKey() {
        do {
            try GoogleMapsCredentialStore.delete()
            draftKey = ""
            settings.reloadCredentials()
            errorMessage = nil
            message = "The API key was removed from Keychain."
        } catch {
            errorMessage = error.localizedDescription
            message = nil
        }
    }
}
