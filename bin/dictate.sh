#!/bin/bash
# Managed by remote-dictation's install-linux.sh - removable with --uninstall.
# Push-to-talk dictation through Wispr Flow (running on the Mac Mini).
#   dictate.sh start   <- key press
#   dictate.sh stop    <- key release
#
# Voice path: internal mic -> Dictation Mic (PipeWire) -> roc-send -> tailnet
#             -> Roc receiver on the Mac -> Wispr Flow -> flow.sqlite History row
# Text path:  History row -> wtype -> whatever window has focus on the Linux machine
set -u
# Derived from OUR uid: hardcoding /run/user/1000 breaks on every account that is not
# uid 1000, which is most of them.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"

# User-tunable settings. The keybind runs this with the COMPOSITOR's environment, not
# your shell's, so exported variables in ~/.zshrc never reach it. This file does.
[ -f "$HOME/.config/dictation.conf" ] && . "$HOME/.config/dictation.conf"

DELIVERY="${DICTATE_DELIVERY:-type}"       # type | paste
TYPE_DELAY="${DICTATE_TYPE_DELAY:-0}"      # ms between keystrokes
TAIL_GRACE="${DICTATE_TAIL_GRACE:-0.5}"    # seconds to keep recording after release
URGENCY="${DICTATE_NOTIFY_URGENCY:-normal}"
NEWLINE_MODE="${DICTATE_NEWLINE:-space}"  # space | shift-enter | enter

MAC="${DICTATE_MAC:-}"   # required: no default host ships with the package
# Flow's database path belongs to the REMOTE user's home, so it is never hardcoded:
# /Users/<name> is wrong on every machine but the one it was written on. Resolved over
# ssh on first use, then cached - this lookup sits on the press path.
DB="${DICTATE_DB:-}"
DB_CACHE="$HOME/.dictation-remote-db"
MARKER=/tmp/dictate-marker
TIMING=/tmp/dictate-timing.log
NOTIFY_LOG=/tmp/dictate-notify.log
now_ms() { date +%s%3N; }

# Omarchy's shell (quickshell) only displays toasts sent by its OWN notifier.
# Plain notify-send returns exit 0 and shows nothing - verified on this machine,
# where a notify-send test toast never appeared but an omarchy-notification-send
# one did. Errors go to a log instead of /dev/null so this cannot hide again.
# Urgency: "normal" toasts auto-expire in a few seconds; "critical" persists until
# dismissed. Override with DICTATE_NOTIFY_URGENCY=critical if you keep missing them.
# Urgency "normal" auto-expires in a few seconds; "critical" persists until it is
# dismissed. We exploit that: the listening toast is critical so it survives the whole
# utterance, then we dismiss it by summary on release. No notification hub needed.
URGENCY="${DICTATE_NOTIFY_URGENCY:-normal}"
NEWLINE_MODE="${DICTATE_NEWLINE:-space}"  # space | shift-enter | enter
notify() {
  local urgency="${2:-$URGENCY}" rc
  omarchy-notification-send -u "$urgency" "Dictation" "$1" >/dev/null 2>>"$NOTIFY_LOG"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    notify-send -a Dictation "Dictation: $1" >>"$NOTIFY_LOG" 2>&1
  fi
  echo "$(date +%H:%M:%S) notify rc=$rc urgency=$urgency len=${#1}" >> "$NOTIFY_LOG"
}
notify_dismiss() { omarchy-notification-dismiss "Dictation" >/dev/null 2>&1; }
restore_machine() { "$HOME/bin/dictation-mic.sh" stop >/dev/null 2>&1; }

# ssh -n is required: without it these calls read the caller's stdin and swallow it.
mac()  { ssh -n -o BatchMode=yes -o ConnectTimeout=8 "$MAC" "$@"; }
remote_db() {
  if [ -z "$DB" ]; then
    if [ -s "$DB_CACHE" ]; then
      DB="$(cat "$DB_CACHE")"
    else
      DB="$(mac 'printf "%s/Library/Application Support/Wispr Flow/flow.sqlite" "$HOME"' 2>/dev/null | tr -d '\r')"
      [ -n "$DB" ] && printf '%s\n' "$DB" > "$DB_CACHE"
    fi
  fi
  printf '%s' "$DB"
}
sql()  { mac "sqlite3 -readonly '$(remote_db)' \"$1\"" 2>/dev/null; }
fire() { mac "open -g '$1'" >/dev/null 2>&1; }

ensure_chain() {
  # ALWAYS call start: the device stays loaded and warm between dictations but is MUTED,
  # so start is what brings the microphone up, sets levels and selects the device.
  "$HOME/bin/dictation-mic.sh" start >/dev/null 2>&1
  if ! pgrep -x roc-send >/dev/null; then
    : >/tmp/roc-send.log
    nohup "$HOME/bin/roc-stream.sh" >>/tmp/roc-send.log 2>&1 &
    # NO WAIT, and that is a measured decision, not an omission. 2026-09-13:
    #   - the capture chain hands over its first frame in ~80-110ms (an earlier "2.4s"
    #     figure was parec's own default buffering, i.e. a broken instrument);
    #   - the ROC receiver only JOINS the session once a consumer opens the virtual device
    #     on the Mac, and arming Flow is what does that. With a consumer holding the device,
    #     the first RTP packet arrives 253ms after this streamer starts; with nothing
    #     holding it, no packet ever arrives (verified over 12s).
    # So audio cannot exist before Flow is armed, and the old `sleep 2` bought nothing while
    # costing 2s on every cold press. Arming now means Flow sees ~0.25s of silence instead
    # of the ~0.9s the old path tolerated.
    sleep 0.2
  fi
}

# No default host is baked in: guessing one would arm Flow and stream audio into the
# void, which looks exactly like a working setup. Fail where the cause is obvious.
if [ -z "$MAC" ]; then
  notify "DICTATE_MAC is not set - run install-linux.sh --mac HOST" normal
  exit 1
fi

case "${1:-}" in
start)
  T0=$(now_ms)
  # Immediate feedback, before any waiting: a cold start takes seconds and silence reads as
  # "the key did nothing". Replaced by the Listening toast once Flow is armed.
  pgrep -x roc-send >/dev/null || notify "Connecting... (release F9 when done)" critical
  # History.timestamp is the SESSION START, which can share a second with our marker,
  # so the marker is the current max rowid instead - exact and monotonic. Rows are only
  # written when the session ENDS, so reading it at any point before release is safe.
  if pgrep -x roc-send >/dev/null; then
    # WARM (the normal case). Two SSH round trips used to sit in front of the local audio
    # setup and cost ~1.3s end to end, during which the opening word was lost. Now the
    # remote arming runs CONCURRENTLY with the local level setup, and the marker query
    # happens after - it only has to be read before release, since rows are written then.
    # ONE ssh round trip does the marker query and the arming together: three sequential
    # round trips cost ~1.3s and the opening word went with it. Run in the FOREGROUND so a
    # failure is DETECTED - an unreachable Mac (tailnet down, Mac asleep) fails in ~400ms,
    # and leaving the microphone live for a session that cannot happen is the wrong call.
    # Backgrounded so it overlaps the local level setup (~180ms remote, ~270ms local),
    # but we still WAIT on the job and check its status, so an unreachable Mac is caught.
    ( mac "sqlite3 -readonly '$(remote_db)' \"SELECT COALESCE(MAX(rowid),0) FROM History\"; open -g 'wispr-flow://start-hands-free'" > /tmp/dictate-arm.out 2>/dev/null ) &
    armjob=$!
    "$HOME/bin/dictation-mic.sh" start >/dev/null 2>&1
    if wait "$armjob"; then
      head -1 /tmp/dictate-arm.out > "$MARKER"
      if [ ! -s "$MARKER" ]; then
        # The marker query came back empty (observed when Flow is starting up and the DB is
        # busy). Do NOT fall back to 0: with a 0 marker the release matches ANY row and
        # would re-type a PREVIOUS dictation into whatever is focused. Retry, then fail.
        sql "SELECT COALESCE(MAX(rowid),0) FROM History" > "$MARKER" 2>/dev/null
      fi
      if [ ! -s "$MARKER" ]; then
        notify_dismiss
        notify "Could not read the transcript log" critical
        restore_machine
        rm -f "$MARKER"
        echo "press_failed_no_marker=$(( $(now_ms) - T0 ))ms" >> "$TIMING"
        exit 1
      fi
    else
      notify_dismiss
      notify "Cannot reach the Mac - is Tailscale up?" critical
      restore_machine
      rm -f "$MARKER"
      echo "press_failed_unreachable=$(( $(now_ms) - T0 ))ms" >> "$TIMING"
      exit 1
    fi
  else
    # COLD: get audio flowing first. Flow auto-stops on "no audio detected", so arming
    # it against a dead stream would end the session before the user speaks.
    ensure_chain
    # This branch used to arm Flow and report success WITHOUT checking anything, so a press
    # with an unreachable Mac looked like a normal one - "Listening..." toast, microphone left
    # live, a stray streamer - and only failed at release. Measured 2026-09-13 (press_to_armed
    # 289ms, rc=0, no error toast). Fail fast instead, and undo what this branch created,
    # including the streamer, which is the one thing only this branch starts.
    if ! sql "SELECT COALESCE(MAX(rowid),0) FROM History" > "$MARKER" || [ ! -s "$MARKER" ] \
       || ! fire "wispr-flow://start-hands-free"; then
      notify_dismiss
      notify "Cannot reach the Mac - is Tailscale up?" critical
      restore_machine
      pkill -x roc-send 2>/dev/null
      rm -f "$MARKER"
      echo "press_failed_unreachable=$(( $(now_ms) - T0 ))ms" >> "$TIMING"
      exit 1
    fi
  fi
  echo "press_to_armed=$(( $(now_ms) - T0 ))ms" >> "$TIMING"
  notify_dismiss
  notify "Listening... (release F9 when done)" critical
  ;;
stop)
  # The restore is filed BEFORE any early-out, so a release always puts the machine back
  # even with no matching press (a start made outside the keybind path had no marker and
  # was previously never reverted). Restoring is idempotent and lands on the muted idle
  # state, so doing it redundantly is harmless.
  trap restore_machine EXIT
  [ -f "$MARKER" ] || exit 0          # no matching press; nothing else to do
  sleep "$TAIL_GRACE"
  T0=$(now_ms)
  if ! fire "wispr-flow://stop-hands-free"; then
    notify_dismiss
    notify "Lost the Mac mid-dictation" critical
    exit 1                      # trap restores the machine
  fi
  MARK=$(cat "$MARKER"); rm -f "$MARKER"
  # The toast has said "Listening..." since the press. Change it the moment the recording is
  # actually stopped, so the wait for the transcript is visible instead of stale.
  notify_dismiss
  notify "Transcribing..."
  TXT=""
  # Fast poll: each iteration is an ssh round trip (~0.15s) plus the sleep, so the loop count
  # IS the latency. 40 x 0.2s measured 15.3s to give up - a long, silent wait for the user.
  # 15 x 0.3s bounds it at ~7s while still catching a row that lands within ~1s (the normal
  # case: release_to_row ~1.2s) plus plenty of slack.
  for _ in $(seq 1 15); do
    TXT=$(sql "SELECT COALESCE(editedText, formattedText, asrText, '') FROM History WHERE rowid > $MARK ORDER BY rowid DESC LIMIT 1")
    [ -n "$TXT" ] && break
    sleep 0.3
  done
  T1=$(now_ms)
  if [ -z "$TXT" ]; then
    echo "release_to_giveup=$(( T1 - T0 ))ms (no transcript)" >> "$TIMING"
    notify_dismiss
    notify "No transcript captured"
    exit 1
  fi
  # A newline in the transcript becomes a Return keystroke, and in a chat or agent
  # prompt Return SUBMITS - which sent half a message and left the rest in the box.
  # It also ate characters while the input box re-rendered. Normalise by default.
  case "$NEWLINE_MODE" in
    enter) ;;                                                    # raw: newlines submit
    shift-enter) ;;                                              # handled below
    *) TXT=$(printf '%s' "$TXT" | tr -s '\n' ' ') ;;            # default: newlines -> space
  esac

  # TYPE_DELAY spaces keystrokes. 0 = fastest; raise if characters go missing.
  #
  # Capitals are left to wtype's own inference, because the explicit route does not work on
  # this stack. Measured 2026-09-13, four variants of an explicit Shift around the key
  # (-M shift -k l -m shift, with -s 6 / -s 20 / -s 30 spacing, and -k L / -M shift -k L):
  # EVERY one produced a lowercase "l", while plain text typing produced "L" correctly
  # (36/36 byte-identical runs over 5-capital strings at -d 0, 6 and 12). wtype's -k sends
  # the keycode for the requested keysym and does not apply the held modifier, so the
  # explicit path trades a rare dropped capital for a guaranteed wrong one.
  type_seg() {
    if [ "$TYPE_DELAY" -gt 0 ]; then wtype -d "$TYPE_DELAY" -- "$1"; else wtype -- "$1"; fi
  }

  if [ "$NEWLINE_MODE" = "shift-enter" ]; then
    first=1
    while IFS= read -r line; do
      [ "$first" -eq 1 ] || wtype -M shift -k Return -m shift
      [ -n "$line" ] && type_seg "$line "
      first=0
    done <<< "$TXT"
  else
    type_seg "$TXT "
  fi
  T2=$(now_ms)
  echo "release_to_row=$(( T1 - T0 ))ms row_to_typed=$(( T2 - T1 ))ms total=$(( T2 - T0 ))ms chars=${#TXT}" >> "$TIMING"
  notify_dismiss
  notify "Delivered: $TXT"
  ;;
*)
  echo "usage: $0 start|stop"
  ;;
esac
