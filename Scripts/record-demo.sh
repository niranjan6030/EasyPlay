#!/bin/bash
#
# Records the README demo GIF by driving the real app.
#
# Nothing here is staged: it launches the built app, navigates it through the
# accessibility API, and screen-records the window. Re-run it whenever the UI
# changes and the demo stays honest.
#
# Requires: the app built (Scripts/build-app.sh), ffmpeg, an unlocked screen,
# and at least one installed game so the Library isn't empty.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/EasyPlay.app"
OUT="$ROOT/docs/screenshots/demo.gif"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

X=70; Y=60; W=1100; H=700
DURATION=42

if python3 -c "import Quartz,sys; d=Quartz.CGSessionCopyCurrentDictionary(); sys.exit(1 if (d and d.get('CGSSessionScreenIsLocked')) else 0)"; then :; else
  echo "The screen is locked — a locked screen composites no windows, so there is nothing to record." >&2
  exit 1
fi

echo "Launching the app…"
defaults delete com.easyplay.EasyPlay com.easyplay.hasSeenGuide 2>/dev/null || true
pkill -f "EasyPlay.app/Contents/MacOS/EasyPlay" 2>/dev/null || true
sleep 2
open "$APP"
sleep 7
osascript -e 'tell application "EasyPlay" to activate' >/dev/null 2>&1
sleep 1
osascript -e "tell application \"System Events\" to tell process \"EasyPlay\"
  set position of window 1 to {$X, $Y}
  set size of window 1 to {$W, $H}
end tell"
sleep 2

# Park the pointer outside the window so it doesn't sit in shot.
python3 -c "import Quartz; Quartz.CGWarpMouseCursorPosition(Quartz.CGPoint(x=$((X+W+80)), y=$((Y+H-40))))"

echo "Recording ${DURATION}s…"
screencapture -V "$DURATION" -R"$X,$Y,$W,$H" "$WORK/demo.mp4" &
CAPTURE=$!
sleep 1

# Selecting a sidebar row by its accessibility `selected` attribute is the only
# reliable way to navigate: clicking and AXPress both report success and do
# nothing to a SwiftUI List.
select_row() {
  osascript -e "tell application \"System Events\" to tell process \"EasyPlay\" to set selected of row $1 of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1 to true" >/dev/null 2>&1 || true
}

osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
-- Sidebar rows, counting section headers:
--   1 "Start here"  2 How to use EasyPlay
--   3 "Games"       4 Ask   5 Library
--   6 "Behind the scenes"   7 Bottles   8 Setup
tell application "System Events" to tell process "EasyPlay"
  -- 1. The guide, which is where a first run lands.
  delay 3

  -- 2. Ask about a game that cannot work, and one that has a Mac build.
  set selected of row 4 of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1 to true
  delay 2
  keystroke "Can I run Elden Ring?"
  delay 1
  key code 36
  delay 4
  keystroke "what about baldurs gate 3"
  delay 1
  key code 36
  delay 4

  -- 3. The library: installed games, each with one button.
  set selected of row 5 of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1 to true
  delay 3

  -- 4. The install sheet, showing a preset and where its rating came from.
  click button 2 of toolbar 1 of window 1
  delay 2
  set p to pop up button "Preset" of group 2 of scroll area 1 of group 1 of sheet 1 of window 1
  click p
  delay 1
  click menu item "RIDE 4" of menu 1 of p
  delay 4
  click button 1 of group 1 of sheet 1 of window 1
  delay 2

  -- 5. Behind the scenes: the isolated Windows environment per game.
  set selected of row 7 of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1 to true
  delay 3

  -- 6. The setup check — a good place to finish, since it shows the engine.
  set selected of row 8 of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1 to true
  delay 4
end tell
APPLESCRIPT

wait $CAPTURE
echo "Converting to GIF…"

# Two passes: a palette built from the whole clip, then dithered against it.
# A dark UI banded badly with the default 256-colour palette.
ffmpeg -loglevel error -y -i "$WORK/demo.mp4" \
  -vf "fps=12,scale=900:-1:flags=lanczos,palettegen=stats_mode=diff" "$WORK/palette.png"
ffmpeg -loglevel error -y -i "$WORK/demo.mp4" -i "$WORK/palette.png" \
  -lavfi "fps=12,scale=900:-1:flags=lanczos[v];[v][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  "$OUT"

echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
pkill -f "EasyPlay.app/Contents/MacOS/EasyPlay" 2>/dev/null || true
