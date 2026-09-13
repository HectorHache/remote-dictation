# The brain interface (design)

Status: design note, 2026-09-13. Not implemented. This is E.2 on the roadmap.

## Problem

The package works, but its speech engine is welded in. `bin/dictate.sh` knows that the engine is
a macOS app reached over ssh, that it is armed through a URL scheme, that its transcripts land in
a sqlite `History` table, and that a rowid is how a session is recognised.

Everything else is already independent of it: capture, transport, delivery, health gating.

So keep the engine-specific knowledge in ONE place, behind a small contract, and let the rest of
the pipeline talk to that contract. A local Whisper, a cloud STT service, a different Mac app, or
a future Linux client of the same closed-source app can then be swapped in without touching
capture, transport or delivery.

## The contract

A brain is one executable, `dictation-brain-<name>` on `$PATH`, or a path in `DICTATE_BRAIN`.
It answers subcommands on stdout as JSON. Nothing else is fixed: no language, no transport, no
storage layout.

    brain describe              -> {"name","kind","languages","notes"}
    brain arm                   -> {"session":"<opaque token>","armed_ms":<int>}
    brain transcript <session>  -> {"text":"...","ready":true|false}
    brain disarm <session>      -> exit 0
    brain health                -> exit 0 when the engine can be armed at all

`armed_ms` is how long arming actually took. It exists because the honest UX question is not "how
fast is dictation" but "when is it really listening" - on the current path most of that first
second is spent arming a device on the other machine, and the interface should be able to say so
instead of pretending the press was instant.

`languages` is a list (`["en","zh"]` today). It exists so the delivery layer can warn BEFORE a
dictation in an unsupported language is thrown away by the engine, instead of after.

## Reference implementations

1. `dictation-brain-wisprflow-ssh` - today's behaviour moved behind the contract: arm by opening
   the app's URL scheme over ssh, session = `max(rowid)` read in that same round trip, transcript
   = the row above it, health = the ssh probe the sender already performs.
2. `dictation-brain-echo` - a stub with no engine at all: arm returns instantly, transcript
   returns a fixed string. This is what makes the delivery layer testable in one command with no
   microphone, no Mac and no speech engine. The two existing harnesses already prove the idea.

## What the rest of the pipeline keeps doing

- capture: unchanged (PipeWire source -> sender). A brain may consume a virtual device (today),
  receive a stream (a cloud brain), or own capture entirely (a local Whisper).
- transport: unchanged (RTP + FEC over the tailnet). A brain that owns capture simply does not use it.
- delivery: unchanged (clipboard paste, wtype fallback) and - the point - it needs to know nothing
  about the brain.
- health gating: unchanged, but keyed on `brain health` instead of an engine-specific probe.
- sessions: generalised from "max rowid" to whatever `arm` returns. A local engine returns a path
  or a counter; a cloud one returns a request id.

## Non-goals

- Not a plugin framework. One executable, five subcommands, JSON on stdout.
- Not a rewrite of transport or delivery.
- Not multi-brain routing: one brain per invocation, chosen by config.

## First steps when this is built

1. Extract today's ssh + sqlite logic into `bin/dictation-brain-wisprflow-ssh` with no behaviour
   change, and prove it with the existing harnesses.
2. Add `bin/dictation-brain-echo`, plus one test that runs the delivery layer against it.
3. Point `dictate.sh` at `DICTATE_BRAIN` (default: the ssh brain) and delete its engine-specific
   branches.
