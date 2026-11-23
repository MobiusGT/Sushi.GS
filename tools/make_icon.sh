#!/bin/zsh
# Compiles Icon/AppIcon.icon (Icon Composer) with actool and writes:
#   Resources/Assets.car     Liquid Glass icon (Default, Dark, Tinted, Clear)
#   Resources/AppIcon.icns   Classic multi-resolution .icns fallback
#   Resources/AboutIcon.png  Rendered 512x512 icon for About window & DMG branding
set -euo pipefail
here=${0:A:h}
repo=${here:h}
icon="$repo/Icon/AppIcon.icon"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$repo/Resources"

xcrun actool "$icon" --compile "$work" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$work/partial.plist" \
  --output-format human-readable-text --errors --warnings >"$work/log" 2>&1 || { cat "$work/log"; exit 1; }
[[ -f "$work/Assets.car" && -f "$work/AppIcon.icns" ]] || { cat "$work/log"; echo "actool wrote no icon"; exit 1; }
cp "$work/Assets.car" "$work/AppIcon.icns" "$repo/Resources/"

ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ -x "$ictool" ]]; then
  "$ictool" "$icon" --export-image --output-file "$repo/Resources/AboutIcon.png" \
    --platform macOS --rendition Default --width 256 --height 256 --scale 2 >/dev/null
fi

echo "wrote Resources/Assets.car, Resources/AppIcon.icns, and Resources/AboutIcon.png"
