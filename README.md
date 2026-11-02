# Geobra

Geobra is a native Mac app for geographic files. It imports KML, KMZ, and GeoJSON into one GeoJSON model.
A native sidebar keeps data layers, folders, and features organized. A large 3D globe shows online maps and visible features.

The app uses SwiftUI, AppKit, and SceneKit. Its sidebar, toolbar, inspector, and settings follow the system appearance.
OpenStreetMap works without an account. Google Maps requires an API key. The app uses no web runtime.

## Requirements

- macOS 14 or later.
- Xcode 16 or later, with its command line tools selected.
- Swift 6 or later.
- An internet connection for online maps and remote GeoJSON sources.

## Build and run

1. Clone the repository.
2. Open a terminal in the repository directory.
3. Build the app:

   ```bash
   ./scripts/build-app.sh
   ```

4. Open the app:

   ```bash
   open dist/Geobra.app
   ```

The script creates a local app bundle and signs it with an ad hoc signature.
It draws the app icon from native vector shapes during the build.
It does not use an Apple account or a deployment credential. It does not publish or notarize the app.

Use `dist/Geobra-mac.zip` to transfer the build. The script checks the signature after it extracts a fresh copy in temporary storage.
Extract the ZIP outside a folder that syncs to cloud storage. For example, extract it in `/Applications`.
Cloud file providers can add metadata that makes signature checks fail. The app in `dist/Geobra.app` remains available for local use.

For a debug build, use `./scripts/build-app.sh debug`.
For direct development, use `swift run Geobra` or open `Package.swift` in Xcode.

## Use the app

- Import a `.kml`, `.kmz`, `.geojson`, or `.json` file with the Import button.
- Select Import > Add GeoJSON URL to load an HTTPS GeoJSON data source.
- Drag files into the window to import them.
- Expand folders to find features.
- Change visibility with the visibility control beside a folder or feature.
- Select a feature to inspect its properties.
- Select several places with Command-click or Shift-click.
- Drag selected places into a folder. Drag between siblings to change their order.
- Press Return to rename the selected place. Press Escape to cancel the name change.
- Select Places > New Folder with Selection to group the selected places.
- Use Edit > Undo or Edit > Redo to reverse or repeat workspace edits.
- Use the Inspector button to inspect a single place or a group of selected places.
- Export a folder as GeoJSON.
- Use the globe controls to change the view.
- Select Open Sample Project in an empty workspace to explore the built-in example.

## Map sources and layers

Select a source from the map menu in the toolbar. Source changes preserve the camera and imported data.

| Source | Content | Access |
| --- | --- | --- |
| OpenStreetMap | Street map | No API key. |
| Google Maps | Street map | Google Maps Tile API key. |
| Google Satellite | Satellite imagery | Google Maps Tile API key. |
| Google Hybrid | Satellite imagery with roads and labels | Google Maps Tile API key. |

Use Show Basemap and Show Coordinate Grid in the map menu to change reference layers.
Each imported folder is a separate data layer. Its visibility control also applies to its child folders and features.
GeoJSON URL imports load a local copy. They do not refresh automatically.

Open Source Settings to save or delete a Google key. The key stays in the app-specific Keychain item on this Mac.
It does not enter workspace files, exports, or UserDefaults. Enable the Map Tiles API for the key through your Google project.
Google Maps usage can incur charges. The app does not create a cloud project or activate billing.
See [Google API setup](https://developers.google.com/maps/documentation/tile/get-api-key).

Map requests identify the current viewport to the selected provider. They do not upload imported feature properties or source files.
The app shows provider attribution with the map. OpenStreetMap requests use an app-specific User-Agent and honor HTTP cache headers.
Google sessions use the official Map Tiles API, with a memory-only HTTP cache.
The app requests tiles for the visible viewport. It provides no bulk download or offline map feature.

Provider documentation: [OpenStreetMap tile policy](https://operations.osmfoundation.org/policies/tiles/) and [Google Map Tiles API](https://developers.google.com/maps/documentation/tile/overview).

The app saves the workspace locally at:

```text
~/Library/Application Support/Geobra/workspace.geobra
```

The workspace file preserves folders, feature properties, visibility, and styles.
A GeoJSON export uses a `FeatureCollection` for geographic data.
Geobra metadata preserves folders, styles, and visibility when you import that export again.

## Sample files

The `Samples` directory contains small files for import checks:

| File | Contents |
| --- | --- |
| `sao-paulo.geojson` | A polygon with a hole, a line, and a point near São Paulo. |
| `sao-paulo.kml` | Nested folders, feature styles, properties, and a polygon with a hole. |
| `sao-paulo.kmz` | A ZIP archive that contains the sample KML as `doc.kml`. |

The sample boundaries illustrate import behavior. They are not survey data or official boundaries.

## Check the source

Run the import, workspace, tile, and provider tests:

```bash
swift test
```

Build a release bundle:

```bash
./scripts/build-app.sh
```

These commands check the app locally. The build script creates a ZIP archive and checks its extracted signature before it copies the build to `dist`.

A proposed GitHub Actions workflow is in `scripts/ci.example.yml`. Add it through an account that can create workflows.
The example remains outside `.github/workflows`, so it does not run.

## Current limits

- Online map detail depends on provider coverage, zoom limits, network access, and credentials.
- The app does not request terrain or elevation data.
- The app preserves altitude values, but it draws overlays on the globe surface.
- The app draws paths with positive line widths as native lines of one pixel in this version.
- Decimal properties support about 38 significant digits.
- KML ground overlays, screen overlays, network links, tours, and embedded media are outside this version.
- The app does not provide advanced geometry editing, measurement tools, or coordinate reference system conversion.
- GeoJSON coordinates use longitude and latitude in WGS 84. Reproject other coordinate systems before import.
- The local bundle is for development. Distribution signing, notarization, and App Store packaging need a separate release process.

Attribution asset credits are in `Sources/Geobra/Resources/ASSET-SOURCES.md`.
