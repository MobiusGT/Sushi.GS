# <p align="center"> Sushi.GS aka Gas Station Sushi

<p align="center">
  <img src="Icon/AppIcon.icon/Assets/tamago.png" width="180" alt="Sushi.GS icon">
</p>

<p align="center">
  <a href="https://github.com/MobiusGT/Sushi.GS/releases">
    <img src="https://img.shields.io/github/v/release/MobiusGT/Sushi.GS?style=flat-square&color=blue" alt="Version">
  </a>
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B%20(Apple%20Silicon)-lightgrey?style=flat-square" alt="Platform">
</p>

A native Apple Silicon (`arm64`) **macOS 26+** SwiftUI subtitle retiming and MKV batch utility that wraps **[`C1fer/sushi-batch`](https://github.com/C1fer/sushi-batch)** and **[`C1fer/sushi-next`](https://github.com/C1fer/sushi-next)** (`sushi-sub-next`) via a headless, app-managed Python 3.13 worker.


---

## Features

- **Single Episode & Batch Queue Modes**
  - **Single Episode:** Drag-and-drop Source media, Target media, and optional external `.ass`/`.srt`/`.ssa` subtitles (or pick embedded subtitle tracks directly from the Source file), with a one-click **Clear** reset (`⇧⌘K`) to return to a clean slate.
  - **Two-Folder Batch Intake:** Drop or select both a Source folder and a Target folder before entering the pairing table, then use dedicated **Add Source Folder** (`⌥⌘O`) and **Add Target Folder** (`⌥⇧⌘O`) actions anytime.
- **Smart Multi-Tier Episode Pairing & Verification**
  - **Strict Season Safety:** Differing explicit seasons (`S01E05` vs `S02E05`, `Season 1` vs `Season 2`, `1x05` vs `2x05`) never cross-match.
  - **Auto-Verified Exact Matches:** Exact filenames or identical filename stems across different containers (e.g. `Show - 01.mkv` ↔ `Show - 01.mp4`) auto-verify immediately.
  - **Normalized Episode & Specials Cascade:** Strips release noise (`1080p`, `x265`, `10bit`, `FLAC2.0`, `[DEADBEEF]`, years), normalizes `S##E##`, leading zeroes (`005` → `5`), version tags (`01v2` → `1`), and fractional specials (`01.5` → `1.5`), conservatively matches non-numbered specials (`OVA`, `Movie`, `NCOP`/`NCED`), and leaves genuinely unmatched files clearly labeled **"No match found"** instead of forcing bad matches.
- **Explicit Track Matching & Full Sushi Controls**
  - Inspects media via `ffprobe` (and `mkvmerge -J` for MKVs) to match any Source audio track against any Target audio track and select one or more embedded or external subtitles.
  - Exposes high-value Sushi parameters inline (**24 kHz HQ**, **Window**, **Max Window**, **Keyframe Snapping**, **Chapters**) and full defaults in **Settings → Sync / Merge / Audio**, with concise hover-only descriptions to keep the workspace uncluttered.
  - Supports automatic or manual **MKVMerge** muxing, pre-merge lossless audio re-encoding (**Opus**, **AAC**, **EAC-3**), optional **Aegisub-CLI** subtitle resolution resampling, batch track rules, and reusable presets.
- **Live Log Inspector & Automatic Audio-Matching Warnings**
  - Real-time streaming Log Inspector (`⌃⌘I`) with search, `All` / `Warnings` / `Errors` filtering, copy, and `.log` export.
  - Automatically flags max-window fallbacks, broken segments, high audio diff scores, sudden shift jumps, large average shifts, chapter/keyframe inconsistencies, and pipeline warnings with a prominent warning banner and one-click **Jump to Warning**.
- **Zero-Terminal In-App Dependency Manager**
  - Installs and updates `uv`, managed Python 3.13, `sushi-batch` (+ `sushi-sub-next`), and standalone Apple Silicon `ffmpeg`/`ffprobe` directly inside `~/Library/Application Support/Sushi.GS/`, plus optional `mkvmerge`, `opusenc`, and guided `aegisub-cli` setup.

---

## Installation (`Sushi.GS-0.1.0-arm64.dmg`)

Requires an **Apple Silicon Mac running macOS 26+**.

1. Download **`Sushi.GS-0.1.0-arm64.dmg`** (and optionally **`Sushi.GS-0.1.0-arm64.dmg.sha256`**) from [GitHub Releases](https://github.com/MobiusGT/Sushi.GS/releases).
2. Open the `.dmg` and drag **`Sushi.GS.app`** into **`Applications`**.
3. Launch **`Sushi.GS`** from `/Applications`, Spotlight, or the Apps drawer (its window title bar displays **Gas Station Sushi**).
4. On first launch, click **Install Required Dependencies** in the **Dependencies** view to provision `uv`, Python 3.13, `sushi-batch`, `ffmpeg`, and `ffprobe` automatically.

### Opening Ad-Hoc Signed Builds on macOS Gatekeeper

GitHub Release builds without a paid Apple Developer ID certificate are ad-hoc signed. If macOS displays an *"Apple could not verify Sushi.GS is free of malware"* warning on first launch:

- **Option 1 (System Settings):** Try to open `Sushi.GS.app`, then open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway**.
- **Option 2 (Terminal):** Clear the download quarantine attribute once:
  ```bash
  xattr -cr /Applications/Sushi.GS.app
  ```

---

## Architecture & Upstream Updateability

`Sushi.GS` intentionally does **not** fork or vendor `sushi-batch` or `sushi-next` internals:
- The SwiftUI frontend bundles only a thin headless Python bridge (`Contents/Resources/worker.py`).
- All mutable runtime state (`uv`, Python 3.13, the `sushi-batch` virtual environment, downloaded binaries, presets, and logs) is stored strictly in `~/Library/Application Support/Sushi.GS/`.
- Updating to new upstream `C1fer/sushi-batch` releases is one click inside **Dependencies**, verified by an automatic headless compatibility self-check.
- No third-party GPL/LGPL binaries (`ffmpeg`, `mkvmerge`, etc.) are bundled inside the `.dmg`.

---

## Building from Source

Requires an Apple Silicon Mac running **macOS 26+** with **Xcode 26/27+** (Swift 6.2+ toolchain).

```bash
git clone https://github.com/MobiusGT/Sushi.GS.git
cd Sushi.GS

# Run Swift Testing unit tests
swift test

# Build Release arm64 app bundle into ~/Applications/Sushi.GS.app
./build.sh --open

# Package a GitHub-shareable .dmg + .sha256 into dist/
scripts/build_dmg.sh
```

### Optional Developer ID Signing & Notarization

`scripts/build_dmg.sh` defaults to ad-hoc signing (`-`). To sign and notarize a release `.dmg` with your Apple Developer account:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-profile" \
scripts/build_dmg.sh
```

*(Alternatively, supply `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD` instead of `NOTARY_PROFILE`.)*

---

## Credits

`Sushi.GS` ("Gas Station Sushi") is a macOS frontend built on the work of the Sushi subtitle-synchronization ecosystem:

- **[`C1fer/sushi-batch`](https://github.com/C1fer/sushi-batch)** — Batch subtitle synchronization, MKVMerge, lossless audio re-encoding, and subtitle resampling pipeline wrapped by Sushi.GS.
- **[`C1fer/sushi-next`](https://github.com/C1fer/sushi-next)** (`sushi-sub-next`) — Actively maintained Python 3.13+ continuation of Sushi powering `sushi-batch`.
- **[`FichteFoll/Sushi`](https://github.com/FichteFoll/Sushi)** (`sushi-sub`) — Python 3 port of the original Sushi script that `sushi-next` continues.
- **[`tp7/Sushi`](https://github.com/tp7/Sushi)** — The original automatic audio-based subtitle shifter by `tp7` that started the entire lineage.

### Runtime & Optional Tools

- **[`uv`](https://github.com/astral-sh/uv)** — Fast Python and virtual environment manager used for zero-terminal runtime provisioning.
- **[`FFmpeg` / `FFprobe`](https://ffmpeg.org/)** — Audio extraction, track inspection, and audio encoding.
- **[`MKVToolNix`](https://mkvtoolnix.download/)** (`mkvmerge`) — Matroska track inspection and automatic/manual MKV muxing.
- **[`opus-tools`](https://opus-codec.org/)** (`opusenc`) — Optional standalone Opus encoder.
- **[`Aegisub-CLI`](https://github.com/TypesettingTools/Aegisub)** (`aegisub-cli`) — Optional ASS subtitle resolution resampling prior to merge.

---

## AI Disclosure

This frontend was fully made by **Gemini 4 Neon Extra High**.

---

## License

`Sushi.GS` ("Gas Station Sushi") is released under the **MIT License** — see [LICENSE](LICENSE).
