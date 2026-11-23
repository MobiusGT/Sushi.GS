# Gas Station Sushi (`Sushi.GS`)

A native Apple Silicon (`arm64`) **macOS 26+** SwiftUI subtitle retiming and MKV batch utility that wraps **[`C1fer/sushi-batch`](https://github.com/C1fer/sushi-batch)** and **[`C1fer/sushi-next`](https://github.com/C1fer/sushi-next)** (`sushi-sub-next`) via a headless, app-managed Python 3.13 worker.

- **System / Finder / Dock Name:** `Sushi.GS` (`Sushi.GS.app`)
- **In-App Brand & Window Title:** **Gas Station Sushi**
- **Current Release:** `0.1.0`
- **Repository:** https://github.com/MobiusGT/Sushi.GS

---

## Features

- **Single Episode & Batch Modes**
  - **Single Episode:** Drag-and-drop Source media, Target media, and optional external `.ass`/`.srt`/`.ssa` subtitles (or choose embedded subtitle tracks directly from the Source file).
  - **Batch Queue:** Drop Source & Target folders (or multiple files), auto-pair episodes by episode number (`S01E01`, ` - 01 `, `[01]`, `EP01`, `OVA 01`, etc.), fix mismatches manually in an editable pairing table, apply batch-wide track rules with per-episode overrides, and manage reusable presets.
- **Granular Track & Subtitle Selection**
  - Inspects every file with `ffprobe` (and `mkvmerge -J` for Matroska files) showing stream ID, language, codec, channel layout, sample rate, title, and default/forced flags.
  - Explicitly match any Source audio track against any Target audio track (e.g., Source Audio Track 2 ↔ Target Audio Track 3) and select one or more embedded subtitle tracks or an external subtitle file.
- **Live Log Inspector & Automatic Audio-Matching Warnings**
  - Real-time streaming Log Inspector (`⌃⌘I`) with search, `All` / `Warnings` / `Errors` filtering, copy, and `.log` export.
  - Automatically flags high audio-matching diff scores, max-window fallbacks, broken/uncommitted segments, sudden shift jumps, large average shifts, chapter grouping inconsistencies, keyframe mismatches, and pipeline warnings with a prominent **Warning** badge, summary banner, and one-click **Jump to Warning** navigation.
- **Full `sushi-batch` + `sushi-next` Capabilities**
  - 24 kHz HQ audio resampling, advanced window/smoothing/typesetting args, chapters, and keyframe snapping.
  - Optional automatic or manual **MKVMerge** muxing (metadata copy toggles, default/forced flags, custom subtitle track titles, and optional cleanup of temporary files).
  - Pre-merge lossless audio re-encoding (**Opus**, **AAC**, **EAC-3** with per-channel-layout bitrates).
  - Optional **Aegisub-CLI** subtitle resolution resampling before merge when `aegisub-cli` is installed.
- **Zero-Terminal In-App Dependency Manager**
  - First-launch setup installs official Apple Silicon `uv`, managed Python 3.13, `sushi-batch` (+ `sushi-sub-next`), and standalone native `arm64` `ffmpeg` / `ffprobe` directly inside `~/Library/Application Support/Sushi.GS/`.
  - One-click updates with post-update compatibility self-checks, plus optional installers for `mkvmerge`, `opusenc`, and guided setup for `aegisub-cli`.

---

## Installation (`Sushi.GS-0.1.0-arm64.dmg`)

1. Download **`Sushi.GS-0.1.0-arm64.dmg`** (and optionally verify **`Sushi.GS-0.1.0-arm64.dmg.sha256`**) from [GitHub Releases](https://github.com/MobiusGT/Sushi.GS/releases).
2. Open the `.dmg` and drag **`Sushi.GS.app`** into **`Applications`**.
3. Launch **`Sushi.GS`** from `/Applications`, Spotlight, or Launchpad.
4. On first launch, click **Install Required Dependencies** in the Dependencies view to provision `uv`, Python 3.13, `sushi-batch`, `ffmpeg`, and `ffprobe` automatically.

### Opening Ad-Hoc Signed Builds on macOS Gatekeeper

Direct GitHub Release builds without a paid Apple Developer ID certificate are ad-hoc signed. If macOS displays an *"Apple could not verify Sushi.GS is free of malware"* warning on first launch:

- **Option 1 (System Settings):** Attempt to open `Sushi.GS.app`, then go to **System Settings → Privacy & Security**, scroll to Security, and click **Open Anyway**.
- **Option 2 (Terminal):** Clear the download quarantine attribute once:
  ```bash
  xattr -cr /Applications/Sushi.GS.app
  ```

---

## Building from Source

Requires an Apple Silicon Mac running **macOS 26+** with **Xcode 26/27+** (Swift 6.2+ toolchain).

```bash
git clone https://github.com/MobiusGT/Sushi.GS.git
cd Sushi.GS

# Run Swift Testing unit tests
swift test

# Build Release arm64 bundle into ~/Applications/Sushi.GS.app
./build.sh --open

# Package a GitHub-shareable .dmg + .sha256 into dist/
scripts/build_dmg.sh
```

### Optional Developer ID Signing & Notarization

`scripts/build_dmg.sh` defaults to ad-hoc signing (`-`). To sign and notarize a release `.dmg` with your Apple Developer account, set:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-profile" \
scripts/build_dmg.sh
```

*(Alternatively, supply `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD` instead of `NOTARY_PROFILE`.)*

---

## Architecture & Upstream Updateability

`Sushi.GS` intentionally does **not** fork or vendor `sushi-batch` or `sushi-next` source code. Instead:
- The SwiftUI frontend bundles a thin headless Python adapter (`Contents/Resources/worker.py`).
- All mutable runtime state (`uv`, managed Python 3.13, the `sushi-batch` virtual environment, downloaded binaries, presets, and logs) lives strictly in `~/Library/Application Support/Sushi.GS/`.
- Updating to a newer upstream `C1fer/sushi-batch` release takes one click inside **Dependencies** (with an automatic headless compatibility self-check).
- No third-party GPL/LGPL binaries (`ffmpeg`, `mkvmerge`, etc.) are bundled inside the `.dmg`.

---

## Credits & Licenses

- **`C1fer/sushi-batch`** — https://github.com/C1fer/sushi-batch (MIT License)
- **`C1fer/sushi-next` (`sushi-sub-next`)** — https://github.com/C1fer/sushi-next (MIT License, based on `tp7/Sushi` by Victor Efimov)
- **`Sushi.GS` ("Gas Station Sushi")** — MIT License (see [LICENSE](LICENSE)).
