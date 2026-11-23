# Sushi.GS ("Gas Station Sushi") — Engineering Rules

- **Bundle identity:** `Sushi.GS.app`, `CFBundleName` / `CFBundleDisplayName` = `Sushi.GS`, `CFBundleIdentifier` = `io.github.mobiusgt.sushigs`.
- **In-app window title:** `Gas Station Sushi` (`WindowGroup("Gas Station Sushi")` + `.navigationTitle("Gas Station Sushi")`).
- **Design rules:** Follow `design/DESIGN-SYSTEM.md` and `docs/GLOSSARY.md`. Use tokens from `Sources/SushiGS/UI/`; never raw colors, corner radii, or animation durations.
- **Upstream separation:** Never copy-paste `sushi-batch` or `sushi-next` internals into this repository. Always delegate via `Resources/worker.py` running inside the app-managed `uv` Python 3.13 venv in `~/Library/Application Support/Sushi.GS/`.
- **Build & verify:**
  - `./build.sh` builds Release `Sushi.GS.app` into `~/Applications/Sushi.GS.app`
  - `swift test --scratch-path ~/Library/Developer/SushiGS/test-build` runs `SushiGSKitTests`
  - `tools/selftest.sh` runs in-app self-tests
  - `tools/snap.sh` captures light & dark snapshots + layout probes
  - `tools/grid-lint.sh` and `swift tools/check-layout.swift /tmp/SushiGS-shots/*-layout.json` verify layout
  - `scripts/build_dmg.sh` builds `dist/Sushi.GS-0.1.0-arm64.dmg` + `.sha256`
