#!/bin/zsh
# Reproducible GitHub-shareable DMG packager for Sushi.GS ("Gas Station Sushi").
#
# Usage:
#   scripts/build_dmg.sh                    # builds dist/Sushi.GS-0.1.0-arm64.dmg (ad-hoc signed)
#   APP_VERSION=0.1.0 scripts/build_dmg.sh  # explicit version
#
# Optional Developer ID Signing & Notarization env vars:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="your-keychain-profile"
#     OR:
#   APPLE_ID="you@example.com"
#   APPLE_TEAM_ID="TEAMID"
#   APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
set -euo pipefail

here=${0:A:h}
repo=${here:h}
app_name="Sushi.GS"
exec_name="SushiGS"
bundle_id="io.github.mobiusgt.sushigs"
version="${APP_VERSION:-0.1.0}"
build_num="${APP_BUILD:-1}"
out_dir="${OUT_DIR:-$repo/dist}"
scratch="${SCRATCH_PATH:-$HOME/Library/Developer/SushiGS/dmg-build}"

dmg_name="${app_name}-${version}-arm64.dmg"
dmg_path="$out_dir/$dmg_name"
sha_path="${dmg_path}.sha256"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out_dir"

echo "==> Building Release arm64 binary ($app_name $version [$build_num])"
swift build -c release --arch arm64 --package-path "$repo" --scratch-path "$scratch"

bin="$scratch/arm64-apple-macosx/release/$exec_name"
[[ -x "$bin" ]] || bin="$scratch/release/$exec_name"
[[ -x "$bin" ]] || { echo "ERROR: Release executable not found at $bin"; exit 1; }

# Verify arm64 Mach-O slice
arch_info=$(file "$bin")
echo "    Executable: $arch_info"
[[ "$arch_info" == *"arm64"* ]] || { echo "ERROR: Expected arm64 executable"; exit 1; }

echo "==> Compiling AppIcon.icon -> Assets.car + AppIcon.icns"
"$repo/tools/make_icon.sh"

stage="$work/stage"
app="$stage/${app_name}.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin" "$app/Contents/MacOS/$exec_name"
sed -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build_num/g" "$repo/Info.plist.in" > "$app/Contents/Info.plist"
cp "$repo/Resources/worker.py" "$app/Contents/Resources/worker.py"
chmod +x "$app/Contents/Resources/worker.py"
cp -X "$repo/Resources/Assets.car" "$app/Contents/Resources/Assets.car"
cp -X "$repo/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
if [[ -f "$repo/Resources/AboutIcon.png" ]]; then
  cp -X "$repo/Resources/AboutIcon.png" "$app/Contents/Resources/AboutIcon.png"
fi

echo "==> Verifying bundle metadata and required resources"
for required in \
  "$app/Contents/MacOS/$exec_name" \
  "$app/Contents/Info.plist" \
  "$app/Contents/Resources/worker.py" \
  "$app/Contents/Resources/Assets.car" \
  "$app/Contents/Resources/AppIcon.icns"; do
  [[ -f "$required" ]] || { echo "ERROR: Missing required bundle file: $required"; exit 1; }
done

check_plist() {
  local key="$1"
  local expected="$2"
  local actual
  actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist")
  [[ "$actual" == "$expected" ]] || { echo "ERROR: Info.plist $key='$actual' (expected '$expected')"; exit 1; }
}
check_plist CFBundleName "$app_name"
check_plist CFBundleDisplayName "$app_name"
check_plist CFBundleIdentifier "$bundle_id"
check_plist CFBundleShortVersionString "$version"
check_plist CFBundleVersion "$build_num"
check_plist LSMinimumSystemVersion "26.0"

# Ensure no third-party GPL/LGPL binaries were accidentally bundled inside the DMG.
for forbidden in ffmpeg ffprobe mkvmerge opusenc aegisub-cli uv; do
  if find "$app" -name "$forbidden" | grep -q .; then
    echo "ERROR: Third-party binary '$forbidden' must not be bundled inside the DMG."
    exit 1
  fi
done

xattr -cr "$app"

identity="${CODESIGN_IDENTITY:--}"
echo "==> Signing $app_name.app (identity: $identity)"
if [[ "$identity" == "-" ]]; then
  codesign --force --deep --sign - "$app"
else
  codesign --force --deep --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

should_notarize=0
if [[ "$identity" != "-" ]]; then
  if [[ -n "${NOTARY_PROFILE:-}" ]] || [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    should_notarize=1
  fi
fi

notarize_item() {
  local target="$1"
  echo "==> Submitting $target to Apple Notary Service"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$target" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --wait
  fi
  xcrun stapler staple "$target"
}

if [[ "$should_notarize" == "1" ]]; then
  zip_tmp="$work/${app_name}.zip"
  ditto -c -k --keepParent "$app" "$zip_tmp"
  notarize_item "$zip_tmp"
  xcrun stapler staple "$app"
fi

echo "==> Packaging drag-to-Applications DMG ($dmg_name)"
ln -s /Applications "$stage/Applications"
cp -X "$repo/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns"

rw_dmg="$work/rw.dmg"
rm -f "$rw_dmg" "$dmg_path" "$sha_path"
hdiutil create \
  -volname "$app_name" \
  -srcfolder "$stage" \
  -fs HFS+ \
  -format UDRW \
  -ov "$rw_dmg" >/dev/null

mount_dir="$work/mnt"
mkdir -p "$mount_dir"
hdiutil attach "$rw_dmg" -readwrite -noverify -noautoopen -mountpoint "$mount_dir" >/dev/null

# Enable custom volume icon bit if SetFile is available
if command -v SetFile >/dev/null 2>&1; then
  SetFile -c icnC "$mount_dir/.VolumeIcon.icns" || true
  SetFile -a C "$mount_dir" || true
fi

# Apply a clean Finder drag-to-Applications layout when running with an interactive GUI session.
if [[ -z "${CI:-}" && "${SKIP_FINDER_LAYOUT:-0}" != "1" ]]; then
  osascript <<EOF >/dev/null 2>&1 || true
tell application "Finder"
  tell disk "$app_name"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 140, 740, 480}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set position of item "${app_name}.app" of container window to {150, 165}
    set position of item "Applications" of container window to {390, 165}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
fi

sync
hdiutil detach "$mount_dir" -quiet || hdiutil detach "$mount_dir" -force -quiet

hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg_path" >/dev/null

if [[ "$identity" != "-" ]]; then
  codesign --force --timestamp --sign "$identity" "$dmg_path"
fi
if [[ "$should_notarize" == "1" ]]; then
  notarize_item "$dmg_path"
fi

(cd "$out_dir" && shasum -a 256 "$dmg_name" > "$(basename "$sha_path")")

echo "==> Done!"
echo "    DMG:    $dmg_path ($(du -h "$dmg_path" | awk '{print $1}'))"
echo "    SHA256: $(cat "$sha_path")"
