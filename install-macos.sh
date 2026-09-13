#!/usr/bin/env bash
# Wispr Flow remote dictation - Mac (brain) side installer.
#
#   ./install-macos.sh                 install or refresh (idempotent)
#   ./install-macos.sh --check         report state, change nothing
#   ./install-macos.sh --uninstall     delete the virtual microphone
#   ./install-macos.sh --purge         also remove the driver and CLI (sudo)
#   ./install-macos.sh --tarball FILE  install the driver from a local tarball
#
# What it installs:
#   1. the roc-vad virtual audio driver (a real HAL driver, so the receiver
#      lives inside the audio server - there is NO background service to run
#      and no launchd job to keep alive)
#   2. a receiver device, "Remote Mic", bound to UDP 10001/10002/10003
#   3. a report of Wispr Flow's microphone setting, which is the one step that
#      still needs a human (Flow stores an opaque device hash, so we verify
#      rather than write it)
#
# The Linux side is install-linux.sh. Run this one first.
set -euo pipefail

VERSION="v0.0.4"
TARBALL_URL="https://github.com/roc-streaming/roc-vad/releases/download/$VERSION/roc-vad.tar.bz2"
TARBALL_SHA256="efa3ab380092de554160dc02140702d2b4f9aa2ddb503cf2b90618cdbc95e29a"
DRIVER="/Library/Audio/Plug-Ins/HAL/roc_vad.driver"
CLI="/usr/local/bin/roc-vad"
DEV_UID="remote-mic"
DEV_NAME="Remote Mic"
EP_SOURCE="rtp+rs8m://0.0.0.0:10001"
EP_REPAIR="rs8m://0.0.0.0:10002"
EP_CONTROL="rtcp://0.0.0.0:10003"
FLOW_CFG="$HOME/Library/Application Support/Wispr Flow/config.json"
TARBALL=""

MODE=install
while [ $# -gt 0 ]; do
  case "$1" in
    --check)        MODE=check ;;
    --rebind)       MODE=rebind ;;
    --uninstall|-u) MODE=uninstall ;;
    --purge)        MODE=purge ;;
    --tarball)      TARBALL="${2:?--tarball needs a path}"; shift ;;
    -h|--help)      sed -n '2,19p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
die()  { printf '  fail  %s\n' "$*" >&2; exit 1; }
step() { printf '\n%s\n' "$*"; }

sudo_keepalive() {
  say "this step needs sudo (installing into /Library and /usr/local)"
  sudo -v || die "sudo refused"
}

# ---------------------------------------------------------------- driver

# NB: never `... | grep -q` under `set -o pipefail`: grep closes the pipe early,
# the producer dies of SIGPIPE, and the pipeline reports failure even on a match.
driver_loaded() {
  local out
  out="$("$CLI" info 2>/dev/null || true)"
  case "$out" in *"driver is loaded"*) return 0 ;; esac
  return 1
}

install_driver() {
  step "roc-vad driver $VERSION"
  if [ -x "$CLI" ] && [ -f "$DRIVER/Contents/Info.plist" ]; then
    ok "already installed: $("$CLI" info 2>/dev/null | awk '/^  version:/{print $2; exit}')"
    return 0
  fi
  local tb="$TARBALL"
  if [ -z "$tb" ]; then
    tb="$(mktemp -d)/roc-vad.tar.bz2"
    say "downloading $TARBALL_URL"
    curl -fL --retry 3 -o "$tb" "$TARBALL_URL" || die "download failed"
  fi
  printf '%s  %s\n' "$TARBALL_SHA256" "$tb" | shasum -a 256 -c - >/dev/null 2>&1 \
    || die "checksum mismatch on $tb"
  ok "tarball verified against the published sha256"
  sudo_keepalive
  # bsdtar cannot create /usr and /Library: on modern macOS both are firmlinks,
  # so it always exits non-zero even when every real file landed. Never trust
  # this exit status - verify the payload below instead.
  set +e
  sudo tar --no-same-owner -xPmf "$tb" -C / 2>&1 | tail -2
  set -e
  [ -x "$CLI" ] || die "extraction did not produce $CLI"
  [ -f "$DRIVER/Contents/Info.plist" ] || die "extraction did not produce the driver bundle"
  local got
  got="$(defaults read "$DRIVER/Contents/Info" CFBundleVersion 2>/dev/null || echo '?')"
  case "$got" in "${VERSION#v}"*) ok "driver $got in place (bsdtar's exit status ignored on purpose)" ;;
                 *) warn "driver reports version $got, expected ${VERSION#v}" ;; esac
}

load_driver() {
  step "Loading the driver"
  if driver_loaded; then ok "driver is loaded"; return 0; fi
  say "not loaded - restarting coreaudiod (it respawns by itself)"
  sudo killall coreaudiod 2>/dev/null || true
  sleep 3
  if driver_loaded; then ok "driver is loaded"; return 0; fi
  die "still not loaded - reboot this Mac and re-run (do not reboot while an agent session is live on it)"
}

# ---------------------------------------------------------------- device

device_index() {
  "$CLI" device list 2>/dev/null | awk -v u="$DEV_UID" 'NR>1 && $4==u {print $1; exit}'
}

install_device() {
  step "Virtual microphone '$DEV_NAME'"
  local idx; idx="$(device_index)"
  if [ -z "$idx" ]; then
    "$CLI" device add receiver --uid "$DEV_UID" --name "$DEV_NAME" >/dev/null \
      || die "could not create the device"
    idx="$(device_index)"
    [ -n "$idx" ] || die "device was created but does not appear in the list"
    ok "created (index $idx)"
  else
    ok "already exists (index $idx)"
  fi
  # `device bind` is NOT idempotent: re-binding an already-bound slot fails with
  # "invalid endpoint ... err=-1", so check the current binding first.
  local shown
  shown="$("$CLI" device show "$idx" 2>/dev/null || true)"
  local has_src=0 has_rpr=0 has_ctl=0
  case "$shown" in *"$EP_SOURCE"*) has_src=1 ;; esac
  case "$shown" in *"$EP_REPAIR"*) has_rpr=1 ;; esac
  case "$shown" in *"$EP_CONTROL"*) has_ctl=1 ;; esac
  if [ "$has_src" = 1 ] && [ "$has_rpr" = 1 ] && [ "$has_ctl" = 1 ]; then
    ok "endpoints already bound (slot 0)"
  else
    if ! "$CLI" device bind "$idx" -s "$EP_SOURCE" -r "$EP_REPAIR" -c "$EP_CONTROL" >/dev/null 2>&1; then
      # A bind fails with "invalid endpoint ... err=-1" when the UDP ports are
      # still owned by an earlier device (a renamed one, or a device whose own
      # bind failed and left the slot half-bound). Deleting the device releases
      # both; recreate once, then bind again.
      warn "bind failed - recreating the device to release a stale slot and its ports"
      "$CLI" device del "$idx" >/dev/null 2>&1 || true
      sleep 1
      idx="$(device_index)"
      if [ -n "$idx" ]; then "$CLI" device del "$idx" >/dev/null 2>&1 || true; fi
      "$CLI" device add receiver --uid "$DEV_UID" --name "$DEV_NAME" >/dev/null \
        || die "could not create the device"
      idx="$(device_index)"
      [ -n "$idx" ] || die "device was created but does not appear in the list"
      "$CLI" device bind "$idx" -s "$EP_SOURCE" -r "$EP_REPAIR" -c "$EP_CONTROL" >/dev/null \
        || die "could not bind the endpoints, even after recreating the device"
      ok "recreated (index $idx)"
    fi
    shown="$("$CLI" device show "$idx" 2>/dev/null || true)"
    ok "bound to :10001 (source), :10002 (repair), :10003 (control)"
  fi
  local ep
  for ep in 10001 10002 10003; do
    case "$shown" in *"$ep"*) ;; *) warn "endpoint :$ep is not visible in device show" ;; esac
  done
  if grep -qE '^  state: *on' <<<"$shown"; then
    ok "state: on"
  else
    warn "device is not in state 'on' - try: $CLI device enable $idx"
  fi
}

coreaudio_report() {
  step "CoreAudio"
  local prof
  prof="$(system_profiler SPAudioDataType 2>/dev/null || true)"
  if grep -q "^ *${DEV_NAME}:$" <<<"$prof"; then
    ok "CoreAudio sees '$DEV_NAME'"
  else
    warn "CoreAudio does not list '$DEV_NAME' yet - give coreaudiod a moment and re-run --check"
  fi
  if awk -v name="${DEV_NAME}:" '
        $0 ~ "^ *" name "$" { dev=1; next }
        /Default Input Device: Yes/ { if (dev) found=1 }
        { dev=0 }
        END { exit !found }' <<<"$prof"; then
    say "note: '$DEV_NAME' is the system default INPUT. Anything left on 'default input'"
    say "      hears silence unless the Linux machine is streaming - that is intended."
  fi
}

flow_report() {
  step "Wispr Flow"
  if [ ! -f "$FLOW_CFG" ]; then
    warn "Flow config not found - install Flow, then pick the microphone by hand"
    return 0
  fi
  local pin
  pin="$(python3 - "$FLOW_CFG" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("unreadable"); raise SystemExit
u = (d.get("prefs") or {}).get("user") or {}
print(u.get("overrideAudioDeviceId") or "default")
PY
)"
  say "microphone setting: ${pin:-default}"
  if [ -z "$pin" ] || [ "$pin" = default ] || [ "$pin" = unreadable ]; then
    warn "Flow is on Auto-detect. Fix once, by hand:"
    say "  Flow > Settings > General > Microphone > Change > $DEV_NAME"
    say "  (Flow stores an opaque device hash, so this cannot be scripted safely)"
  else
    ok "Flow is pinned to a specific microphone - confirm it is '$DEV_NAME' in Settings"
  fi
}

# --------------------------------------------------------------- uninstall

do_uninstall() {
  step "Uninstall"
  local idx; idx="$(device_index)"
  if [ -n "$idx" ]; then
    "$CLI" device del "$idx" >/dev/null && ok "deleted virtual microphone (index $idx)"
  else
    say "no '$DEV_NAME' device to delete"
  fi
  if [ "$MODE" = purge ]; then
    sudo_keepalive
    "$CLI" uninstall >/dev/null 2>&1 && ok "driver and CLI removed" || warn "roc-vad uninstall failed - remove $DRIVER and $CLI by hand"
  else
    say "kept: the driver and CLI (use --purge to remove them too)"
  fi
  say "Flow's microphone setting now points at a device that no longer exists -"
  say "set it back to Auto-detect (Flow > Settings > General > Microphone)."
}

do_rebind() {
  # The device config can outlive the receiver that is actually listening: a
  # `device bind` against an already-bound slot tears the old binding down and
  # then fails, leaving the endpoints listed but nothing on the wire (the device
  # is silently dead - Flow sees a device that never produces audio).
  # Rebuilding the device is the only reliable repair.
  step "Rebuild the receiver"
  local idx; idx="$(device_index)"
  if [ -n "$idx" ]; then
    "$CLI" device del "$idx" >/dev/null && ok "deleted the existing device (index $idx)"
  fi
  install_device
  coreaudio_report
  say "open and close any app that uses the microphone if CoreAudio does not show it"
}

do_check() {
  step "State"
  if [ -x "$CLI" ]; then ok "CLI: $CLI"; else warn "CLI missing: $CLI"; fi
  if driver_loaded; then ok "driver is loaded"; else warn "driver is not loaded"; fi
  local idx; idx="$(device_index)"
  if [ -n "$idx" ]; then ok "device '$DEV_NAME' (index $idx)"; else warn "device '$DEV_NAME' is missing"; fi
  if [ -n "$idx" ]; then
    local shown; shown="$("$CLI" device show "$idx" 2>/dev/null || true)"
    local ep
    for ep in 10001 10002 10003; do
      case "$shown" in *"$ep"*) ok "endpoint :$ep bound" ;; *) warn "endpoint :$ep missing" ;; esac
    done
  fi
  coreaudio_report
  flow_report
  say "note: the endpoint list above is config, not proof of a live receiver."
  say "      Only a stream proves it - see 'Verifying the audio path' in the README."
  say "      A device that looks bound but hears nothing: repair with --rebind."
  say "streaming is a Linux-side condition; check it there with install-linux.sh --check"
}

case "$MODE" in
  check)     do_check ;;
  rebind)    do_rebind ;;
  uninstall|purge) do_uninstall ;;
  install)
    [ "$(uname -s)" = Darwin ] || die "this is the Mac side; the Linux side is install-linux.sh"
    install_driver
    load_driver
    install_device
    coreaudio_report
    flow_report
    step "Next"
    say "on the Linux machine: bash remote-dictation/install-linux.sh, then press F9 and speak"
    say "no background service is needed here: the receiver lives in the audio driver"
    ;;
esac
