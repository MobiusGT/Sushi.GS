#!/bin/zsh
# Builds Sushi.GS.app and installs it to ~/Applications/Sushi.GS.app.
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, quit running copy, open new one
set -euo pipefail
here=${0:A:h}
exec_name="SushiGS"
app_name="Sushi.GS"
version="${APP_VERSION:-0.1.0}"
build_num="${APP_BUILD:-1}"
scratch="$HOME/Library/Developer/SushiGS/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug

identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || identity=-

build_log=$(mktemp)
build_ok=1
swift build -c "$config" --arch arm64 --package-path "$here" --scratch-path "$scratch" > "$build_log" 2>&1 || build_ok=0
grep -E "error:|warning:|Build complete" "$build_log" | grep -v "^\[" || true
rm -f "$build_log"
[[ "$build_ok" == 1 ]] || { echo "build failed"; exit 1; }

bin="$scratch/arm64-apple-macosx/$config/$exec_name"
[[ -x "$bin" ]] || bin="$scratch/$config/$exec_name"
[[ -x "$bin" ]] || { echo "build failed: executable not found"; exit 1; }

stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" | head -1)
if [[ -n "$stale" ]]; then
  echo "build failed: binary is older than $stale"
  swift build -c "$config" --arch arm64 --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error:" | head -20
  exit 1
fi

app="$HOME/Applications/$app_name.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$exec_name"
sed -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build_num/g" "$here/Info.plist.in" > "$app/Contents/Info.plist"

# Bundle Python worker bridge inside Contents/Resources
cp "$here/Resources/worker.py" "$app/Contents/Resources/worker.py"

# Compile Icon/AppIcon.icon -> Resources/Assets.car + Resources/AppIcon.icns
if [[ -d "$here/Icon/AppIcon.icon" ]]; then
  car="$here/Resources/Assets.car"
  if [[ ! -f "$car" || -n "$(find "$here/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    "$here/tools/make_icon.sh"
  fi
  cp -X "$car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
  if [[ -f "$here/Resources/AboutIcon.png" ]]; then
    cp -X "$here/Resources/AboutIcon.png" "$app/Contents/Resources/"
  fi
fi

xattr -cr "$app"
codesign --force --deep --sign "$identity" "$app" 2>&1 | grep -v "replacing existing signature" || true
echo "installed $app (version: $version [$build_num], signed: ${identity})"

if [[ " $* " == *" --open "* ]]; then
  osascript -e "quit app \"$app_name\"" 2>/dev/null || true
  sleep 0.5
  open "$app"
fi
