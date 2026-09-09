# Architecture

## The problem this solves

Windows games already run on Apple Silicon. Wine translates the Win32 API,
Rosetta 2 translates x86-64 instructions, and Apple's D3DMetal translates
DirectX to Metal. All three are free, mature, and installable in about five
minutes.

Almost nobody uses them, because the workflow looks like this:

```bash
brew tap Gcenx/wine
brew install --cask gcenx/wine/game-porting-toolkit
export WINEPREFIX=~/mygame
/Applications/Game\ Porting\ Toolkit.app/Contents/Resources/wine/bin/wine64 wineboot --init
wine64 reg add 'HKCU\Software\Wine' /v Version /d win10 /f
wine64 reg add 'HKCU\Software\Wine\DllOverrides' /v d3d11 /d builtin /f
export DYLD_FALLBACK_LIBRARY_PATH=".../lib/external:.../lib:/usr/lib"
export WINEDLLOVERRIDES="d3d11,dxgi=builtin;nvapi=disabled"
export WINEESYNC=1 WINEMSYNC=1 ROSETTA_ADVERTISE_AVX=1
wine64 setup.exe
# ...and when it fails:
# 0024:err:module:import_dll Library MSVCP140.dll (which is needed by
# L"Z:\\game\\RIDE4.exe") not found
```

Every line is necessary. None is discoverable. Miss the `DYLD_FALLBACK_LIBRARY_PATH`
and the game fails with a device-creation error that names nothing relevant.

**EasyPlay is a UX problem disguised as a systems problem.** The engineering
here is not translation — it is capturing that knowledge as data, applying it
correctly, and turning failures back into English.

## Shape of the system

```
┌─────────────────────────────────────────────────────────────────┐
│  EasyPlayApp (SwiftUI)        easyplay (CLI)     easyplay-tests │
│  Library · Bottles · Setup    same operations    53 checks      │
└───────────────────────────────┬─────────────────────────────────┘
                                │  every front-end is thin
┌───────────────────────────────▼─────────────────────────────────┐
│                          EasyPlayKit                            │
│                                                                 │
│  Environment/   SystemProbe · BrewClient · ToolchainDetector    │
│                 → what's installed, what's missing, how to fix  │
│                                                                 │
│  Recipes/       Recipe · RecipeLibrary                          │
│                 → per-game configuration as versionable data    │
│                                                                 │
│  Bottles/       Bottle · BottleManager · WineRunner             │
│                 → prefix lifecycle, and the Wine environment    │
│                                                                 │
│  Library/       GameInstaller · GameLauncher · ExecutableFinder │
│                 → install, locate, launch                       │
│                                                                 │
│  Diagnostics/   LogClassifier · KnownIssues                     │
│                 → Wine's stderr, rendered as advice             │
│                                                                 │
│  Support/       ProcessRunner · AppPaths                        │
└───────────────────────────────┬─────────────────────────────────┘
                                │  subprocesses only
┌───────────────────────────────▼─────────────────────────────────┐
│  wine64 · wineserver · winetricks · brew   (installed, not      │
│  Game Porting Toolkit → D3DMetal → Metal    vendored, not       │
│  Rosetta 2                                  reimplemented)      │
└─────────────────────────────────────────────────────────────────┘
```

The boundary at the bottom is the important one. EasyPlay's entire interaction
with Wine goes through `ProcessRunner` — spawn a process, set its environment,
capture its output. There is no linking against Wine, no patching it, no
vendored copy. Wine can be updated by Homebrew underneath EasyPlay and nothing
breaks.

## Decisions worth defending

### Recipes are data, not code

A preset is a JSON file. It could have been a Swift type per game, and that
would have been less work initially.

Data wins because the interesting artifact is the *knowledge*, not the program.
A recipe can be diffed, reviewed, edited by someone who doesn't write Swift, and
shipped as a fix without a new build. `installerPatterns` was added mid-project
as an optional field; every existing preset kept working, because optional keys
decode to `nil`.

The schema carries a `schemaVersion` and the loader refuses anything newer than
it understands, which is what makes future changes safe rather than a gamble.

### One bottle per game

Sharing prefixes saves disk — a Windows environment is ~350 MB before a game is
installed. It was still rejected. Shared prefixes mean one game's DLL override
can break another game months later, and the resulting bug is undebuggable for
the person experiencing it. Isolation makes "delete it and start again" a
complete and safe answer to almost every problem.

### The graphics translator is a field, not an assumption

The obvious design ships DXVK, since DXVK is what everyone associates with
DirectX-on-Linux. On Apple Silicon that is the wrong default: the macOS DXVK
fork is pinned at 1.10.3 (May 2023), covers DirectX 9–11 only, and reaches Metal
through an extra MoltenVK translation. Apple's D3DMetal targets Metal directly
and handles DirectX 12.

So `graphics.backend` is a per-recipe choice among `d3dMetal`, `dxvk` and
`wineD3D`, and `WineRunner.graphicsOverrides(for:)` maps that choice onto the
right DLL load order — built-in for D3DMetal (on Game Porting Toolkit the
built-in `d3d11` *is* D3DMetal), native for DXVK (which ships its own PE DLLs
into the bottle). Getting this backwards produces a game that runs at a tenth of
its frame rate with no error message, which is exactly the class of failure the
project exists to prevent, so it is unit-tested.

### A CLI nobody was asked for

The deliverable is a Mac app. The CLI exists anyway, and it earned its place
twice over: it let the whole engine be built and verified before a line of
SwiftUI existed, and it means the engine cannot quietly grow a dependency on
being driven by a view. `swift run easyplay verify <bottle>` performs the exact
operation the app's "Check" button performs, through the exact same code.

### Errors are a feature, not error handling

`LogClassifier` is the difference between EasyPlay and a shell script. It
matches Wine's output against patterns from two sources — the current game's
recipe first, then a global set — and produces a `Diagnosis`: a title, an
explanation in plain language, and where possible a `Remedy` the UI renders as a
button that fixes it.

Three rules keep it honest:

1. **A per-game explanation always outranks a generic one.** Tested.
2. **No fix is offered where no fix exists.** Anti-cheat is detected and
   explained with no button attached, because a button that cannot work is worse
   than no button.
3. **The raw log is never hidden**, only demoted — one disclosure triangle down.

### Tests without a test framework

XCTest and swift-testing both ship with Xcode, not the Command Line Tools, and a
core goal was that this builds on a Mac without Xcode. Rather than drop testing,
`Harness` is 50 lines providing `expect` and `expectEqual` with file/line
reporting. Assertions map one-to-one onto `#expect`, so migrating is a
find-and-replace once Xcode is present.

What gets tested is chosen deliberately: the Wine environment builder, the glob
matcher, the log classifier, and preset loading. All four are pure functions
over data whose failures are silent — a wrong `WINEDLLOVERRIDES` string doesn't
throw, it just makes a game slow.

One of those tests caught a wrong Steam AppID in the RIDE 4 preset during
development (1024650 is Port Royale 4; RIDE 4 is 1259980), and another caught
that installer-filename matching couldn't recognise `7z2409-x64.exe` — which is
what added `installerPatterns` to the schema.

The CLI earned its keep the same way. Deleting a bottle through it left an
orphaned library entry, because the cascade that removes games belonging to a
deleted bottle had been written in `AppModel` — the SwiftUI layer — instead of in
`BottleManager`. The app looked correct; the engine was incomplete. That is
precisely the failure a second front-end exists to expose, and the fix moved the
cascade into the engine and added `GameStore.pruneOrphans` so the library also
heals when a bottle disappears outside EasyPlay entirely.

### Reading the PE header before trusting the preset

The graphics section above describes choosing a translator. It omits the thing
that turned out to matter more: whether the chosen translator is *possible*.

D3DMetal ships as an x86_64-only framework, and Game Porting Toolkit has no
32-bit host-side Direct3D module at all. A 32-bit game asking for D3DMetal does
not get an error — it gets Wine's OpenGL renderer, a fabricated GeForce 8800 GTX,
feature level 10.1, and a preset that looks wrong when it is not.

This was found the expensive way: by downloading a 260 MB DirectX 11 benchmark to
prove the D3DMetal path, and discovering its engine is 32-bit. That experience is
now encoded three ways — `WindowsExecutable.architecture(of:)` parses the COFF
machine field straight from the file, `WineBackend.supports(_:for:)` states the
rule, and `GameLauncher.preflight` turns a violation into a plain-English warning
before the game runs. A wasted afternoon became a check that costs microseconds.

It also produced the sharpest illustration of what this project is. Wine had all
the information needed to explain this and chose not to surface it. That gap —
between what the tool knows and what the user is told — is the entire product.

### A chatbot that refuses to guess

The natural-language front door ("can I run Elden Ring?") is the one feature
where the obvious implementation is the wrong one. Wiring it to an LLM would
answer every question about every game, fluently, in an afternoon.

It would also destroy the only property that makes this project trustworthy.
Every rating EasyPlay shows carries provenance — "CodeWeavers CrossOver
compatibility database", "Verified by EasyPlay on an M4 Mac". A generated answer
has no provenance, is confidently phrased whether right or wrong, and a wrong
"yes" costs someone a purchase and a 50 GB download. The failure mode of the
plausible-sounding guess is exactly what this project exists to remove.

So `CompatibilityAdvisor` is a rules engine over a bundled catalogue, and its
most important capability is **saying it does not know**. Rules are applied
strongest-fact-first:

1. **A native macOS build exists** → say so, and send them to the Mac version.
   The best answer EasyPlay can give is "you don't need me".
2. **Kernel anti-cheat** → structurally impossible, with the reason. No preset
   will ever fix it, so no fix is offered.
3. **A shipped preset exists** → the configuration work is already done.
4. **Nothing known blocks it** → *untested*, explicitly not a promise, with links
   to the databases the project's own ratings come from.
5. **Not in the catalogue** → "I don't have data on this", and the same links.

Fuzzy matching is deliberately gated: below a confidence threshold the advisor
returns "unknown" rather than the nearest title, because answering a different
game's question is worse than answering none. A second, higher threshold governs
"did you mean…?", so nonsense input produces no suggestions at all rather than
three unrelated games.

Two tests encode the honesty as a property rather than a habit: no catalogue
entry may claim `runsGreat` without either a native build or a real preset behind
it, and every definite answer must carry a source. Those hold for all 33 entries,
and will fail loudly if someone adds an optimistic one.

### Not sandboxed, and it can't be

EasyPlay's purpose is executing arbitrary third-party binaries from arbitrary
paths with a custom environment. That is precisely what the App Sandbox exists
to prevent. The app is ad-hoc signed and distributed as source. This closes the
Mac App Store as a distribution channel, which is the correct trade for a tool
of this kind, and it is stated rather than glossed over.

## Where it goes next

- **Steam-first installs.** Most modern PC games, RIDE 4 included, are not a
  setup file. The recipe schema already models this (`install.kind == .steam`
  plus an app ID); the flow that installs Steam into a bottle and waits for the
  download is the remaining work.
- **DXVK provisioning.** The recipe field and DLL overrides are implemented;
  downloading a DXVK release and installing its DLLs into a bottle is not.
- **Preset verification.** Ratings currently come from CrossOver's database.
  A recipe carries `lastVerified`; the honest version of this project verifies
  its own presets and says so.
