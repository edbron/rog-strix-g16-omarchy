# Hardware detection: why you might see N/A

Both `check.sh` and `install.sh` fingerprint the machine they're running
on before doing anything, so each can tell the difference between "this
fix is broken" (or "not applied yet") and "this fix doesn't apply to your
hardware." If you're running either on something other than a G615JMR,
expect a fair amount of `N/A`, that's the intended result, not a bug, but
not necessarily a wall of it either: several fixes here gate on the actual
mechanism (an amp, a CPU class) rather than on being an ASUS, and will
turn on for any brand that shares it. See "Not all of this is ASUS-only"
below for which ones.

## `check.sh`'s four outcomes

```
PASS  the fix's hardware is present and the fix is correctly in place
FAIL  the fix's hardware is present and the fix is missing or wrong
N/A   this machine doesn't match the hardware the fix targets, skipped
warn  informational, doesn't affect the exit code either way
```

Only `FAIL` sets a non-zero exit. A machine that reports every check as
`N/A` exits 0, correctly, because nothing that applies to it is broken.

## `install.sh` gates the same way

Each hardware-specific section (`do_audio`, the amp and board-specific
halves of `do_sleep`, `do_keyboard`, `do_theme`, `do_menu`) checks its
matching predicate before writing anything, reporting `N/A` instead of
installing a file that does nothing useful. This isn't only a reporting
nicety: `aura_support.ron` is one file shared across every board `asusd`
knows about, so before this gate, running the keyboard section on any
machine with `asusctl` installed would rewrite the `G615JM` entry in it
regardless of whether that board was actually present. `do_keyboard` and
`do_theme` are gated on `has_asus_nkey_keyboard`, not just on `asusctl`
being installed. On unrelated hardware, `./install.sh --dry-run` now
reports `N/A` for every hardware-specific section and "0 change(s) would
be made."

## What gets fingerprinted

`lib/hardware-detect.sh`, sourced by both `check.sh` and `install.sh`,
detects:

| Signal | How | Used to gate |
|---|---|---|
| Board name | `/sys/class/dmi/id/board_name` | keyboard zone patch only |
| CPU vendor | `/proc/cpuinfo` | VMD (Intel-only feature) |
| CPU model | `/proc/cpuinfo` | warm-idle fix (Intel HX-class, any brand) |
| GPU vendor(s) | `lspci -nn`, PCI vendor ID | NVIDIA sleep units |
| Audio codec | `/proc/asound/cards` + `codec#0`, **not** a hardcoded card index | codec-cache diagnostic only |
| TAS2781 amp | `lsmod` | s2idle-forcing, amp-protection audio fixes (any brand) |
| ASUS N-KEY keyboard | `lsusb` / sysfs, USB ID `0b05:19b6` | keyboard zone patch |

The audio codec's card index is discovered, not assumed. Card indices are
assigned in probe order and shift with whatever else is plugged in or how
the kernel happens to enumerate the dGPU's HDMI/DP audio function on a
given boot, so `card0` is not a safe constant even on the reference
machine, let alone someone else's.

## Not all of this is ASUS-only

Board name is now the narrowest and least-used gate here, on purpose: it's
only load-bearing for the keyboard zone patch, which really can't
generalize, it edits `asusd`'s own device table, and there's no non-ASUS
equivalent to patch. Everything else gates on the actual mechanism, not on
being an ASUS:

- **The soft-mixer ACP fix and the alsa-gain-pinning unit disable** (in
  `do_audio`) aren't gated on hardware at all. Both only act if the
  specific drop-in or service they target actually exists on the machine,
  so they're safe, and potentially useful, on any Realtek+ACP setup
  Omarchy manages this way, ASUS or not.
- **The amp-protection fixes** (`power_save=0`, no idle-suspend on the
  built-in sink) gate on `has_tas2781_amp` via `lsmod`, not on ASUS or on
  ALC294. TI's TAS2781 smart amp ships in laptops from several brands; any
  of them benefits from the same protection.
- **The warm-idle fix** (suspend-then-hibernate) gates on `is_no_s0ix_cpu`,
  a CPU model check for Intel's "HX" mobile-workstation suffix
  (`i9-14900HX`, `i7-13700HX`, ...), not on the G615 board. The mechanism
  is a CPU-die limitation shared by every laptop shipping that chip class,
  Dell, Lenovo, MSI, Razer, ASUS. Scoped to Intel only for now, see below.

Only the keyboard zone patch and its theme-following hook stay gated on
`has_asus_nkey_keyboard`, and the codec-cache diagnostic stays gated on
`is_target_codec` (it needs ALC294's exact DAC node addresses, 0x02/0x03,
which don't transfer to another codec).

## Applicability is gated on the narrowest verified signal, not the broadest plausible one

The warm-idle fix's gate went through three iterations, worth knowing
about because the middle one is a trap that looks reasonable:

1. **Too broad.** "No `total_hw_sleep` counter" looked like a good stand-in
   for "no S0ix." Tested against an unrelated HP laptop (Conexant codec,
   no discrete GPU, no ASUS anything, and not an HX-class CPU) and it
   false-FAILed: the counter is absent there for reasons that have nothing
   to do with the ~2.65 W warm-idle number this repo measured on the
   G615JMR.
2. **Too narrow.** Tightened to `is_g615_board`, the board this was
   actually measured on. Safe, but it also silently excluded every other
   laptop built on the same Intel HX-class chip, which has nothing to do
   with ASUS.
3. **Verified and general.** The actual cause is the CPU die, not the
   board, Intel's own "HX" naming marks it consistently across every OEM
   that ships those chips. `is_no_s0ix_cpu` gates on that instead, so the
   fix applies to any brand shipping the same CPU class. The exact
   ~2.65 W number stays labeled as measured on this machine specifically;
   the mechanism it's fixing does not.

The general rule going forward, see `CLAUDE.md` and `ROADMAP.md` for the
fuller version: prefer the narrowest signal that's actually verified, but
"verified" describes the mechanism, not the brand it happened to be
observed on first. A hardcoded-feeling but verified gate beats a broader
but speculative one, and a gate gets to be as broad as the evidence for
the underlying mechanism, no broader.

## If you're on different hardware

Every `N/A` line names what it's not matching. Read it as: this repo has
nothing to say about that part of your machine, not: something is broken.
If you have a G615-series board that reports something unexpected, an
AMD laptop with an "HX"-suffix CPU (untested, see the scoping note in
`lib/hardware-detect.sh`), or want to add detection for a different board
or codec entirely, see [../ROADMAP.md](../ROADMAP.md) for the current plan
and how a contributed profile would slot in.
