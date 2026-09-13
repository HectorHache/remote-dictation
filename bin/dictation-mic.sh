#!/bin/bash
# Managed by remote-dictation's install-linux.sh - removable with --uninstall.
# Dictation Mic - the device we own, used only while dictating.
#
# WHY IT EXISTS: the real mic (ALC298) must be able to sit MUTED the rest of the time
# for privacy, and we need something we can configure and select atomically without
# mutating the user's device in place. So:
#
#   idle   : Dictation Mic muted, real mic muted, your own source selected
#   press  : real mic unmuted at our levels, Dictation Mic unmuted + becomes the DEFAULT
#            source so the desktop UI shows it, Bluetooth untouched (stays A2DP)
#   release: levels and your previous source restored, both mics muted again
#
# The device is NOT unloaded on release: unloading it kills roc-send, and a full rebuild
# measures ~10.4s of dead air. Keeping it warm costs nothing because it is muted.
set -u
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[ -f "$HOME/.config/dictation.conf" ] && . "$HOME/.config/dictation.conf"

MASTER="${MIC_MASTER:-alsa_input.pci-0000_00_1f.3.analog-stereo}"
NAME=dictation_mic
GAIN="${MIC_GAIN:-140}"              # our own fader on the Dictation Mic
HW_GAIN="${MIC_HW_GAIN:-70%}"        # hardware capture gain (+11 dB, not +30 dB)
SRC_LEVEL="${MIC_SRC_LEVEL:-20%}"    # real mic's software fader while dictating
MUTE_IDLE="${MIC_MUTE_IDLE:-1}"      # 1 = mute the real mic whenever not dictating

STATE="$HOME/.dictation-capture-orig"
FADER_STATE="$HOME/.dictation-src-fader"
MUTE_STATE="$HOME/.dictation-src-mute"
DEFAULT_STATE="$HOME/.dictation-default-source"

node_exists() { pactl list short sources 2>/dev/null | awk -v n="$NAME" '$2==n{f=1} END{exit !f}'; }
read_fader()  { pactl get-source-volume "$MASTER" 2>/dev/null | head -1 | awk -F/ '{print $2}' | tr -d ' '; }
read_hw()     { amixer -c "${MIC_CARD:-0}" sget Capture 2>/dev/null | tail -1 | awk '{gsub(/[\[\]]/,"",$5); print $5}'; }
read_mute()   { pactl get-source-mute "$MASTER" 2>/dev/null | awk '{print $2}'; }
# WirePlumber owns the REMEMBERED volume for a device and re-applies it whenever the node
# is reconfigured (e.g. when the remap attaches), so a pactl write alone gets reverted.
# Setting through wpctl updates that memory, which is the only thing that actually sticks.
set_src_fader() {
  local pct="$1" id dec
  id=$(pactl list short sources 2>/dev/null | awk -v m="$MASTER" '$2==m{print $1; exit}')
  dec=$(awk -v p="${pct%\%}" 'BEGIN{printf "%.4f", p/100}')
  [ -n "$id" ] && wpctl set-volume "$id" "$dec" >/dev/null 2>&1
  pactl set-source-volume "$MASTER" "$pct" >/dev/null 2>&1
}

wait_for_node() {
  for _ in $(seq 1 24); do node_exists && return 0; sleep 0.25; done
  return 1
}

start() {
  # ORDER MATTERS. Everything that makes audio flow comes first, so the microphone is
  # live within ~200ms of the keypress; verification loops that only matter if something
  # drifted run last. Setting levels before unmuting cost ~1s of the first word.
  [ -f "$STATE" ]         || read_hw    > "$STATE"
  [ -f "$FADER_STATE" ]   || read_fader > "$FADER_STATE"
  [ -f "$MUTE_STATE" ]    || read_mute  > "$MUTE_STATE"
  # Never record OUR OWN device as the user's original: if an earlier release failed to
  # restore, saving the current default would lock dictation_mic in as "yours" forever.
  if [ ! -f "$DEFAULT_STATE" ]; then
    local cur_def; cur_def=$(pactl get-default-source 2>/dev/null)
    [ "$cur_def" != "$NAME" ] && printf '%s\n' "$cur_def" > "$DEFAULT_STATE"
  fi

  # --- audio-critical, do these immediately ---
  set_src_fader "$SRC_LEVEL"
  pactl set-source-mute   "$MASTER" 0 >/dev/null 2>&1
  if ! node_exists; then
    # Prefer WebRTC processing: a high-pass filter plus noise suppression. Wind noise is
    # overwhelmingly low-frequency, and unfiltered it defeats speech detection entirely
    # (observed: 155s of captured audio, zero words, detectedLanguage NULL).
    if ! pactl load-module module-echo-cancel \
            source_name="$NAME" source_master="$MASTER" \
            aec_method=webrtc \
            aec_args="high_pass_filter=1 noise_suppression=1 analog_gain_control=0 digital_gain_control=0" \
            source_properties="device.description=Dictation Mic" >/dev/null 2>&1; then
      # Fallback: a plain remap, unfiltered, if echo-cancel is unavailable.
      pactl load-module module-remap-source master="$MASTER" source_name="$NAME" \
          source_properties="device.description=Dictation Mic" >/dev/null || return 1
    fi
    wait_for_node || { echo "ERROR: $NAME never appeared"; return 1; }
  fi
  pactl set-source-mute "$NAME" 0 >/dev/null 2>&1
  pactl set-source-volume "$NAME" "${GAIN}%" >/dev/null 2>&1
  pactl set-default-source "$NAME" >/dev/null 2>&1
  # --- live from here ---

  # Re-assert the real mic's fader AFTER the node is linked. Attaching the remap makes
  # WirePlumber re-apply the device's REMEMBERED volume, which silently replaced our value
  # (measured: asked for 20%, got the user's 15% - a 20 dB quieting).
  # ONE corrective attempt, not a loop. WirePlumber re-pins this device's fader regardless
  # of which API we use, so the old 20-iteration loop could never succeed - it just burned
  # ~900ms of the ~1.07s bring-up on every single keypress.
  local sgot
  sgot=$(read_fader)
  if [ "$sgot" != "$SRC_LEVEL" ]; then
    set_src_fader "$SRC_LEVEL"
    sgot=$(read_fader)
  fi

  # Hardware gain: WirePlumber re-applies remembered ALSA mixer state, so verify.
  local hw=""
  for _ in $(seq 1 8); do
    amixer -c "${MIC_CARD:-0}" sset Capture "$HW_GAIN" >/dev/null 2>&1
    hw=$(read_hw); [ "$hw" = "$HW_GAIN" ] && break
    sleep 0.2
  done

  # module-stream-restore can re-apply a remembered fader AFTER our write. Only pay for
  # the settle loop if it actually drifted.
  local got want="${GAIN}%" stable=0
  got=$(pactl get-source-volume "$NAME" 2>/dev/null | head -1 | awk -F/ '{print $2}' | tr -d ' ')
  if [ "$got" != "$want" ]; then
    for _ in $(seq 1 40); do
      got=$(pactl get-source-volume "$NAME" 2>/dev/null | head -1 | awk -F/ '{print $2}' | tr -d ' ')
      if [ "$got" = "$want" ]; then stable=$((stable+1)); [ "$stable" -ge 4 ] && break
      else stable=0; pactl set-source-volume "$NAME" "$want" >/dev/null 2>&1; fi
      sleep 0.25
    done
  fi

  # Report what is ACTUALLY set, not what we asked for: WirePlumber can re-pin the real
  # mic's fader to its remembered value shortly after we write it, and pretending
  # otherwise made an earlier debugging round chase a phantom.
  local final_src final_hw
  final_src=$(read_fader); final_hw=$(read_hw)
  echo "Dictation Mic live (device ${got:-${GAIN}%}, source $final_src [asked $SRC_LEVEL], hardware $final_hw [asked $HW_GAIN])"
}

stop() {
  # Revert the visible default first, so the desktop stops showing the dictation device.
  if [ -f "$DEFAULT_STATE" ]; then
    pactl set-default-source "$(cat "$DEFAULT_STATE")" >/dev/null 2>&1
    rm -f "$DEFAULT_STATE"
  fi
  # Silence our device; it stays loaded and warm but carries nothing.
  pactl set-source-mute "$NAME" 1 >/dev/null 2>&1

  # Real mic: back to silenced-by-default, your fader restored.
  if [ "$MUTE_IDLE" = "1" ]; then
    pactl set-source-mute "$MASTER" 1 >/dev/null 2>&1
  elif [ -f "$MUTE_STATE" ]; then
    pactl set-source-mute "$MASTER" "$(cat "$MUTE_STATE")" >/dev/null 2>&1
  fi
  [ -f "$FADER_STATE" ] && { set_src_fader "$(cat "$FADER_STATE")"; rm -f "$FADER_STATE"; }
  [ -f "$STATE" ] && { amixer -c "${MIC_CARD:-0}" sset Capture "$(cat "$STATE")" >/dev/null 2>&1; rm -f "$STATE"; }
  rm -f "$MUTE_STATE"
  echo "Dictation Mic idle (real mic muted, your source reselected, device kept warm)"
}

case "${1:-}" in
  start) start ;;
  stop)  stop ;;
  status)
    echo "node=$(node_exists && echo present || echo absent) fader=$(pactl get-source-volume "$NAME" 2>/dev/null | head -1 | awk -F/ '{print $2}' | tr -d ' ') source_fader=$(read_fader) source_mute=$(read_mute) default=$(pactl get-default-source 2>/dev/null)"
    ;;
  *) echo "usage: $0 start|stop|status" ;;
esac
