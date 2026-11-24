# Gas Station Sushi (`Sushi.GS`) — Brief

Native Apple Silicon macOS 26+ subtitle retiming and MKV batch utility powered by a managed Python worker wrapping `C1fer/sushi-batch` and `C1fer/sushi-next` (`sushi-sub-next`).

## Identity
- **System / Bundle / Dock / Finder Name:** `Sushi.GS` (`Sushi.GS.app`, `io.github.mobiusgt.sushigs`)
- **In-App Display Name & Window Title:** `Gas Station Sushi`
- **Version:** `0.1.1` (`CFBundleVersion` = `2`)
- **Repository:** `https://github.com/MobiusGT/Sushi.GS`
- **Mutable Runtime Directory:** `~/Library/Application Support/Sushi.GS/`

## Design plan
1. **Archetype:** Sidebar window (`NavigationSplitView`) + collapsible trailing Log Inspector (`.inspector`) + standard Settings window (`⌘,`) + branded About window.
2. **Information architecture:** One-level sidebar with four destinations:
   - **Single Episode** (`film`): fast 1-to-1 drop zones, explicit track selection, quick sync & merge controls.
   - **Auto Batch** (`square.stack.3d.up`): Embedded/External folder intake, multi-tier season-aware pairing table, batch track rules with per-episode overrides, queue transport, presets.
   - **Manual Batch** (`rectangle.split.3x1`): lightweight native file browser alongside resizable synchronized pairing columns (Source Video, optional Source Subtitles, Target Video) with zero auto-matching.
   - **Dependencies** (`shippingbox`): live required/optional dependency health, one-click installers, updater, and live install log.
3. **Command map:**
   - App: About Gas Station Sushi, Settings... (`⌘,`), Quit `Sushi.GS` (`⌘Q`).
   - File: Open Source File... (`⌘O`), Open Target File... (`⇧⌘O`), Add Source Media Folder... (`⌥⌘O`), Add Target Media Folder... (`⌥⇧⌘O`), Add External Subtitle Folder... (`⌃⌥⌘O`), Export Selected Log... (`⇧⌘E`), Close Window (`⌘W`).
   - Edit: Undo/Redo (`⌘Z` / `⇧⌘Z`), Copy Log (`⌥⌘C`), Select All (`⌘A`).
   - View: Show/Hide Sidebar (`⌃⌘S`), Show/Hide Inspector (`⌃⌘I`), Show/Hide Toolbar (`⌥⌘T`), Jump to Single Episode (`⌘1`), Auto Batch (`⌘2`), Manual Batch (`⌘3`), Dependencies (`⌘4`).
   - Queue: Run Sync (`⌘R`), Pause/Resume Queue (`⌥⌘P`), Cancel Active Job (`⌘.`), Retry Failed or Warned (`⇧⌘R`), Merge Completed (`⇧⌘M`), Refresh Dependencies (`⌥⌘R`).
4. **Empty states:**
   - Single Episode: crisp drag-and-drop cards inviting Source and Target selection with file-picker buttons.
   - Auto Batch: folder intake drop boxes with Embedded/External switch and Continue to Queue action.
   - Manual Batch: File Browser column inviting folder selection/drop alongside empty pairing columns ready for drops.
   - Log Inspector: calm "No Log Output Yet" empty state until a job runs or is selected.
5. **Feeling:** Confident, crisp, and immediate — native Mac craftsmanship that keeps audio-matching telemetry clear and surfaces sync warnings unmistakably.

## Look
System accent by default (`ThemeStore.defaultID = "system"`), with a warm Tamago Gold brand accent when the Mac accent is Multicolor. Light and dark mode follow macOS.
