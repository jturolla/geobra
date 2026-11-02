# Geobra

Geobra is a native Mac app for geographic files. It imports KML, KMZ, and GeoJSON into one GeoJSON model.
A folder sidebar keeps places and features organized. A large 3D globe displays the visible features.

This repository contains the first version. The app uses SwiftUI, AppKit, and SceneKit. It needs no web runtime or account.

## Requirements

- macOS 14 or later.
- Xcode 16 or later, with its command line tools selected.
- Swift 6 or later.

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
- Drag files into the window to import them.
- Expand folders to find features.
- Change visibility with the visibility control beside a folder or feature.
- Select a feature to inspect its properties.
- Use the folder controls to create folders, rename items, and move items.
- Export a folder as GeoJSON.
- Use the globe controls to change the view.
- Select Open Sample Project in an empty workspace to explore the built-in example.

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

Run the import and geometry tests:

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

- The globe uses a bundled Earth texture. It works offline, but it provides limited detail at close zoom.
- The app does not request imagery tiles, terrain, or elevation data.
- The app preserves altitude values, but it draws overlays on the globe surface.
- The app draws paths with positive line widths as native lines of one pixel in this version.
- Decimal properties support about 38 significant digits.
- KML ground overlays, screen overlays, network links, tours, and embedded media are outside this version.
- The app does not provide advanced geometry editing, measurement tools, or coordinate reference system conversion.
- GeoJSON coordinates use longitude and latitude in WGS 84. Reproject other coordinate systems before import.
- The local bundle is for development. Distribution signing, notarization, and App Store packaging need a separate release process.

Earth image credits and source details are in `Sources/Geobra/Resources/ASSET-SOURCES.md`.
