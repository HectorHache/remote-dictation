# Remote dictation: a Linux microphone, a Mac speech engine

Dictate using Wispr Flow running on a Mac, from your Linux machine. Hold **F9**,
speak into the machine's own microphone, and the transcript is typed into whatever
window has focus. Flow has no Linux client; this package does not need one.

The microphone audio travels over the tailnet to a Mac, where a virtual audio
device presents it to Wispr Flow. The transcript comes back through Flow's own
local database. Nothing but audio ever leaves the Linux machine - no files, no
transcripts, no telemetry - and the microphone it captures is muted whenever the key
is not held. (The sender stays attached between presses: that is what makes a warm
press ~260 ms instead of a full rebuild, and what the "roc-send killed while idle"
row in Failure modes costs you.)

```
Linux machine                                    Mac (tailnet)
------                                    -------------
Hyprland F9 bind                          roc-vad virtual input "Remote Mic"
  |                                         ^            |
  v                                         |            v
Dictation Mic (echo-cancel/WebRTC)          |      Wispr Flow (mic pinned)
  |                                         |            |
roc-send -i pulse://dictation_mic ----------+            v
                                RTP + rs8m FEC     flow.sqlite  History row
  ^                                                      |
  |                                            ssh poll (readonly)
  +---- clipboard paste (or wtype) delivers it into the focused window
```

## What you need first

Two machines on the same **tailnet** (Tailscale or equivalent), plus:

**On the Mac** (the brain)
- macOS with **Wispr Flow installed and logged in**. Flow is macOS-only, and this
  package does not give you an account for it.
- **Remote Login** enabled (System Settings > General > Sharing) and your Linux machine's
  key in `~/.ssh/authorized_keys`, so `ssh <mac>` works with no password. Test that
  before you start - it is the one thing the installer cannot fix for you.
- `sudo` once, during install: the receiver is a real CoreAudio HAL driver, so it
  belongs in `/Library`.
- `sqlite3`, which macOS already ships: the Linux machine reads Flow's history over ssh.

**On the Linux machine** (Omarchy/Hyprland - nothing here needs root)
- `libpulse` (`pactl`), `wireplumber` (`wpctl`), `alsa-utils` (`amixer`), `wtype`
- a toolchain and Python, to build roc-toolkit: `base-devel`, `git`, `python`
- optional, for the no-microphone verification recipe: `sox` (and `ffmpeg` on the Mac)

Arch, in one line:

```bash
sudo pacman -S --needed libpulse wireplumber alsa-utils wtype base-devel git python sox
```

The installer writes to `~/bin`, `~/.config`, `~/.local` and `~/build` (the roc
source tree). It never touches system paths, and `--uninstall` reverses all of it.

## Install

Run the Mac side first (it owns the receiving end), then the Linux side.

```bash
# 1. On the Mac: clone, then install the receiving end (asks for sudo once)
git clone <repo-url> ~/remote-dictation
bash ~/remote-dictation/install-macos.sh          # idempotent; --check, --uninstall

# 2. Flow's microphone is the one step no installer can do for you:
#    Flow > Settings > General > Microphone > Change > Remote Mic

# 3. Copy the same directory to the Linux machine and install the sending end
scp -r ~/remote-dictation <linux-host>:~/
ssh <linux-host> 'bash ~/remote-dictation/install-linux.sh --mac <mac>'

# 4. Hold F9 on the Linux machine and speak.
```

Both installers are idempotent and safe to re-run; `--check` reports state
without touching anything, `--uninstall` reverses what the installer created.
`install-macos.sh --rebind` rebuilds the virtual microphone from scratch - that
is the repair path if the receiver ever goes silent (see Failure modes).

### What the Mac installer does

1. Installs the **roc-vad** HAL driver (published tarball, sha256-pinned).
2. Ensures the audio server has loaded it.
3. Creates the receiver device `Remote Mic` and binds UDP 10001 (source),
   10002 (FEC repair), 10003 (control).
4. Reports Flow's microphone setting.

No background service is involved: the receiver lives inside the audio driver,
and the device survives reboots on its own. There is no launchd job to keep
alive.

**One manual step, once:** Flow ships an opaque per-device hash, so the
installer cannot select the microphone for you. In Flow: *Settings > General >
Microphone > Change > Remote Mic*. It already persists after that.

### What the Linux installer does

1. Builds **roc-toolkit** into `~/.local`, statically, with the SoX backend disabled.
   This retires the `LD_LIBRARY_PATH` workaround for
   [roc-toolkit #838](https://github.com/roc-streaming/roc-toolkit/issues/838)
   (Arch's `sox_ng 14.8` registers more than the backend's 256-driver array
   can hold, so the stock `roc-send` panics on start-up).
   `--disable-shared` is also load-bearing: with the shared library enabled,
   `scons install` fails trying to copy it from a staging directory scons never
   creates, even though the build succeeded.
2. Installs the three scripts into `~/bin`.
3. Writes `~/.config/dictation.conf` (never overwrites an existing one).
4. Appends one push-to-talk binding to `~/.config/hypr/bindings.lua`, inside a
   managed block, and reloads Hyprland.

`ragel` is needed to build openfec (the FEC codec). The installer builds it
unprivileged into `~/.local` if it is missing, so no root is required. If your
build fails for a different reason, the log is at `~/build/roc-build.log`.

## Use

| Action | Result |
| --- | --- |
| Hold `F9`, speak, release | transcript is typed into the focused window |
| `~/bin/dictate.sh start` / `stop` | same thing from a terminal |
| `bash install-linux.sh --check` | state of scripts, device, Mac reachability **and the Mac's receiver** |

While nothing is held, the Linux machine's real microphone is muted, so no other app
can listen in. The Dictation Mic node is kept warm between presses to keep
bring-up under ~300 ms.

**Warm vs cold.** Every press after the first is ~0.3 s; the **first press after a
reboot** is ~1 s (device bring-up, streamer start, arming). Nothing needs waiting for:
the capture chain hands over its first frame in ~80-110 ms, and the receiver joins the
stream the moment a consumer opens the virtual device on the Mac - which is exactly what
arming Flow does. Audio therefore appears within ~250 ms of Flow being armed, so the
press path arms immediately instead of sleeping first.

## Configuration

`~/.config/dictation.conf` is sourced on every keypress by both scripts. **The config wins over
the environment**: it is sourced *after* the environment is inherited, so `DICTATE_MAC=other
dictate.sh start` has no effect when this file also sets `DICTATE_MAC` - edit the file, or pass
the value at install time (`install-linux.sh --mac HOST`, which appends it here). That
precedence silently invalidated a test of the unreachable-Mac path once; check which value
actually applied before drawing conclusions from a failure test.

The keys that matter:

| Key | Default | Meaning |
| --- | --- | --- |
| `DICTATE_DELIVERY` | `auto` | `auto` pastes via the clipboard when possible (exact bytes: accented characters wtype cannot type, atomic for long text); `type` forces wtype |
| `DICTATE_NEWLINE` | `space` | `enter` would submit a chat prompt - keep `space` unless you want that |
| `DICTATE_TYPE_DELAY` | `6` | ms between keystrokes; raise to 8 if letters go missing |
| `DICTATE_TAIL_GRACE` | `0.5` | seconds of extra recording after release |
| `MIC_SRC_LEVEL` | `20%` | the real mic's software fader while dictating; 50%+ clips |
| `MIC_GAIN` | `140` | the Dictation Mic's own fader |
| `MIC_MASTER` / `MIC_CARD` | detected | which source to capture, and its ALSA card |
| `MIC_MUTE_IDLE` | `1` | mute the real mic whenever not dictating |
| `MIC_SINK_MASTER` | derived | the echo-canceller's reference sink. Derived from the mic's own card (`alsa_input.X` -> `alsa_output.X`); set it only if that card has no matching output. Read the failure-mode table before letting this float |
| `DICTATE_SENDER_MAX_AGE` | `1800` | seconds; a streamer older than this is rebuilt on the next press |
| `DICTATE_MAC` | *required* | ssh host of the brain (must resolve over the tailnet). No default ships with the package: `install-linux.sh --mac HOST` writes it |
| `DICTATE_MAC_IP` | unset | pins the Mac's address instead of resolving `DICTATE_MAC` |
| `DICTATE_DB` | derived | Flow's database on the Mac. Derived from the **remote** `$HOME` on first use and cached; set it only for a non-standard install |

## Verified numbers

Measured on the reference pair (Omarchy machine, M4 Pro Mac mini, Tailscale):

- F9 press to Flow armed: **~310 ms** warm, ~1 s on the first press after a reboot;
  audio follows ~250 ms after arming, because the receiver joins the stream as soon as
  Flow opens the virtual device
- capture chain, first frame: ~80-110 ms; first RTP packet at the Mac: **253 ms** after
  the streamer starts (with a consumer holding the device open) and **never**, if nothing
  holds it - the receiver only joins while the Mac side is consuming
- measures of "how long the chain takes" must not use `parec` defaults: `--latency-msec=5`
  reads 78 ms where the default reads 2401 ms, and that default is buffering, not latency
- release to transcript row: ~1.0 s (Flow's own processing)
- row to text typed: ~200 ms for short text, ~200 chars/s for long text
- delivery exactness: 675 characters including 19 capital I's, byte-identical
- wind rejection with the WebRTC high-pass: low-end share 39.7% -> 8.7%

## Failure modes

| Failure | Behaviour |
| --- | --- |
| Mac unreachable / asleep | press fails in ~0.9 s (measured 855 ms), microphone re-muted, no text, toast says so. **Cold presses used to report success** - that gap was found and fixed on 2026-09-13 |
| `roc-send` killed while idle | next press rebuilds it (device bring-up + streamer, ~1 s; the first words are not lost because audio starts ~250 ms after arming) |
| capture device removed (on the Linux side) | next press rebuilds device and stream |
| **the AEC reference sink follows your default sink** | leave `sink_master` unset and PipeWire attaches the echo-canceller's playback side to the *default* sink. If that is a removable device (Bluetooth), a BlueZ hiccup stops the filter producing frames entirely: the microphone is fine, both `--check`s pass, the receiver answers, and dictation delivers silence. The reference is now pinned to the mic's own card. Diagnose with `dictation-mic.sh status`: `aec_link=` must name a local sink, not a Bluetooth one. Found 2026-09-13, after two dictations returned nothing |
| a streamer whose capture starved from birth | it stays alive and used to be reused forever, so **one bad start poisoned every later press**. The press path now checks it - alive, aimed at the right address, not currently starving, not ancient - and rebuilds it when unhealthy |
| **receiver device removed (Mac)** | a press still arms Flow and delivers nothing. The Mac's `--check` reports the missing device; the Linux machine's now does too. Flow itself silently falls back to whichever input it can find, so a transcript may arrive from the *Mac's* room - not a failure mode you can detect from the Linux machine alone |
| Flow not running | the URL scheme relaunches it |
| Flow busy at start-up (marker unreadable) | retried once, then a clean failure - never silently becomes "row 0" |
| Flow logged out | trigger accepted, no transcript, release reports no transcript. Not literally tested - restoring a login needs your credentials, so I did not touch it; it collapses into the verified "no transcript" branch above |
| no transcript at all | release polls for ~7 s (15 ssh round trips, was 40 = 15.3 s), then names the cause when it can: the press watches the capture in the background, so it says "no audio left the microphone" (armed and digitally silent) or "the audio pipeline stalled" (no frames) instead of a bare "No transcript captured" |
| a failed `device bind` (an already-bound slot; also what a device left behind by a rename causes) | it tears the **live** receiver down and then fails: the endpoint list still looks right in `device show`, but nothing is listening - the device is silently dead. Repair with `install-macos.sh --rebind`, and the installer now recovers on its own, by recreating the device, whenever a bind fails |

## Verifying the audio path without speaking

The transport can be proved deterministically, with no microphone and no human:

```bash
# on the Linux machine: a known tone, matching the device's format
sox -n /tmp/tone.wav synth 5 sine 440 vol 0.6 channels 2 rate 44100

# on the Mac: record the virtual microphone while the tone plays
ffmpeg -y -f avfoundation -i ':1' -t 12 -ar 44100 -ac 2 /tmp/rx.wav &

# on the Linux machine: send that file instead of the live microphone
~/.local/bin/roc-send -i file:///tmp/tone.wav \
  -s rtp+rs8m://<mac-tailnet-ip>:10001 -r rs8m://<mac-tailnet-ip>:10002 \
  -c rtcp://<mac-tailnet-ip>:10003

# on the Mac: a tone that arrived reads about -11 dB mean; a dead path reads -91 dB
ffmpeg -i /tmp/rx.wav -af volumedetect -f null - 2>&1 | grep mean_volume
```

The Mac's driver log confirms it independently: a working stream logs
`session router: creating route ... address=<linux-host>:<port>` as the sender
starts, and `removing session` when it ends.

## Where this is going: the brain interface

The speech engine is the only part of this package that knows about a specific product.
`docs/brain-interface.md` describes the small contract - five subcommands, JSON on stdout - that
would let a local Whisper, a cloud STT service or a future Linux client take its place without
touching capture, transport or delivery.

## Verifying the delivery layer (no microphone, no Flow)

`~/bin/type-harness.sh` types a test string through the same `wtype` path dictation uses and
tells you whether it arrived byte-identical. It exists because it caught a delivery regression
in one run that reading the code twice did not.

`~/bin/paste-harness.sh` does the same for the clipboard-paste path: it puts a test string on
the clipboard, sends Ctrl+V into a real GTK entry (zenity) and compares what arrived. Its
default string is deliberately full of accents - `Mañana, ¿qué tal? Ñandú añejo, áéíóú, ü ü` -
because accented characters are exactly what wtype cannot deliver and why this path exists.
Both harnesses open one window for about ten seconds and close it again.

**It opens a terminal window** (one window, about ten seconds, closed again at the end), so run
it deliberately rather than in the middle of something:

```bash
~/bin/type-harness.sh                     # default string: 5 capitals, apostrophe, dashes
~/bin/type-harness.sh --delay 12          # after changing DICTATE_TYPE_DELAY
~/bin/type-harness.sh --text "Custom. Text." --keep-open
```

It refuses to type unless it can verify the scratch window is the focused one, because that is
exactly how a test string ends up in someone's editor otherwise.

## Traps worth knowing (the short list)

- **An echo-canceller's reference sink must not be left floating.** Unset, it
  follows the *default* sink; if that is a Bluetooth headset, the filter's
  playback side is attached to the headset, and a BlueZ error storm
  (`suspended -> error`, `Start error: Input/output error`) then stops the
  filter emitting frames at all - the microphone is healthy and every check on
  both ends passes while Flow receives silence. Pin it (`sink_master=`, i.e.
  `MIC_SINK_MASTER`), and read `aec_link=` in `dictation-mic.sh status`. Verified
  2026-09-13.

- macOS installers that extract with `tar -xP` **always exit non-zero** on
  modern macOS: `/usr` and `/Library` are firmlinks and cannot be created.
  Verify the payload, never the exit status.
- Omarchy renders toasts only via `omarchy-notification-send`; `notify-send`
  exits 0 and shows nothing.
- Hyprland ignores binds fired by synthesized keys (`wtype -k F9`); only a real
  keypress proves a binding works.
- `hyprctl` needs `HYPRLAND_INSTANCE_SIGNATURE`; without it it prints nothing,
  which reads exactly like "no binds registered".
- Non-interactive SSH has no `XDG_RUNTIME_DIR`, so every `pactl` call returns
  empty - this produced three phantom "device missing" alarms in one session.
- `module-echo-cancel` inherits its master's volume; muting the mic kills it.
- Three layers re-apply a remembered volume after your write: WirePlumber,
  `module-stream-restore`, and the ALSA mixer state.
- Arch's `roc-toolkit` package links `libsox_ng.so.3` without declaring it
  (`pacman -S sox` fixes it), and the sox backend then panics on `sox_ng 14.8`
  (roc #838, `sox backend: can't add driver`) - hence the private build in this
  package. The panic comes back if you call a bare `roc-send` from a **non-login**
  shell: PATH resolves to `/usr/bin/roc-send`, which has the sox backend. Use
  `~/.local/bin/roc-send` (or the scripts) in anything scripted - verified 2026-09-13,
  where a bare call core-dumped and the same command with the absolute path sent the
  tone cleanly.
- `roc-send -L` prints the scheme list on **stderr**, not stdout, so a
  `2>/dev/null` makes a perfectly good binary look broken.
- `... | grep -q` under `set -o pipefail` fails spuriously: grep closes the pipe
  early, the producer dies of SIGPIPE, and the pipeline reports failure even when
  the pattern matched. Capture the output, then match it.
- `roc-vad device bind` on an already-bound slot tears the live receiver down and
  then fails - "looks configured" is not "is listening". The Mac installer now
  recovers by itself when a bind fails: it deletes the device (which releases the
  stale slot and its UDP ports), recreates it and binds again - the state a rename
  leaves behind, where the old device still owns :10001.
- **`roc-vad device show` takes an index, not a uid** (`device show remote-mic` →
  `invalid index "remote-mic", not a number`, and it still exits 0). Get the index from
  `roc-vad device list`, where the uid is column 4 - the Mac installer's awk one-liner does
  exactly that. A probe that trusts the exit status here always "passes".
- **`dictation.conf` overrides the environment** (see Configuration): a failure test that sets
  `DICTATE_MAC=...` on the command line silently tests the configured host instead.
- **`wtype`'s modifier options do not work on this stack.** Measured 2026-09-13 over four
  variants - `-M shift -k l -m shift` with `-s 6`/`-s 20`/`-s 30` spacing, plus `-k L` and
  `-M shift -k L` - every one produced a lowercase `l`, while plain text typing produced
  `L` correctly (36/36 byte-identical runs of a 5-capital string at `-d 0`, `6` and `12`).
  Consequences: capitals must be left to wtype's text inference, and the `shift-enter`
  newline mode was **removed** on 2026-09-13 rather than shipped broken - it could only
  emit a plain Return, which submits a prompt. An old config value now degrades to `space`
  with one notice. The original note, for the record: the `shift-enter` newline
  mode (which sends `-M shift -k Return`) behaves like a plain Return, i.e. it SUBMITS -
  keep `DICTATE_NEWLINE=space`; and clipboard paste cannot be synthesised either, since the
  paste key is a modifier combo.
- **Non-ASCII characters are silently dropped by text typing.** `cafe Léo accion` arrived
  where `café Léo acción` was sent, on a Spanish layout: wtype maps a codepoint to a keysym
  and cannot type one the layout has no single key for (é needs a dead-key sequence). This
  is a real limitation for accented dictation and has no clean fix while modifiers are
  unavailable - worth knowing before promising Spanish support.
- **roc-vad only joins a session once a consumer opens the device on the Mac.**
  Nothing listens on UDP 10001 until Flow (or any recorder) captures "Remote Mic", so
  from the sending side there is no readiness signal to wait for - the packets simply do
  not arrive until the Mac side is consuming (verified: none in 12 s, then 253 ms after a
  recorder opened it). Do not gate the press on that: arm Flow, and audio follows.
- **Measure the capture chain with an explicit latency, never with `parec` defaults.**
  `parec --latency-msec=5` reads 78 ms for the first frame where the default reads
  2401 ms; the default is buffering, and reading it as "the chain takes 2.4 s to wake"
  cost a bogus fix attempt and a slower cold path until it was caught.

## Uninstall

```bash
ssh <linux-host> 'bash ~/remote-dictation/install-linux.sh --uninstall'
bash remote-dictation/install-macos.sh --uninstall    # --purge removes the driver too
```
