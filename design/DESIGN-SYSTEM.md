# Design System — Gas Station Sushi (`Sushi.GS`)

Every view uses tokens from `Sources/SushiGS/UI/` — never raw hex colors, corner radii, or animation durations.

## `Theme.swift`
- `ThemeStore.defaultID = "system"` with warm Tamago Gold brand fallback when macOS accent is Multicolor (`light: 0xFCD34D`, `base: 0xEAB308`, `deep: 0xA16207`, `darkText: true`).
- Use `Palette.accent`, `Palette.accentText`, `Palette.onAccent`, and `.themed()` on every scene.

## `Grid.swift`
- 4 pt spacing scale via `Space`: `xs` (4), `sm` (8), `md` (12), `lg` (16), `xl` (20), `xxl` (24), `section` (32), `margin` (20).
- Mark custom pages and cards with `.gridArea(...)` and `.gridProbe(...)` so `tools/check-layout.swift` verifies alignment.

## `Surfaces.swift`
- Neutral translucent fills (`Surface.card`, `Surface.cardHover`, `Surface.dropZone`, `Surface.hairline`) and semantic status fills (`Surface.statusSuccess`, `Surface.statusWarning`, `Surface.statusError`, `Surface.statusRunning`).
- Every status color is paired with an SF Symbol and text label. Never color alone.

## `Radius.swift`
- `xs` (6) chips/badges, `sm` (8) controls/rows, `md` (12) cards/drop zones, `lg` (16) callout banners.
- Inner corners stay concentric (`outer - inset`).

## `Motion.swift`
- Standard curves (`Motion.hover`, `Motion.quick`, `Motion.ui`, `Motion.appear`) respecting `accessibilityReduceMotion`.
- Search and filter updates never animate.

## `WindowBehavior.swift`
- `.noInitialFocus()` on windows, sheets, and Settings tabs so nothing opens with an unwanted focus ring.
- `.fitsContent()` on Settings grouped Forms so each tab sizes cleanly without spare scrollbars.
