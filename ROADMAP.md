# Roadmap

This repo works for one laptop today: the ASUS ROG Strix G16 (G615JMR).
Most of what's here can't generalize, a fix keyed to this exact codec's
node addresses or this exact board's device table doesn't help someone on
a Dell or a different ASUS board. What can generalize is the scaffolding
around those fixes: detecting hardware, gating fixes on whether they apply,
and reporting honestly when they don't. This file tracks that, staged, so
the plan doesn't get built out of order.

## Guiding constraint

Chase "safe to run on any laptop, useful on the ones it recognizes," not
"works on any laptop." A fix nobody has measured on the hardware it claims
to help is worse than no fix. See `CLAUDE.md` for the fuller reasoning
behind gating on the narrowest verified signal rather than the broadest
plausible one.

## Phase 0: Detect hardware, gate reporting (done)

Landed in PR #1. `lib/hardware-detect.sh` fingerprints board, CPU vendor,
GPU vendor, audio codec, amp, and keyboard. `check.sh` gates every
fix-specific check behind the matching predicate, reporting `N/A` instead
of a false `FAIL` on hardware that doesn't match. Verified against an
unrelated HP laptop: reports `N/A` across the board, exits 0. See
[docs/hardware-detection.md](docs/hardware-detection.md).

## Phase 1: Gate `install.sh`, not just `check.sh` (done)

`do_audio`, the s2idle-forcing and suspend-then-hibernate halves of
`do_sleep`, `do_keyboard`, `do_theme`, and `do_menu` now check the
matching `is_*`/`has_*` predicate from `lib/hardware-detect.sh` before
writing anything hardware-specific, reporting `N/A` the same way
`check.sh` already did. No new detection logic was needed, this was
wiring the library that already existed into the apply path instead of
only the report path.

One real gap this closed, not just a reporting nicety: `aura_support.ron`
is one file shared across every board `asusd` knows about. Before this,
running the keyboard section on *any* machine with `asusctl` installed
would rewrite the `G615JM` entry in it regardless of whether that board
was actually present. `do_keyboard` and `do_theme` are now gated on
`has_asus_nkey_keyboard`, not just on `asusctl` being installed.

Verified: `./install.sh --dry-run` on the same unrelated HP laptop used to
verify Phase 0 now reports `N/A` for every hardware-specific section and
"0 change(s) would be made," only the generic Omarchy inhibit-delay file
still applies, correctly, since that one isn't hardware-specific.

## Phase 2: A quirk registry instead of a growing if/else

**Status: not started, blocked on a second real hardware profile existing.**

`is_target_codec` and `has_asus_nkey_keyboard` (used for the keyboard zone
patch) and `is_no_s0ix_cpu` (an Intel-only CPU-model check, see Phase 3)
are still single-hardware or single-vendor predicates baked directly into
`lib/hardware-detect.sh`. That's fine while there's one board and one
verified CPU family. It stops scaling the moment a second board, or AMD's
own HX-class chips, need their own entry. Replace the board-specific ones
with small per-quirk profile files, one per board+codec+keyboard
combination, e.g. `quirks/g615jmr.sh` as the first entry, each declaring
its own match condition and the fix parameters that go with it (codec
SSID, zone count, keyboard USB ID, measured idle-power numbers).

`lib/hardware-detect.sh` stays the fingerprinting layer, facts about the
machine. A new `lib/quirks.sh` becomes the matching layer, which profile
(if any) matches those facts. This is roughly what the Linux kernel's own
HDA quirk tables and `fwupd`'s device quirks already do, at a scale this
repo doesn't need yet.

Exit criteria: a second board's profile can be added as a new file without
touching the predicates the first board depends on.

## Phase 3: Split generic advice from hardware-specific payloads (mostly done)

Some of what's here is general Linux-laptop-power knowledge wearing this
machine's numbers, or an ASUS badge it doesn't need. VMD and NVIDIA
gating were already vendor-level, not board-level, as of Phase 0. Since
then, the audio and sleep fixes went the same way: the soft-mixer/
alsa-gain fixes in `do_audio` aren't gated on hardware at all (they're
self-gating on the drop-in/service existing), the amp-protection fixes
(`power_save`, idle-suspend) gate on `has_tas2781_amp`, not on ASUS or
ALC294, and the warm-idle fix gates on `is_no_s0ix_cpu`, a CPU-model check
for Intel's HX-class chips, not on the G615 board. See
[docs/hardware-detection.md](docs/hardware-detection.md), "Not all of this
is ASUS-only," for the full breakdown and the reasoning trail (the CPU gate
went through a too-broad and a too-narrow version before landing here).

What's left: the keyboard zone patch stays genuinely ASUS-only (it edits
`asusd`'s own device table, there's no non-ASUS equivalent), the
codec-cache diagnostic stays ALC294-only (its DAC node addresses are
codec-specific), and `is_no_s0ix_cpu` is scoped to Intel only, AMD's own
HX-class chips are a plausible extension but unverified, see the scoping
note in `lib/hardware-detect.sh` before widening it.

Exit criteria (done): the README's "What gets fixed" table marks which
rows apply broadly and which need this exact board or an ASUS keyboard.

## Phase 4: Accept community-contributed profiles

**Status: not started, blocked on Phase 2.**

The README's Contributing section already invites reports from other
G615-series owners, and, since Phase 0, from owners of unrelated hardware
entirely, the fingerprint `check.sh` prints is exactly the input a new
profile needs. Once Phase 2 exists, contributing support for a new board
becomes: run `./check.sh`, paste the fingerprint into an issue or a new
`quirks/<board>.sh`, open a PR. No forking the whole repo's assumptions
required.

Exit criteria: at least one profile in `quirks/` for hardware the original
author doesn't own.

## Explicit non-goals, for now

- **A GUI, package, or installer that auto-detects "your" fix.** This
  repo stays scripts plus docs, not a product.
- **Fixes for hardware nobody has measured.** A profile that guesses at
  numbers (idle watts, zone counts, timing) is worse than no profile.
- **Skipping ahead.** Land Phase 1 before Phase 2. Land Phase 2 before
  inventing a schema for hardware nobody has contributed data for yet. A
  half-built generalization, detection without gated apply, or a quirk
  schema nothing populates but the original board, is worse than either
  extreme.

## How to help right now

- **Own a G615-series board that behaves differently?** Open an issue
  with `./check.sh` output, see the README's Contributing section.
- **Own different hardware entirely?** Same ask: `./check.sh` output plus
  your board/codec/keyboard identifiers is exactly what Phase 2 needs,
  even though there's nowhere to plug it in yet.
- **Want to pick up Phase 1?** It's scoped, self-contained, and doesn't
  need you to own any particular hardware to implement, only to review.

This file is the public plan. `CLAUDE.md`'s "Generalizing to other
hardware and brands" section is the shorter, agent-facing pointer to it,
keep the two in sync rather than letting the plan drift between them.
