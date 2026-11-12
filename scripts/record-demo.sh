#!/bin/zsh
# Records a ~100 s HopTab feature tour to ~/Desktop/HopTab-demo.mov.
#
# It drives the real app with synthetic keystrokes, so for the length of the
# recording the keyboard and screen belong to the script. Before running:
#   1. Have HopTab running with at least two workspaces (it uses whatever you
#      have; the active one should hold 3+ running apps).
#   2. Put neutral windows on screen: the recording shows everything.
#   3. Quit anything with notifications you would not want on camera.
#   4. Run:  scripts/record-demo.sh   and keep your hands off for ~2 minutes.
#
# Shortcuts assumed: ⌘Tab all apps, ⌥Tab workspace apps, ⌥` workspaces,
# ⌥K palette, snap keys at HopTab defaults. Edit the key codes below if
# yours differ (Settings → Shortcuts).

set -u
OUT="${1:-$HOME/Desktop/HopTab-demo.mov}"
DURATION=${DURATION:-100}

se() { osascript -e "tell application \"System Events\" to $1"; }
pause() { sleep "$1"; }
# Hold a modifier, tap a key N times with a gap, release. Shows the overlay.
hold_tap() { # modifier keycode taps gap
  osascript <<APPLESCRIPT
tell application "System Events"
  key down $1
  delay 0.35
  repeat $3 times
    key code $2
    delay $4
  end repeat
  delay 1.6
  key up $1
end tell
APPLESCRIPT
}
type_slow() { # text
  osascript -e "tell application \"System Events\" to keystroke \"$1\""
}

echo "Recording to $OUT for ${DURATION}s. Hands off."
/usr/sbin/screencapture -v -V "$DURATION" "$OUT" &
REC=$!
pause 2

# --- Scene 1: ⌘Tab, your workspace first, everything else after (12 s)
hold_tap command 48 3 0.9
pause 1.5
hold_tap command 48 1 0.9          # back to where we were
pause 1.5

# --- Scene 2: ⌥Tab, workspace apps only (10 s)
hold_tap option 48 2 0.9
pause 1.5
hold_tap option 48 1 0.9
pause 1.5

# --- Scene 3: ⌥` jump between workspaces (14 s)
hold_tap option 50 1 0.9
pause 4
hold_tap option 50 1 0.9
pause 3

# --- Scene 4: ⌥K palette: search, then an action (28 s)
se 'key code 40 using option down'; pause 1.6
type_slow "chro"; pause 2.2
se 'key code 53'; pause 1
se 'key code 40 using option down'; pause 1.6
type_slow "snap left"; pause 1.6
se 'key code 36'; pause 2.5
se 'key code 40 using option down'; pause 1.6
type_slow "snap right"; pause 1.6
se 'key code 36'; pause 2.5
se 'key code 40 using option down'; pause 1.6
type_slow "snap full"; pause 1.6
se 'key code 36'; pause 2.5

# --- Scene 5: ⌥K across workspaces (10 s)
se 'key code 40 using option down'; pause 1.6
type_slow "work"; pause 2.5
se 'key code 53'; pause 1

# --- Scene 6: settle, end on the ⌘Tab overlay held open (8 s)
osascript -e 'tell application "System Events"
  key down command
  delay 0.35
  key code 48
  delay 4
  key up command
end tell'

wait $REC
echo "Done: $OUT"
