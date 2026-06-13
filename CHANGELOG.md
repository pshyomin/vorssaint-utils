# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [2.4.4] — 2026-06-12

Stability pass over the whole project — same behavior, fewer ways to fail.

### Fixed
- **Self-update is fail-safe**: the new version is fully copied next to the app
  before the old one is removed, so a failed download/copy can never leave you
  without an app
- **Uninstaller**: scan results landing after you picked a different app are
  discarded (files of app A can no longer be listed under app B); display names
  only strip a trailing ".app"
- **Cut & paste**: an unexpected Accessibility value can no longer crash the
  app from inside the keyboard tap, and a cut superseded by a copy elsewhere
  now dismisses its HUD instead of lingering
- **Shelf**: an image dragged from a web page is kept as an image, not as a
  link to the page

### Changed
- Periodic timers gained tolerances so macOS can coalesce wakeups (less power)
- Internal dedup: one screen-under-mouse helper and one HUD backdrop shared by
  all floating panels; CI workflows moved to the actions' Node 24 lines

## [2.4.3] — 2026-06-12

### Changed
- **Shelf**: tiles are now AppKit-backed so you can select several items (click
  to select) and drag them all out in a single drag

### Fixed
- **Shelf**: you can move the panel again — drag its top bar to reposition it,
  while grabbing a tile still drags the item
- **Shelf**: dropping item(s) somewhere now removes them from the shelf
  automatically (a cancelled drag keeps them)

## [2.4.2] — 2026-06-12

### Fixed
- **Uninstaller**: granting Full Disk Access now actually works. The app
  registers itself with the system first, so it appears (with a toggle) in the
  System Settings list instead of opening to a list it isn't in, and a short
  hint explains how to enable it

## [2.4.1] — 2026-06-12

### Fixed
- **Shelf**: dragging an item out of the shelf now works. The panel no longer
  moves with the pointer, so grabbing a tile starts an item drag instead of
  dragging the whole window
- **Shelf**: shaking the mouse while *moving a window* no longer summons the
  shelf — it appears only when something droppable (a file, image, text or link)
  is actually being dragged

## [2.4.0] — 2026-06-12

### Added
- **Cut & paste files in Finder**: ⌘X cuts the current selection and ⌘V moves it
  into the folder you're viewing, with a floating HUD showing the held items.
  Text fields keep their normal shortcuts. Opt-in
- **Quit on last window close**: when an app that had a window closes its last
  one, it quits — with a per-app exception list (Finder excepted by default).
  Opt-in
- **Complete app uninstaller**: drag an app (or pick one) to find the caches,
  preferences, logs, containers and other files it leaves behind, each with its
  size, then move the selected ones to the Trash and see the space recovered.
  Opt-in
- **Temporary shelf**: a floating area, summoned at the cursor with ⌃⌥⌘D or by
  shaking the mouse mid-drag, that holds files, images, text and links to drag
  back out into any app later — needs no permissions. Opt-in
- A visual onboarding page for each new feature; people updating from an earlier
  version see a one-time "what's new" pass to discover and configure them

### Changed
- Settings moved from a tab bar to a System-Settings-style sidebar, giving every
  feature its own page with room for examples and options

## [2.3.0] — 2026-06-12

### Added
- **Per-app volume mixer** in the panel: set the volume of each app holding an
  audio connection (CoreAudio process taps, macOS 14.4+). A live indicator marks
  apps playing now; volumes persist per app; 100% is untouched passthrough
- **Browser tabs are first-class in the switcher**: each Safari/Chrome/Edge/
  Brave/Vivaldi tab is its own entry

### Changed
- **Switcher is instant**: a browser tab now raises its window immediately
  instead of waiting on the tab-select script, and the panel only appears after
  a short delay so quick flicks switch with no UI
- **Tab-granular toggle**: the switcher tracks a most-recently-used order of
  individual items, so ⌘Tab toggles between two tabs of the same browser just
  like between two apps
- The CPU/GPU/memory breakdown consolidates helper processes under their app
  (one Safari row, not a dozen Web Content rows)

### Removed
- The quick-utilities panel section (hide desktop icons, show hidden files, turn
  off display, eject disks, empty Trash)

## [2.1.0] — 2026-06-12

### Added
- **Per-app resource breakdown**: tapping CPU, GPU or Memory in the panel's
  System section expands the top consumers of that resource. CPU and memory
  come from the process table; per-app GPU% is computed from the accelerator's
  per-process GPU-time counters, sampled as deltas
- **Browser tabs in the switcher**: every Safari/Chrome/Edge/Brave/Vivaldi tab
  appears as its own ⌘Tab entry (the active tab keeps the window thumbnail);
  selecting one focuses that exact tab. Toggleable in Settings › Switcher;
  macOS asks for Automation consent once per browser

## [2.0.2] — 2026-06-12

### Fixed
- **Permissions now survive updates.** Builds are signed with a stable
  self-signed identity (`Tools/setup-signing.sh` locally, shared certificate in
  CI), giving the bundle a constant designated requirement — so macOS keeps
  granted Accessibility and Screen Recording permissions across updates instead
  of dropping them. Falls back to ad-hoc signing on a fresh clone.

### Changed
- The installer **DMG is styled**: a window with the app icon, an arrow and the
  Applications folder for a proper drag-and-drop install.

### Docs
- README/switcher wording updated to ⌘Tab-only (the ⌥Tab option is gone).

## [2.0.1] — 2026-06-12

### Added
- **Automatic updates**: the app checks GitHub Releases (toggle in Settings ›
  General, plus a "Check for updates" menu item), and can download the new DMG
  and self-install with a single click

### Changed
- The window switcher now **always replaces ⌘Tab** (the ⌥Tab option was removed)
- Switcher selection follows a real most-recently-used app order, so a quick
  ⌘Tab→release toggles back to the previous app — matching the system switcher

### Added (switcher)
- Press **Q** while the switcher is open to quit the highlighted app

## [2.0.0] — 2026-06-12

The app was renamed from **Vorss** to **Vorssaint Utils** and prepared for
open source distribution.

### Added
- **System monitor**: CPU/GPU/battery temperatures (SMC), CPU/GPU usage and a
  traffic-light memory pressure indicator in the panel
- **Windows-style scrolling**: invert the mouse wheel only, trackpad untouched,
  live toggle (Accessibility)
- **Window switcher**: ⌥Tab (or ⌘Tab takeover) with real window thumbnails
  (ScreenCaptureKit), multi-window support, Spaces/Mission Control friendly
- **Onboarding** in 7 steps: language, Accessibility, Screen Recording,
  monitor tour, optional features, status verification, summary
- **Bilingual interface** (pt-BR / en-US) with live language switching
- New black hole identity: app icon and menu bar glyph with distinct
  active/inactive states and a click micro-interaction
- `--sensors` diagnostic flag (SMC dump for porting to new chips)
- `--uninstall` flag and `Tools/uninstall.sh` for a clean removal (login item,
  TCC permissions, preferences, sudoers rule — no dead entries left behind)
- CI build workflow and automated DMG releases

### Changed
- Renamed to **Vorssaint Utils** (`com.vorssaint.utils`); legacy `Vorss.app`
  is removed by `./build.sh --install`
- The System section now shows only temperatures, usage and memory pressure
- Settings reorganized into General / Energy / Mouse / Switcher / About
- Project restructured into App / Core / Services / UI / Support layers

### Removed
- Clipboard history (and its settings)
- "Sleep now" quick action

## [1.1] — 2026-06-11

Initial internal release as **Vorss**: keep-awake sessions with closed-lid
mode, battery protection, clipboard history, quick utilities and system info.
