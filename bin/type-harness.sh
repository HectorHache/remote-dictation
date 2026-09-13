#!/bin/bash
# Managed by remote-dictation's install-linux.sh - removable with --uninstall.
#
# Type-harness: prove the DELIVERY layer (transcript -> keystrokes) with no microphone, no
# speech and no Wispr Flow. It types a test string through the very same wtype path that
# dictation uses and reports whether what arrived is byte-identical.
#
#   type-harness.sh [--delay MS] [--text "STRING"] [--keep-open]
#
# IT OPENS A TERMINAL WINDOW on your desktop: one window, about ten seconds, closed again at
# the end. Run it deliberately, not in the middle of something.
#
# Why it exists: it caught a delivery regression in a single run that reading the code twice
# did not - an "explicit Shift for capitals" change that lowercased every capital instead of
# typing it. Use it after any change to type_seg(), or when delivered text looks wrong.
set -u
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE:-$(basename "$(ls -d "$XDG_RUNTIME_DIR"/hypr/*/ 2>/dev/null | head -1)")}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | head -1)")}"
[ -f "$HOME/.config/dictation.conf" ] && . "$HOME/.config/dictation.conf"

APP=wtype-harness
FILE="$(mktemp -t type-harness.XXXXXX)"
TS="$(mktemp -t type-harness-fn.XXXXXX)"
DELAY="${DICTATE_TYPE_DELAY:-6}"
TEXT=""
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --delay)     DELAY="${2:?--delay needs a number}"; shift ;;
    --text)      TEXT="${2:?--text needs a string}"; shift ;;
    --keep-open) KEEP=1 ;;
    -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    *)           printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
# Default string deliberately carries five capitals mid-sentence, an apostrophe, a dash inside
# a word and a leading dash after a capital - every shape that has broken delivery so far.
[ -n "$TEXT" ] || TEXT="Let's Led L L I a-b -lead end I think."

cleanup() {
  [ "$KEEP" -eq 1 ] || pkill -f "foot -a $APP" 2>/dev/null
  rm -f "$FILE" "$TS"
}
die() { printf 'type-harness: %s\n' "$1" >&2; exit "${2:-1}"; }
trap cleanup EXIT

for c in foot wtype hyprctl python3; do
  command -v "$c" >/dev/null || die "$c is required (foot: pacman -S foot)"
done
[ -n "$HYPRLAND_INSTANCE_SIGNATURE" ] || die "no Hyprland instance under $XDG_RUNTIME_DIR/hypr"
[ -x "$HOME/bin/dictate.sh" ] || die "run install-linux.sh first (no ~/bin/dictate.sh)"

# Never leave strays: two harness windows break the address selector below.
pkill -f "foot -a $APP" 2>/dev/null
sleep 1

printf 'opening a scratch terminal (app-id %s) - one window, ~10s\n' "$APP"
nohup foot -a "$APP" -T "$APP" bash -c "stty -icanon -echo; stdbuf -o0 cat > '$FILE'" >/dev/null 2>&1 &
sleep 2.5

addr=$(hyprctl clients -j | APP="$APP" python3 -c '
import json, os, sys
app = os.environ["APP"]
print(next((c["address"] for c in json.load(sys.stdin) if c["class"] == app), ""))' 2>/dev/null || true)
[ -n "$addr" ] || die "the scratch terminal did not appear"

# Focus-follows-mouse can undo a programmatic focus at any moment, so put the window under the
# pointer AND verify before a single key is sent. Never type into an unverified window: that is
# exactly how a test string ends up in someone's editor.
cur=$(hyprctl cursorpos | tr -d ' ')
hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
hyprctl dispatch movewindowpixel "exact ${cur%,*} ${cur#*,},address:$addr" >/dev/null 2>&1
sleep 0.5
hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
sleep 0.4

act=$(hyprctl activewindow -j | python3 -c 'import json,sys; print(json.load(sys.stdin).get("address",""))' 2>/dev/null || true)
if [ "$act" != "$addr" ]; then
  other=$(hyprctl activewindow -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s (%s)" % (d.get("class","?"), d.get("title","")[:40]))' 2>/dev/null || echo "?")
  die "focus check FAILED - keys would have gone to $other. Move nothing and re-run." 3
fi
printf 'focus verified on %s\n' "$addr"

# Use the DEPLOYED function, not a copy: the point is to test what dictation actually runs.
sed -n '/^  type_seg() {/,/^  }$/p' "$HOME/bin/dictate.sh" > "$TS"
[ -s "$TS" ] || die "could not extract type_seg from $HOME/bin/dictate.sh"
TYPE_DELAY="$DELAY"
. "$TS"

: > "$FILE"; sync; sleep 0.2
type_seg "$TEXT"
sleep 0.8

# The stray NULs come from truncating a file another process holds open; they are not delivery.
got=$(tr -d '\000' < "$FILE")
caps=$(printf '%s' "$TEXT" | tr -cd 'A-Z' | wc -c)

if [ "$got" = "$TEXT" ]; then
  printf 'PASS: %d chars byte-identical (%d capitals, delay %sms)\n' "${#TEXT}" "$caps" "$DELAY"
  exit 0
fi
printf 'FAIL: expected %d chars, arrived %d\n' "${#TEXT}" "${#got}"
printf '  want: [%s]\n' "$TEXT"
printf '  got : [%s]\n' "$got"
exit 1
