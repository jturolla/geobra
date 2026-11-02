#!/bin/bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_dir"

configuration="${1:-release}"
case "$configuration" in
  debug|release) ;;
  *)
    echo "Use debug or release as the build configuration." >&2
    exit 2
    ;;
esac

swift build --configuration "$configuration" --product Geobra
binary_dir="$(swift build --configuration "$configuration" --show-bin-path)"
app_dir="$repository_dir/dist/Geobra.app"
staging_dir="$(mktemp -d "$repository_dir/dist-stage.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

mkdir -p "$staging_dir/Geobra.app/Contents/MacOS" "$staging_dir/Geobra.app/Contents/Resources"
cp "$binary_dir/Geobra" "$staging_dir/Geobra.app/Contents/MacOS/Geobra"
swift scripts/create-icon.swift "$staging_dir/Geobra.app/Contents/Resources/Geobra.icns"

# Keep resources inside Contents so the bundle passes signature checks.
for resource_bundle in "$binary_dir"/*.bundle; do
  if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$staging_dir/Geobra.app/Contents/Resources/"
  fi
done

cat > "$staging_dir/Geobra.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Geobra</string>
  <key>CFBundleIdentifier</key><string>com.geobra.mac</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Geobra</string>
  <key>CFBundleDisplayName</key><string>Geobra</string>
  <key>CFBundleIconFile</key><string>Geobra.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Geobra Workspace</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>com.geobra.workspace</string></array>
      <key>CFBundleTypeIconFile</key><string>Geobra.icns</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>KML Geographic File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.google.earth.kml</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>KMZ Geographic Archive</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.google.earth.kmz</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>GeoJSON Geographic File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.geojson</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.geobra.workspace</string>
      <key>UTTypeDescription</key><string>Geobra Workspace</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeIconFile</key><string>Geobra.icns</string>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>geobra</string></array></dict>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.google.earth.kml</string>
      <key>UTTypeDescription</key><string>KML Geographic File</string>
      <key>UTTypeConformsTo</key><array><string>public.xml</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>kml</string></array>
        <key>public.mime-type</key><string>application/vnd.google-earth.kml+xml</string>
      </dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.google.earth.kmz</string>
      <key>UTTypeDescription</key><string>KMZ Geographic Archive</string>
      <key>UTTypeConformsTo</key><array><string>com.pkware.zip-archive</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>kmz</string></array>
        <key>public.mime-type</key><string>application/vnd.google-earth.kmz</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

plutil -lint "$staging_dir/Geobra.app/Contents/Info.plist"
# Remove metadata that can prevent signing a generated app.
xattr -cr "$staging_dir/Geobra.app"
# Ad hoc signing identifies this local build without an Apple account.
codesign --force --deep --sign - "$staging_dir/Geobra.app"
codesign --verify --deep --strict "$staging_dir/Geobra.app"
mkdir -p "$repository_dir/dist"
rm -rf "$app_dir"
mv "$staging_dir/Geobra.app" "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "Built $app_dir"
