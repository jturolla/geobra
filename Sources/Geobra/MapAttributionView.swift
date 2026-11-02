import SwiftUI

struct MapAttributionView: View {
    let source: MapSource
    let isVisible: Bool
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isVisible {
            if source.requiresAPIKey {
                HStack(alignment: .center, spacing: 0) {
                    Image(colorScheme == .dark ? "google-maps-white" : "google-maps-gray", bundle: resources)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 98, height: 18)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 5)
                        .accessibilityLabel("Google Maps")
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } else {
                Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    .help("OpenStreetMap data attribution and license")
            }
        }
    }

    private var resources: Bundle {
        Bundle.main.resourceURL
            .map { $0.appendingPathComponent("Geobra_Geobra.bundle") }
            .flatMap(Bundle.init(url:)) ?? Bundle.module
    }
}
