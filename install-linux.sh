#!/usr/bin/env bash
# Wispr Flow remote dictation - Linux side installer.
#
#   ./install-linux.sh              install or refresh (idempotent)
#   ./install-linux.sh --check      report state, change nothing
#   ./install-linux.sh --uninstall  remove everything this installer created
#   ./install-linux.sh --purge      --uninstall plus the generated config
#
# What it installs:
#   1. ~/bin/{dictate,dictation-mic,roc-stream}.sh   the push-to-talk scripts
#   2. ~/.config/dictation.conf                      tunables (never overwritten)
#   3. a private roc-toolkit in ~/.local             built with the SoX backend
#      disabled, which retires the LD_LIBRARY_PATH workaround for roc #838
#   4. one F9 push-to-talk binding in ~/.config/hypr/bindings.lua, inside a
#      managed block so --uninstall can take it back out
#
# The Mac side (the speech engine) is install-macos.sh. Run that one first.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/bin"
CONF="$HOME/.config/dictation.conf"
BINDINGS="$HOME/.config/hypr/bindings.lua"
LOCAL_PREFIX="$HOME/.local"
ROC_SRC="$HOME/build/roc-toolkit"
SCONS="$HOME/.local/share/roc-venv/bin/scons"
MARK_BEGIN='-- >>> remote-dictation (managed block: safe to delete) >>>'
MARK_END='-- <<< remote-dictation (managed block) <<<'

SCRIPT_FILES=(dictate.sh dictation-mic.sh roc-stream.sh type-harness.sh)
STATE_FILES=("$HOME/.dictation-capture-orig" "$HOME/.dictation-src-fader" \
             "$HOME/.dictation-src-mute" "$HOME/.dictation-default-source" \
             "$HOME/.dictation-remote-db")

MODE=install
DO_ROC=1
# The host can come from --mac, the environment, or the config it was installed with: a
# plain --check must find the same Mac. Sourcing happens in a subshell so the config's
# other values do not leak into this script.
_conf_mac="$( { [ -f "$CONF" ] && . "$CONF"; printf '%s' "${DICTATE_MAC:-}"; } 2>/dev/null || true )"
MAC_HOST="${DICTATE_MAC:-$_conf_mac}"
while [ $# -gt 0 ]; do
  case "$1" in
    --check)        MODE=check ;;
    --uninstall|-u) MODE=uninstall ;;
    --purge)        MODE=purge ;;
    --no-roc-build) DO_ROC=0 ;;
    --mac)          MAC_HOST="${2:?--mac needs a hostname}"; shift ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# Non-interactive SSH has no XDG_RUNTIME_DIR, and every pactl/hyprctl call then
# returns empty - a trap that produced three phantom "device missing" alarms in
# one session. Restore it (and the session bus) before touching audio.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[ -S "$XDG_RUNTIME_DIR/bus" ] && export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
# Anything this installer builds (ragel, roc-send) lives here; put it first so
# later steps find it without an interactive shell's PATH.
export PATH="$LOCAL_PREFIX/bin:$PATH"

say()   { printf '  %s\n' "$*"; }
ok()    { printf '  ok    %s\n' "$*"; }
warn()  { printf '  warn  %s\n' "$*"; }
die()   { printf '  fail  %s\n' "$*" >&2; exit 1; }
step()  { printf '\n%s\n' "$*"; }

# ---------------------------------------------------------------- preflight

preflight() {
  step "Preflight"
  # Same check as install_conf, but early: a fresh install without a host would otherwise
  # spend minutes building roc-toolkit before refusing.
  if [ "$MODE" = install ] && [ ! -f "$CONF" ] && [ -z "$MAC_HOST" ]; then
    die "no speech-engine host: pass --mac HOST (its ssh host over your tailnet), or export DICTATE_MAC"
  fi
  [ "$(uname -s)" = Linux ] || die "this is the Linux/Linux side; the Mac side is install-macos.sh"
  [ -d "$PKG_DIR/bin" ] || die "bin/ is missing next to $0 - run this from the package directory"
  local missing=()
  local c
  for c in pactl amixer ssh; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] || die "missing commands: ${missing[*]} (need pipewire-pulse, alsa-utils, openssh)"
  command -v wtype >/dev/null 2>&1 || warn "wtype is missing - delivering text into the focused window needs it"
  command -v hyprctl >/dev/null 2>&1 || warn "hyprctl is missing - not a Hyprland session? the keybind step is skipped"
  pactl info >/dev/null 2>&1 || die "pactl cannot reach the audio server (is PipeWire running?)"
  ok "Linux, audio server and package layout look right"
}

# ------------------------------------------------------- the speech-audio leg

# The private build is verified by running it, not by scons' exit status. Note the
# capture-then-match: `... | grep -q` under `set -o pipefail` fails spuriously,
# because grep closes the pipe early and roc-send then dies of SIGPIPE.
roc_ready() {
  local i out
  for i in 1 2 3 4 5; do
    if [ -x "$LOCAL_PREFIX/bin/roc-send" ]; then
      out="$(env -u LD_LIBRARY_PATH "$LOCAL_PREFIX/bin/roc-send" -L 2>&1 || true)"
      case "$out" in *'pulse://'*) return 0 ;; esac
    fi
    sleep 1
  done
  return 1
}

build_roc() {
  step "roc-toolkit, built once with the SoX backend disabled"
  if roc_ready; then
    ok "already present: $LOCAL_PREFIX/bin/roc-send ($("$LOCAL_PREFIX/bin/roc-send" --version 2>/dev/null | sed -n '1p'))"
    return 0
  fi
  local c
  for c in cmake gcc git python3; do
    command -v "$c" >/dev/null 2>&1 || die "build dependency missing: $c"
  done
  if [ ! -x "$SCONS" ]; then
    say "bootstrapping scons into $HOME/.local/share/roc-venv"
    python3 -m venv "$HOME/.local/share/roc-venv"
    "$HOME/.local/share/roc-venv/bin/pip" -q install --upgrade pip scons
  fi
  if [ ! -d "$ROC_SRC/.git" ]; then
    say "cloning roc-toolkit"
    mkdir -p "$(dirname "$ROC_SRC")"
    git clone --depth 1 --recurse-submodules --shallow-submodules \
      https://github.com/roc-streaming/roc-toolkit "$ROC_SRC"
  fi
  # openfec (the FEC codec roc uses for rs8m) is generated by ragel. Arch does not
  # ship ragel, and installing it needs root, so build a private copy instead.
  if ! command -v ragel >/dev/null 2>&1; then
    say "building ragel into $LOCAL_PREFIX (openfec's code generator; no root needed)"
    local rb; rb="$(mktemp -d)"
    curl -fsSL -o "$rb/ragel.tar.gz" https://www.colm.net/files/ragel/ragel-6.10.tar.gz \
      || die "could not download ragel"
    tar -xzf "$rb/ragel.tar.gz" -C "$rb" || die "could not unpack ragel"
    ( cd "$rb/ragel-6.10" && ./configure --prefix="$LOCAL_PREFIX" >/dev/null \
      && make -j"$(nproc)" >/dev/null && make install >/dev/null ) \
      || die "ragel build failed"
    rm -rf "$rb"
    ok "ragel $("$LOCAL_PREFIX/bin/ragel" --version 2>/dev/null | sed -n '1p')"
  fi
  say "compiling (a few minutes; log is printed only on failure)"
  # openfec is the FEC codec behind rs8m; gengetopt generates the CLI parsers.
  # scons fetches and builds both, so neither needs to be installed system-wide.
  # --disable-shared is load-bearing: with the shared library enabled, `scons
  # install` tries to copy it from a staging directory (bin/<target>/) that scons
  # never creates, and fails with "No such file or directory" even though the
  # tools were built - reproducible on a fresh prefix. Static links the tools
  # against libroc directly and installs cleanly. Verify the payload anyway: the
  # binary is what matters, not scons' exit code.
  local rc=0
  PATH="$LOCAL_PREFIX/bin:$PATH" "$SCONS" -Q -C "$ROC_SRC" \
        --build-3rdparty=openfec,gengetopt \
        --disable-sox --disable-sndfile --disable-alsa --disable-libunwind \
        --disable-shared \
        --prefix="$LOCAL_PREFIX" -j"$(nproc)" install >"$HOME/build/roc-build.log" 2>&1 || rc=$?
  if ! roc_ready; then
    tail -20 "$HOME/build/roc-build.log" >&2
    die "roc-toolkit build failed (full log: $HOME/build/roc-build.log)"
  fi
  if [ "$rc" != 0 ]; then
    warn "scons exited $rc, but roc-send verified - treating it as cosmetic (see ~/build/roc-build.log)"
  fi
  # The shared library is no longer built; a copy from an earlier attempt is dead
  # weight and could be picked up by accident.
  local links
  links="$(ldd "$LOCAL_PREFIX/bin/roc-send" 2>/dev/null || true)"
  case "$links" in
    *libroc*) : ;;
    *) rm -f "$LOCAL_PREFIX"/lib/libroc.so* 2>/dev/null || true ;;
  esac
  roc_ready || die "built roc-send does not list pulse:// - see $HOME/build/roc-build.log"
  ok "roc-send now needs no LD_LIBRARY_PATH (roc-toolkit #838 is behind us)"
}

detect_source() {
  local src=""
  src="$(pactl get-default-source 2>/dev/null || true)"
  case "$src" in ""|dictation_mic|*dictation_mic*) src="$(pactl list short sources 2>/dev/null | awk '$2 ~ /^alsa_input\./ {print $2; exit}')" ;; esac
  [ -n "$src" ] || die "could not determine the real microphone source"
  printf '%s' "$src"
}

detect_card() {
  local pci idx
  pci="$(printf '%s' "$1" | sed -n 's/^alsa_input\.\(pci-[0-9a-fA-F:.]*\)\..*/\1/p')"
  idx=""
  if [ -n "$pci" ]; then
    idx="$(pactl list cards short 2>/dev/null | awk -v p="$pci" 'index($2, p) {print $1; exit}')"
  fi
  [ -n "$idx" ] || idx=0
  amixer -c "$idx" sget Capture >/dev/null 2>&1 || idx=0
  printf '%s' "$idx"
}

# ------------------------------------------------------------- the artifacts

install_scripts() {
  step "Scripts"
  mkdir -p "$BIN_DIR"
  local f changed=0
  for f in "${SCRIPT_FILES[@]}"; do
    [ -f "$PKG_DIR/bin/$f" ] || die "package is incomplete: bin/$f missing"
    if ! cmp -s "$PKG_DIR/bin/$f" "$BIN_DIR/$f"; then
      install -m 0755 "$PKG_DIR/bin/$f" "$BIN_DIR/$f"
      say "updated $BIN_DIR/$f"
      changed=1
    fi
  done
  [ "$changed" = 0 ] && ok "already up to date in $BIN_DIR" || ok "installed into $BIN_DIR"
}

install_conf() {
  step "Configuration"
  # The one value the package cannot guess. Needed by both branches below (a fresh config
  # writes it; an existing one gets it appended if it is absent) - but never demanded when
  # the config already carries it.
  if [ -z "$MAC_HOST" ] && ! grep -qE '^[[:space:]]*DICTATE_MAC=' "$CONF" 2>/dev/null; then
    die "no speech-engine host: pass --mac HOST (its ssh host over your tailnet), or export DICTATE_MAC"
  fi
  if [ -f "$CONF" ]; then
    ok "existing config kept untouched: $CONF"
    local src card k add=""
    src="$(detect_source)"; card="$(detect_card "$src")"
    for k in MIC_MASTER MIC_CARD DICTATE_MAC; do
      grep -qE "^[[:space:]]*$k=" "$CONF" || add="$add $k"
    done
    if [ -n "$add" ]; then
      say "appending keys added since your config was written:$add"
      { printf '\n# Added by install-linux.sh. Re-run with --check to review.\n'
        case "$add" in *MIC_MASTER*) printf 'MIC_MASTER=%s\n' "$src" ;; esac
        case "$add" in *MIC_CARD*)   printf 'MIC_CARD=%s\n' "$card" ;; esac
        case "$add" in *DICTATE_MAC*) printf '# The Mac running the speech engine, as an ssh host.\nDICTATE_MAC=%s\n' "$MAC_HOST" ;; esac
      } >> "$CONF"
    fi
    return 0
  fi
  mkdir -p "$(dirname "$CONF")"
  local src card
  src="$(detect_source)"; card="$(detect_card "$src")"
  cat >"$CONF" <<EOF
# Dictation settings. Sourced by ~/bin/dictate.sh on every keypress.
# The keybind runs with the compositor's environment, so put tunables HERE,
# not in ~/.zshrc.

# The real microphone the Dictation Mic is a capture of, and its ALSA card
# index (used for the hardware Capture gain). Detected at install time.
MIC_MASTER=$src
MIC_CARD=$card

# The machine running the speech engine, as an ssh host. It must resolve over your
# tailnet (an ssh alias is the usual way) and accept key-based ssh from this Linux machine.
DICTATE_MAC=$MAC_HOST

# Optional. Pin the Mac's address instead of resolving the hostname above; only
# needed if the tailnet name does not resolve here.
#DICTATE_MAC_IP=100.x.y.z

# Optional. Where Flow's database lives on the Mac. Derived from the REMOTE user's
# home automatically - set this only for a non-standard install.
#DICTATE_DB=/Users/you/Library/Application Support/Wispr Flow/flow.sqlite

# Milliseconds between keystrokes. 0 = fastest, but the desktop can drop
# keystrokes when press/release fire in a burst; 5-8 fixes disappearing letters.
DICTATE_TYPE_DELAY=6

# Seconds Flow keeps recording after you release the key, so the last word is
# not clipped.
DICTATE_TAIL_GRACE=0.5

# normal | low | critical
DICTATE_NOTIFY_URGENCY=normal

# How to handle paragraph breaks. A newline is a Return keystroke and in a chat
# or agent prompt Return SUBMITS, so "space" is the safe default.
# space | shift-enter | enter
DICTATE_NEWLINE=space

# The real mic's SOFTWARE fader while dictating. The Dictation Mic is built from
# that source, so this is the useful level control: 0% is silence, 50%+ clips.
# 20-25% measures clean. Your own value is saved and restored on release.
MIC_SRC_LEVEL=20%

# Our own fader on the Dictation Mic itself (0-150%). Fine trim.
MIC_GAIN=140

# Hardware capture gain, and whether to mute the real mic whenever idle.
MIC_HW_GAIN=70%
MIC_MUTE_IDLE=1
EOF
  ok "wrote $CONF"
}

install_bind() {
  step "Keybind (F9 push-to-talk)"
  if [ ! -f "$BINDINGS" ]; then
    warn "$BINDINGS does not exist - skipping; add the binding by hand (see README)"
    return 0
  fi
  if grep -qF -- "$MARK_BEGIN" "$BINDINGS"; then
    ok "managed block already present"
    return 0
  fi
  # A hand-placed binding (the way it was set up before this installer existed)
  # must not be duplicated: two F9 handlers would both fire.
  if grep -qE 'o\.bind\("F9".*dictate\.sh' "$BINDINGS"; then
    cp "$BINDINGS" "$BINDINGS.bak.$(date +%Y%m%d%H%M%S)"
    grep -vE 'o\.bind\("F9".*dictate\.sh' "$BINDINGS" >"$BINDINGS.tmp" && mv "$BINDINGS.tmp" "$BINDINGS"
    ok "adopted the pre-existing F9 binding (backup alongside the file)"
  fi
  cat >>"$BINDINGS" <<EOF

$MARK_BEGIN
-- Remote dictation: push-to-talk, transcribed by Wispr Flow on the Mac Mini.
-- Voice: internal mic -> Dictation Mic -> roc-send -> tailnet -> Mac -> Flow.
-- Text:  flow.sqlite -> wtype -> the focused window on this Linux machine.
o.bind("F9", "Dictate (push-to-talk)", "$BIN_DIR/dictate.sh start")
o.bind("F9", "Dictate (push-to-talk)", "$BIN_DIR/dictate.sh stop", { release = true })
$MARK_END
EOF
  ok "wrote the F9 binding into $BINDINGS"
  reload_hypr
}

reload_hypr() {
  command -v hyprctl >/dev/null 2>&1 || return 0
  local sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
  if [ -z "$sig" ]; then
    # Over a non-interactive SSH session the variable is not exported. The
    # compositor's runtime directory is named after the signature, so borrow it.
    local d
    d="$( { find "/run/user/$(id -u)/hypr" -maxdepth 1 -mindepth 1 -type d 2>/dev/null || true; } | sed -n '1p')"
    [ -n "$d" ] && sig="$(basename "$d")"
  fi
  if [ -z "$sig" ]; then
    warn "no Hyprland instance found (is a session running?); reload by hand with 'hyprctl reload'"
    return 0
  fi
  if HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl reload >/dev/null 2>&1; then
    ok "Hyprland reloaded"
  else
    warn "hyprctl reload failed - reload by hand with 'hyprctl reload'"
  fi
}

# --------------------------------------------------------------- uninstall

unload_device() {
  local mod
  mod="$(pactl list short modules 2>/dev/null | awk '/dictation_mic/ {print $1; exit}')"
  if [ -n "$mod" ]; then
    pactl unload-module "$mod" >/dev/null 2>&1 && say "unloaded the Dictation Mic device"
  fi
}

do_uninstall() {
  step "Uninstall"
  if [ -f "$BINDINGS" ] && grep -qF -- "$MARK_BEGIN" "$BINDINGS"; then
    sed -i "\|$MARK_BEGIN|,\|$MARK_END|d" "$BINDINGS"
    ok "removed the managed keybind block"
    reload_hypr
  else
    say "no managed keybind block to remove"
  fi

  if [ -x "$BIN_DIR/dictation-mic.sh" ]; then
    "$BIN_DIR/dictation-mic.sh" stop >/dev/null 2>&1 || true
  fi
  unload_device

  local f
  for f in "${SCRIPT_FILES[@]}"; do
    if [ -f "$BIN_DIR/$f" ] && grep -q "remote-dictation" "$BIN_DIR/$f" 2>/dev/null; then
      rm -f "$BIN_DIR/$f"; say "removed $BIN_DIR/$f"
    elif [ -f "$BIN_DIR/$f" ]; then
      warn "$BIN_DIR/$f is not ours - left in place"
    fi
  done
  for f in "${STATE_FILES[@]}"; do rm -f "$f"; done
  ok "scripts, transient state and the capture device are gone"

  if [ "$MODE" = purge ]; then
    rm -f "$CONF" && say "removed $CONF"
    say "the private roc build is left at $LOCAL_PREFIX/bin and $ROC_SRC - remove by hand if you want it gone"
  else
    say "kept: $CONF and the private roc build (use --purge to drop the config too)"
  fi
}

# ----------------------------------------------------------------- checking

do_check() {
  step "State"
  if roc_ready; then ok "roc-send (private build, no LD_LIBRARY_PATH needed)"; else warn "private roc-send missing - the system one still needs the sox workaround"; fi
  local f
  for f in "${SCRIPT_FILES[@]}"; do
    if [ -f "$BIN_DIR/$f" ]; then
      if cmp -s "$PKG_DIR/bin/$f" "$BIN_DIR/$f"; then ok "$BIN_DIR/$f is current"; else warn "$BIN_DIR/$f differs from the package"; fi
    else
      warn "$BIN_DIR/$f is not installed"
    fi
  done
  [ -f "$CONF" ] && ok "config: $CONF" || warn "config missing: $CONF"
  if [ -f "$BINDINGS" ] && grep -qF -- "$MARK_BEGIN" "$BINDINGS"; then ok "F9 binding present"; else warn "F9 binding missing"; fi
  local srcs
  srcs="$(pactl list short sources 2>/dev/null || true)"
  case "$srcs" in
    *dictation_mic*) ok "Dictation Mic node exists (kept warm)" ;;
    *) say "Dictation Mic node is absent - it is created on the first keypress" ;;
  esac
  if [ -z "$MAC_HOST" ]; then
    warn "DICTATE_MAC is not set - skipping the Mac probe (--mac HOST, or the config key)"
  elif ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$MAC_HOST" 'true' >/dev/null 2>&1; then
    ok "Mac reachable over ssh as '$MAC_HOST'"
    # Reachability is not enough. The receiver device can be deleted (or its binding torn down)
    # while ssh still works - and then a press arms Flow and silently delivers nothing, with no
    # clue on this side. The Mac's own --check reports it, but this is the check people run day
    # to day, so ask the Mac what devices it has.
    local idx rx
    idx="$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$MAC_HOST" \
          '/usr/local/bin/roc-vad device list 2>/dev/null | grep -w remote-mic | awk "{print \$1; exit}"' \
          2>/dev/null || true)"
    if [ -z "$idx" ]; then
      warn "Mac receiver 'Remote Mic' is missing - a press will arm Flow and deliver nothing."
      say "     Repair on the Mac: install-macos.sh (or --rebind if it exists but is silent)"
    else
      rx="$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$MAC_HOST" \
            "/usr/local/bin/roc-vad device show $idx 2>&1" 2>/dev/null || true)"
      case "$rx" in
        *rtp+rs8m://0.0.0.0:10001*)
          ok "Mac receiver 'Remote Mic' is present (index $idx, endpoints listed)"
          say "     listed is not proof of a live receiver - the README's tone test is" ;;
        *)
          warn "Mac receiver 'Remote Mic' exists (index $idx) but its endpoints are unbound."
          say "     Repair on the Mac: install-macos.sh --rebind" ;;
      esac
    fi
  else
    warn "cannot reach the Mac as '$MAC_HOST' (tailnet down, or the Mac is asleep)"
  fi
}

# --------------------------------------------------------------------- main

case "$MODE" in
  check)     do_check ;;
  uninstall|purge) do_uninstall ;;
  install)
    preflight
    [ "$DO_ROC" = 1 ] && build_roc
    install_scripts
    install_conf
    install_bind
    step "Next"
    say "press F9 on the Linux machine and speak; release to deliver into the focused window"
    say "diagnostics: --check, plus /tmp/dictate-timing.log and /tmp/roc-send.log"
    ;;
esac
