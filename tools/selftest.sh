#!/bin/zsh
# Runs the in-app self-test against an isolated store in /tmp.
set -u
rm -rf "$HOME/Library/Saved Application State/io.github.mobiusgt.sushigs.savedState"
store="/tmp/SushiGS-selftest-store"
rm -rf "$store"
APP_STORE="$store" "$HOME/Applications/Sushi.GS.app/Contents/MacOS/SushiGS" --selftest
