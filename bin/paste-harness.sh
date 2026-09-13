#!/bin/bash
# Managed by remote-dictation's install-linux.sh - removable with --uninstall.
#
# Paste-harness: prove the CLIPBOARD-PASTE delivery layer (transcript -> clipboard -> Ctrl+V)
# with no microphone, no speech and no Wispr Flow. It delivers a test string through the very
# same paste_seg() that dictation uses, into a zenity entry field - a real GTK text widget, so
# Ctrl+V is a genuine paste - and reports whether what arrived is byte-identical.
#
#   paste-harness.sh [--text "STRING"] [--delay SECONDS] [--keep-open]
#
# IT OPENS ONE DIALOG WINDOW on your desktop for about ten seconds and closes it again.
# Run it deliberately, not in the middle of something.
#
# Why it exists: wtype cannot type accented characters at all, and that is the reason this
# delivery path exists. A test string full of accents is the point of the test, not decoration.
set -u
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE:-$(basename "$(ls -d "$XDG_RUNTIME_DIR"/hypr/*/ 2>/dev/null | head -1)")}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | head -1)")}"
[ -f "$HOME/.config/dictation.conf" ] && . "$HOME/.config/dictation.conf"

OUT="$(mktemp -t paste-harness.XXXXXX)"
TS="$(mktemp -t paste-harness-fn.XXXXXX)"
SETTLE="${DICTATE_PASTE_SETTLE:-0.15}"
TEXT=""
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --text) shift; TEXT="${1:-}" ;;
    --delay) shift; SETTLE="${1:-0.15}" ;;
    --keep-open) KEEP=1 ;;
    *) printf 'usage: %s [--text STRING] [--delay SECONDS] [--keep-open]\n' "$0" >&2; exit 2 ;;
  esac
  shift
done

# Default string carries exactly what wtype cannot do: accents, ñ/ü, inverted punctuation,
# capitals mid-sentence.
[ -n "$TEXT" ] || TEXT='Mañana, ¿qué tal? Ñandú añejo, áéíóú, ü ü. Café con leche.'

cleanup() {
  if [ "$KEEP" = 0 ]; then
    pkill -f 'zenity --title=paste-harness' 2>/dev/null
    rm -f "$OUT"
  fi
  rm -f "$TS"
  return 0
}
die() { printf 'paste-harness: %s\n' "$1" >&2; exit "${2:-1}"; }
trap cleanup EXIT

for c in zenity wl-copy hyprctl wtype python3; do
  command -v "$c" >/dev/null || die "$c is required (zenity: pacman -S zenity; wl-copy: pacman -S wl-clipboard)"
done
[ -n "$HYPRLAND_INSTANCE_SIGNATURE" ] || die "no Hyprland instance under $XDG_RUNTIME_DIR/hypr"
[ -x "$HOME/bin/dictate.sh" ] || die "run install-linux.sh first (no ~/bin/dictate.sh)"

# Never leave strays: two dialogs break the address selector below.
pkill -f 'zenity --title=paste-harness' 2>/dev/null
sleep 0.5

printf 'opening a scratch entry field (one dialog, ~10s)\n'
nohup zenity --title=paste-harness --entry --text='paste test - this window closes by itself' >"$OUT" 2>/dev/null &
sleep 2.0

addr=$(hyprctl clients -j | python3 -c '
import json, sys
print(next((c["address"] for c in json.load(sys.stdin) if "zenity" in (c.get("class") or "").lower()), ""))' 2>/dev/null || true)
[ -n "$addr" ] || die "the scratch entry field did not appear"

# Focus-follows-mouse can undo a programmatic focus at any moment, so put the window under
# the pointer AND verify before a key is sent. Never paste into an unverified window: that is
# exactly how a test string ends up in someone's editor.
cur=$(hyprctl cursorpos | tr -d ' ')
hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
hyprctl dispatch movewindowpixel "exact ${cur%,*} ${cur#*,},address:$addr" >/dev/null 2>&1
sleep 0.5
hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
sleep 0.4

act=$(hyprctl activewindow -j | python3 -c 'import json,sys; print(json.load(sys.stdin).get("address",""))' 2>/dev/null || true)
if [ "$act" != "$addr" ]; then
  die "could not focus the scratch window (active=$act want=$addr) - nothing was pasted" 3
fi
printf 'focus verified on %s\n' "$addr"

# Use the DEPLOYED function, not a copy: the point is to test what dictation actually runs.
sed -n '/^  paste_seg() {/,/^  }$/p' "$HOME/bin/dictate.sh" > "$TS"
[ -s "$TS" ] || die "could not extract paste_seg from $HOME/bin/dictate.sh"
DICTATE_PASTE_SETTLE="$SETTLE"
. "$TS"

: > "$OUT"
paste_seg "$TEXT" || die "paste_seg reported failure (wl-clipboard present? session is Hyprland?)"
# Submit the entry so zenity writes what it holds and closes.
wtype -k Return 2>/dev/null || hyprctl dispatch 'hl.dsp.send_shortcut({mods="",key="Return"})' >/dev/null 2>&1
sleep 1.0

# The stray NULs come from truncating a file another process holds open; they are not delivery.
got="$(tr -d '\000' < "$OUT" 2>/dev/null || true)"
if [ "$got" = "$TEXT" ]; then
  printf 'PASS: %d chars byte-identical through clipboard paste\n' "${#TEXT}"
  printf '  text: [%s]\n' "$got"
  exit 0
fi
printf 'FAIL: expected %d chars, arrived %d\n' "${#TEXT}" "${#got}"
printf '  want: [%s]\n' "$TEXT"
printf '  got : [%s]\n' "$got"
exit 1
