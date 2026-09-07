# EasyPlay

A Mac launcher for Windows games, built on top of Wine.

EasyPlay does not translate Windows APIs, emulate x86, or implement any part of
DirectX. Those problems are solved — by [Wine](https://www.winehq.org), by
[DXVK](https://github.com/doitsujin/dxvk), by Apple's Rosetta 2 and D3DMetal.
What isn't solved is *using* them: a working setup means hand-built prefixes,
DLL override tables, environment variables nobody documents, and error messages
written for Wine developers.

EasyPlay is a thin, well-behaved layer over tools that already work. It creates
the prefix, applies a known-good configuration for the game you're installing,
runs the installer, and gives you a Play button. When something breaks, it tells
you what broke in a sentence instead of handing you 400 lines of `err:module:`.

---

## What it does

| | |
|---|---|
| **Checks your Mac** | Apple Silicon, Rosetta 2, Homebrew, a Wine build, disk space — with a copyable command for anything missing. |
| **Manages bottles** | One isolated Windows environment per game. A game that corrupts its own configuration can be deleted without touching the others. |
| **Applies presets** | Per-game JSON "recipes" carrying Windows version, DLL overrides, graphics translator, environment variables and Winetricks verbs. |
| **Guides installs** | Drag in a Windows installer; EasyPlay recognises it, builds a matching bottle, and runs it. |
| **Launches games** | One button. All the Wine configuration was applied earlier. |
| **Explains failures** | Wine's output is pattern-matched against known problems and rendered as plain English with a fix button where one exists. |
| **Rates compatibility** | Runs Great / Runs OK / Untested / Not Supported, per preset, with the source of the rating. |
| **Proves the graphics path** | `easyplay probe` inspects a running game and reports which translator it is *really* using — Wine falls back silently, and a game on the wrong renderer runs badly rather than failing. |

## What it deliberately does not do

- **No new translation layer.** EasyPlay shells out to an installed Wine. There
  is no emulation, hypervisor, or Win32 reimplementation anywhere in this repo,
  and there never will be.
- **No kernel anti-cheat.** Games using Vanguard, EasyAntiCheat or BattlEye
  cannot work under Wine — the anti-cheat needs a Windows kernel driver, and
  Wine implements Windows' user space, not its kernel. EasyPlay refuses these by
  name and explains why rather than failing mysteriously. Attempting to bypass
  anti-cheat also risks your account.
- **No accounts, no cloud, no preset server.** Presets are JSON files on disk.
  You can read them, edit them, and share one by sending a file.

---

## Requirements

- Apple Silicon Mac (M1 or later), macOS 14+
- Rosetta 2 — Windows game binaries are x86-64
- [Homebrew](https://brew.sh)
- A Wine build. EasyPlay targets Apple's Game Porting Toolkit, packaged by
  Gcenx:

  ```bash
  brew tap Gcenx/wine
  brew install --cask gcenx/wine/game-porting-toolkit
  brew install winetricks
  ```

  > The official `wine-stable`, `wine@devel` and `wine@staging` casks were
  > disabled in homebrew-cask on 2026-09-01 for failing macOS Gatekeeper checks,
  > so they are not currently an installable path. EasyPlay detects them if you
  > have them, but recommends Game Porting Toolkit, which is also the only one of
  > the three with Metal-backed DirectX.

EasyPlay's setup screen checks all of this and offers to run the install for you.

## Building

No Xcode required — the project builds with the Command Line Tools alone.

```bash
git clone <this repo> && cd EasyPlay
./Scripts/build-app.sh release
open build/EasyPlay.app
```

Run the tests:

```bash
swift run easyplay-tests
```

## The command line

Every operation the app performs is also a CLI command. The GUI is the product,
but the CLI keeps the engine honest — logic that only works when a SwiftUI view
drives it is logic in the wrong place.

```bash
swift run easyplay doctor                 # check this Mac
swift run easyplay recipes                # list presets
swift run easyplay recipes ride-4         # inspect one
swift run easyplay bottle-create "RIDE 4" --recipe ride-4
swift run easyplay verify <bottle-id>     # prove the bottle runs Windows programs
swift run easyplay install setup.exe --bottle <id>
swift run easyplay games
swift run easyplay play <game-id>
```

## Current status

Verified on an M4 Mac running macOS 26.5.2 with Game Porting Toolkit 3.0
(Wine 7.7):

- Environment detection, including deduplicating the Homebrew symlinks that make
  one Wine installation look like two
- Bottle creation, Windows-version and DLL-override registry configuration
- **The full install flow, end to end**: a real Windows installer
  (7-Zip 23.01 x64) auto-matched to its preset by filename, a bottle created and
  configured, the installer run silently under Wine, the resulting `7zFM.exe`
  located by glob, and the program launched and confirmed running as a live
  `wine64` process before being shut down cleanly
- **The DirectX 11 path, proven end to end**: a 64-bit DX11 benchmark launched
  through EasyPlay maps `D3DMetal.framework`, `libmetalirconverter` (DXIL to
  Metal IR shader conversion) and the `AGXMetalG16G` Apple GPU driver — DirectX
  11 reaching an M4 GPU through Metal. `easyplay probe <game-id>` reports this
  for any game, so "configured for D3DMetal" and "actually using D3DMetal" can
  be told apart
- 83 unit checks across the environment builder, glob matcher, log classifier
  and preset loader — including a regression case built from the real install
  log, asserting that Wine's harmless shortcut-builder errors raise no false
  alarm

Not yet verified end to end: the RIDE 4 preset itself. Its rating is inherited
from CrossOver's published compatibility database, not from a local run — the
game isn't owned yet. `COMPATIBILITY.md` says exactly which settings are
reasoned and which are measured, and the preset is labelled accordingly in the
UI. The Steam-based install path it needs is also still unwritten.

---

## Credits

EasyPlay is a wrapper. The hard parts belong to other people:

- **[Wine](https://www.winehq.org)** — the compatibility layer that runs the
  games. LGPL-2.1.
- **[Apple Game Porting Toolkit / D3DMetal](https://developer.apple.com/games/)**
  — DirectX 11 and 12 translated to Metal, packaged for Homebrew by
  **[Gcenx](https://github.com/Gcenx)**.
- **[DXVK](https://github.com/doitsujin/dxvk)** and
  **[MoltenVK](https://github.com/KhronosGroup/MoltenVK)** — the Vulkan route,
  supported as a per-preset option.
- **[Winetricks](https://github.com/Winetricks/winetricks)** — Windows runtime
  installation.
- **[CodeWeavers](https://www.codeweavers.com/compatibility)** — the public
  compatibility database the first presets draw their ratings from.
- **[Whisky](https://github.com/Whisky-App/Whisky)** — the SwiftUI Wine wrapper
  that proved this idea and was archived in 2025. EasyPlay is not derived from
  its code; the preset layer is what it never had.
