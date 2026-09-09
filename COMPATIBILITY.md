# Compatibility presets

A preset ("recipe") is everything EasyPlay needs to turn a bare Wine prefix into
one that runs a specific game. This document explains the reference preset
setting by setting, then gives the process for adding a new one.

Presets live in `Sources/EasyPlayKit/Resources/Recipes/*.json` and are copied
into `EasyPlay.app/Contents/Resources/Recipes`. Users can override any shipped
preset by dropping a file with the same `id` into
`~/Library/Application Support/EasyPlay/Recipes/`.

---

## Reference: RIDE 4

Milestone's motorcycle racing game — Unreal Engine 4, DirectX 11, no anti-cheat,
distributed through Steam.

> **Verification status.** The `runsGreat` rating is inherited from CodeWeavers'
> published CrossOver compatibility database, not from a local run. Every setting
> below is reasoned from what the game is and what the engine provides, and is
> labelled as such. When the preset is verified locally, `lastVerified` and
> `source` change, and this note goes away.

### Why this game is the proof-of-concept

| Property | Consequence |
|---|---|
| DirectX 11 | The best-supported path on Apple Silicon. D3DMetal handles DX11 natively; DXVK's macOS fork also covers it. |
| Unreal Engine 4 | Extremely well-trodden under Wine. Whatever breaks, it breaks in a way someone has already documented. |
| No kernel anti-cheat | Nothing structurally prevents it running. |
| Steam-distributed | Forces the harder install path early, rather than designing around a convenient `setup.exe` and discovering later that no real game ships one. |
| ~50 GB | Realistic. Surfaces disk-space checks and long-running progress reporting that a toy game would not. |

### The settings

```json
"requires": { "backend": "gamePortingToolkit", "rosetta": true, "diskGB": 60 }
```

**`backend: gamePortingToolkit`** — the preset is tuned for the D3DMetal-bearing
Wine build. On a stock WineHQ build the same game would fall back to WineD3D and
run at a fraction of the frame rate, so the requirement is recorded rather than
assumed.

**`rosetta: true`** — RIDE 4's binaries are x86-64. On Apple Silicon nothing runs
without Rosetta 2. This is a hard blocker, and EasyPlay reports it as one.

**`diskGB: 60`** — the game is roughly 50 GB, plus the bottle and headroom for
the installer's temporary files.

```json
"bottle": { "windowsVersion": "win10", "architecture": "win64", "retinaMode": true }
```

**`win10`** — UE4 titles of this generation check for Windows 10 and refuse
older versions. Wine defaults to reporting Windows 7 in some configurations.

**`win64`** — RIDE 4 ships 64-bit only. A 32-bit bottle would fail with "not a
valid Win32 application", which `LogClassifier` recognises and explains.

**`retinaMode: true`** — without it Wine renders at a logical resolution and the
result is visibly soft on a Retina display. This is a Wine-specific Mac driver
setting written to `HKCU\Software\Wine\Mac Driver`.

```json
"graphics": { "backend": "d3dMetal", "dxvk": { "version": "1.10.3", "async": true } }
```

**`d3dMetal`** — DirectX 11 straight to Metal. This is the setting that decides
whether the game is playable or a slideshow.

The `dxvk` block is kept populated even though it is unused, so switching
translators is a one-word edit rather than a research exercise. DXVK is the
fallback if D3DMetal ever regresses for this title: it covers DX11, but reaches
Metal via MoltenVK — one more translation, and the macOS fork has not been
updated since May 2023.

```json
"dllOverrides": {
  "d3d11": "builtin", "d3d12": "builtin", "dxgi": "builtin",
  "nvapi": "disabled", "nvapi64": "disabled"
}
```

**`builtin` for the DirectX DLLs** — this is the subtle one. On Game Porting
Toolkit, Wine's *built-in* `d3d11` and `dxgi` **are** Apple's D3DMetal
implementation. Choosing D3DMetal therefore means preferring built-in over
native. It reads backwards if you are used to DXVK, where the same intent
requires `native` because DXVK ships its own PE DLLs into the prefix.

**`nvapi` disabled** — NVIDIA's driver API does not exist on a Mac. UE4 titles
probe for it; letting the probe fail cleanly is faster and quieter than letting
Wine emulate a stub.

```json
"environment": {
  "WINEESYNC": "1", "WINEMSYNC": "1",
  "ROSETTA_ADVERTISE_AVX": "1", "MTL_HUD_ENABLED": "0"
}
```

**`WINEESYNC` / `WINEMSYNC`** — Wine's faster synchronisation primitives,
replacing the default server round-trip for every wait. Matters for a game with
many threads, which every modern engine is.

**`ROSETTA_ADVERTISE_AVX`** — lets Rosetta advertise AVX support to translated
code. Game code compiled with AVX paths will otherwise take a slower fallback,
or refuse to start.

**`MTL_HUD_ENABLED: 0`** — explicitly off. Apple's Metal HUD is genuinely useful
for diagnosing frame rate, and this is where it gets turned on.

Not set here: `DYLD_FALLBACK_LIBRARY_PATH` and `WINEDLLOVERRIDES`. Both are
computed by `WineRunner` from the detected backend, because both depend on where
Wine is installed — which a portable preset cannot know.

```json
"install": { "kind": "steam", "steamAppID": "1259980" }
```

RIDE 4 has no standalone installer. EasyPlay installs the Steam client into the
bottle, the user signs in and downloads the game, and EasyPlay resumes.

> The app ID is **1259980**. A plausible-looking 1024650 is Port Royale 4 — this
> was caught by a unit test during development, which is why the assertion is
> still in the suite.

```json
"launch": { "executableGlob": "**/RIDE4.exe", "workingDirectoryFromExecutable": true }
```

A glob rather than a path, because Steam's install location varies by library
folder and the preset cannot hard-code it. Where several executables match,
`ExecutableFinder` picks the largest — games ship small launcher and
crash-handler binaries beside the real one.

`workingDirectoryFromExecutable` runs the game from its own folder. Many games
load assets by relative path and fail without it, in ways that look like
corrupted installs.

### The known-issue table

```json
"knownIssues": [
  { "match": "err:module:import_dll.*(MSVCP140|VCRUNTIME140)",
    "title": "Missing Visual C++ runtime",
    "fix":   "The game needs Microsoft's C++ runtime, which isn't in this bottle yet. EasyPlay can install it for you.",
    "action": "winetricks:vcrun2019" }
]
```

Each entry is a regex over Wine's output, a human title, an explanation, and an
optional machine-actionable `action` the UI renders as a button.

Recognised actions: `winetricks:<verb>`, `graphics:<backend>`, `steam:start`,
`bottle:recreate`. Unknown actions are rejected at parse time rather than shown
as a button that does nothing.

**Write the `fix` text for someone who has never heard of Wine.** "Install
vcrun2019 into the prefix" is a description of the implementation. "The game
needs Microsoft's C++ runtime, which isn't in this bottle yet" is a description
of the problem.

---

## The 32-bit wall

The single most important constraint when writing a preset, and the one that is
invisible until you have already installed the game:

**Apple's D3DMetal is 64-bit only.** In Game Porting Toolkit 3.0:

```
lib/external/D3DMetal.framework/D3DMetal   x86_64
lib/external/libd3dshared.dylib            x86_64
lib/wine/x86_64-unix/d3d11.so              (present)
lib/wine/i386-unix/                        (does not exist)
```

There is no 32-bit host-side Direct3D module at all. A 32-bit Windows program
therefore **cannot** use D3DMetal — or DXVK — no matter what its preset asks
for. Wine silently serves its own OpenGL renderer instead.

Silently is the problem. A game in this state does not fail; it starts, runs
badly, and reports hardware that does not exist:

```
Renderer:           NVIDIA NV50 (Tesla) 4095MB
Direct3D11 desc:    NVIDIA GeForce 8800 GTX
Found feature level 10.1
```

That is wined3d's emulated adapter. Nothing in Wine's log says a fallback
happened. Someone debugging this would reasonably conclude their preset was
wrong, and could spend hours on it.

EasyPlay reads the PE header before launching and says so instead:

> **D3DMetal (Apple) can't be used by this program**
> Unigine Heaven Benchmark is a 32-bit program, and D3DMetal (Apple) only works
> with 64-bit ones. Wine will fall back to its built-in renderer, which is much
> slower. This is a limit of the compatibility engine, not something a preset can
> change.

### Telling the two apart at a glance

The renderer a title reports is the quickest tell:

| | 32-bit, fell back to wined3d | 64-bit, using D3DMetal |
|---|---|---|
| Adapter name | `NVIDIA GeForce 8800 GTX` | `AMD Compatibility Mode` |
| Video memory | 4095 MB (invented) | the Mac's real unified memory |
| Feature level | 10.1 | 11+ |

Both names are fictional — neither GPU is in the machine — but they are fictional
in different, recognisable ways. `EasyPlay probe <game-id>` answers the same
question directly, by listing the graphics libraries the running process has
actually loaded.

**So: check the architecture first.** `file "SomeGame.exe"` reporting `PE32
executable ... Intel 80386` means `graphics.backend` must be `wineD3D`, and the
game will be slow. `PE32+ ... x86-64` is the case where D3DMetal applies. Nearly
every game from the last decade is 64-bit; the trap is older titles and
benchmarks.

Related: this Game Porting Toolkit build has **no Vulkan support whatsoever**
(`err:vulkan: Wine was built without Vulkan support`), so `dxvk` is not a usable
option on this backend either. On this stack the real choice is D3DMetal for
64-bit programs and WineD3D for everything else.

## Adding a preset

1. **Check it can work at all.** Kernel anti-cheat (Vanguard, EasyAntiCheat,
   BattlEye) is a hard no. Ship it as `notSupported` with an
   `unsupportedReason` — see `valorant.json`. A clear refusal is a feature; a
   preset that fails after a 40 GB download is not.

2. **Start from `ride-4.json`.** Change `id`, `title`, `publisher` and
   `installerPatterns`, and set `compatibility.rating` to `untested`. The UI
   shows an "unverified" warning for untested presets, which is honest and costs
   nothing.

3. **Identify the graphics API.** DirectX 11 or 12 → `d3dMetal`. DirectX 9 or 10
   → try `d3dMetal` first, then `dxvk`. OpenGL → `wineD3D`. Then set
   `dllOverrides` to match: **`builtin` for D3DMetal, `native` for DXVK.**

4. **Start with an empty `winetricks` array.** Add verbs only in response to a
   real failure. Every verb is minutes of install time and another thing that
   can break; speculative ones are how bottles become unreproducible.

5. **Verify, then record what you verified.**

   ```bash
   swift run easyplay bottle-create "My Game" --recipe my-game
   swift run easyplay verify <bottle-id>          # can it run Windows programs?
   swift run easyplay install setup.exe --bottle <bottle-id>
   swift run easyplay play <game-id>
   ```

6. **Turn every failure into a `knownIssues` entry.** This is the point of the
   exercise. A preset that works is useful to one person; a preset that explains
   its own failure modes is useful to everyone who tries it on a slightly
   different Mac.

7. **Set the rating honestly.**

   | Rating | Meaning |
   |---|---|
   | `runsGreat` | Playable start to finish at reasonable frame rates. |
   | `runsOK` | Playable with caveats — list every one in `notes`. |
   | `untested` | Written but not run. The default for a new preset. |
   | `notSupported` | Cannot work. Requires an `unsupportedReason`. |

   Record `lastVerified` and `source`. A rating whose provenance isn't stated is
   a rumour.

## The game catalogue

Presets say *how* to run a game. The catalogue
(`Sources/EasyPlayKit/Resources/Catalog/catalog.json`) says *whether it is worth
trying* — it backs the Ask screen and `easyplay ask`, and most of its entries
have no preset at all.

That is deliberate. Correctly telling someone "don't buy this, it can never work"
is worth more than a vague maybe, and it is the answer EasyPlay can give with the
most confidence.

Each entry records:

| Field | Why |
|---|---|
| `macNative` | A native Mac build outranks everything. The answer becomes "you don't need EasyPlay". |
| `antiCheat` | Kernel-level (`easyAntiCheat`, `battlEye`, `vanguard`, `ricochet`, `mhyprot`) is an absolute no. `vac` and `denuvo` are not kernel-level and do not block Wine by themselves. |
| `presetID` | Links to a shipped preset when one exists. |
| `verdict` | Never better than the evidence: `runsGreat` requires a native build or a preset. |
| `source` | Where the claim comes from. An entry without one is a rumour. |
| `lastReviewed` | Anti-cheat and native-build status change. An undated claim rots silently. |

**Adding an entry.** Only assert what you can point at. If a game has no known
blocker but nobody has run it, the verdict is `untested` and the advisor says so
out loud — the tests will reject a `runsGreat` that isn't backed by a native
build or a preset.

## Shipped presets

| Preset | Rating | Purpose |
|---|---|---|
| `ride-4` | Runs Great (from CrossOver's database) | The reference implementation. |
| `winemine` | Runs Great (verified locally) | Wine's own Minesweeper. Confirms a bottle can run Windows programs before you commit to a long download. |
| `7-zip` | Runs Great (verified locally) | A real Windows installer, small and free — the installer-flow smoke test. Verified end to end. |
| `unigine-superposition` | Runs Great (verified locally) | A 64-bit DirectX 11 benchmark. The proof that the DirectX-to-Metal path works: the live process maps D3DMetal, the DXIL-to-Metal-IR shader converter, and the Apple GPU driver. |
| `unigine-heaven` | Not Supported (verified failing) | A 32-bit DirectX 11 benchmark. Kept as the worked example of the 32-bit wall above — and of a title that fails for architectural reasons rather than policy ones. |
| `valorant` | Not Supported | Demonstrates refusing a game properly, with a reason. |
