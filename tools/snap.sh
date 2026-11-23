#!/bin/zsh
# Snapshots every sidebar page and Settings tab in light & dark mode on an isolated store.
set -u
app="$HOME/Applications/Sushi.GS.app/Contents/MacOS/SushiGS"
store="/tmp/SushiGS-test-store"
shots="/tmp/SushiGS-shots"
rm -rf "$HOME/Library/Saved Application State/io.github.mobiusgt.sushigs.savedState"
rm -rf "$store" "$shots"
APP_STORE="$store" APP_SEED=1 APP_SNAPSHOT="$shots" "$app" "$@"
