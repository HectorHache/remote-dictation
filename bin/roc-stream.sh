#!/bin/bash
# Managed by remote-dictation's install-linux.sh - removable with --uninstall.
# Stream the Linux machine's Dictation Mic to the Mac Mini over the tailnet as a ROC stream.
# The LD_LIBRARY_PATH workaround is for roc-toolkit issue #838: the sox backend has a
# hard 256-driver cap and Arch's sox_ng registers more, so roc-send panics on startup.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# Settings come from the same file the keybind uses. This script is also run by hand
# (and under nohup from dictate.sh), so it must not depend on being handed an environment.
[ -f "$HOME/.config/dictation.conf" ] && . "$HOME/.config/dictation.conf"
# Prefer the private build (install-linux.sh): it has the SoX backend disabled,
# which retires roc-toolkit issue #838. Fall back to the system package plus the
# old-sox LD_LIBRARY_PATH hack if that build is not present.
if [ -x "$HOME/.local/bin/roc-send" ]; then
  ROC_SEND="$HOME/.local/bin/roc-send"
else
  ROC_SEND="${ROC_SEND:-roc-send}"
  SOX_OLD="${SOX_OLD:-$HOME/opt/sox-14.7.1/usr/lib}"
  [ -d "$SOX_OLD" ] && export LD_LIBRARY_PATH="$SOX_OLD${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
MAC_HOST="${DICTATE_MAC:-}"  # required: the resolve check below fails loudly if unset
MAC_IP="${DICTATE_MAC_IP:-$(getent ahostsv4 "$MAC_HOST" 2>/dev/null | awk 'NR==1{print $1}')}"
# No silent fallback to an address: a wrong IP would stream audio into the void while
# everything else looked healthy. Fail where the cause is obvious instead.
if [ -z "$MAC_IP" ]; then
  echo "roc-stream: cannot resolve the Mac host '$MAC_HOST'." >&2
  echo "Set DICTATE_MAC (or DICTATE_MAC_IP) in ~/.config/dictation.conf." >&2
  exit 1
fi
exec "$ROC_SEND" -v \
  -i pulse://dictation_mic \
  -s "rtp+rs8m://${MAC_IP}:10001" \
  -r "rs8m://${MAC_IP}:10002" \
  -c "rtcp://${MAC_IP}:10003"
