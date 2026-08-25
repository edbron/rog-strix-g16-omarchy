#!/usr/bin/env bash
#
# Read-only health check for the ROG Strix G16 (G615JMR) fixes.
# Writes nothing, needs no root. Exit 0 if everything applicable passed.
#
# Every fix in this repo targets specific hardware (a codec, an amp, a board
# family, a CPU vendor), not "any laptop". This script fingerprints the
# machine it's running on first, then gates each fix-specific check behind
# whether that hardware is actually present:
#
#   PASS  the fix applies here and is correctly in place
#   FAIL  the fix applies here and is missing or wrong
#   N/A   this machine doesn't match the hardware the fix targets, skipped
#   warn  informational, doesn't affect the exit code
#
# Only FAIL affects the exit code. N/A is not a failure -- it means this
# specific check has nothing to say about your hardware, see CLAUDE.md
# ("Generalizing to other hardware") for where that's headed.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/hardware-detect.sh
source "$REPO/lib/hardware-detect.sh"

FAIL=0
NA=0

if [[ -t 1 ]]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'
else
  B=; G=; Y=; R=; C=; D=; N=
fi

section() { printf '\n%s== %s%s\n' "$B" "$1" "$N"; }
pass()    { printf '  %s...%s %s\n' "$G" "$N" "$1"; }
fail()    { printf '  %sFAIL%s %s\n' "$R" "$N" "$1"; FAIL=1; }
warn()    { printf '  %swarn%s %s\n' "$Y" "$N" "$1"; }
na()      { printf '  %sN/A %s %s\n' "$C" "$N" "$1"; NA=$((NA+1)); }
note()    { printf '       %s%s%s\n' "$D" "$1" "$N"; }

read_or() { cat "$1" 2>/dev/null || echo "$2"; }

# ------------------------------------------------------------ fingerprint -----

section "Machine"
BOARD="$(detect_board)"
VENDOR="$(detect_sys_vendor)"
CPU_VENDOR="$(detect_cpu_vendor)"
GPU_VENDOR="$(detect_gpu_vendor)"
CODEC_NAME="$(detect_codec_name)"
AMP="no"; has_tas2781_amp && AMP="yes (TAS2781)"
KBD="no"; has_asus_nkey_keyboard && KBD="yes (ASUS N-KEY 0b05:19b6)"

printf '  %-22s %s (%s)\n' "vendor / board" "$VENDOR" "$BOARD"
printf '  %-22s %s\n'      "bios"           "$(detect_bios)"
printf '  %-22s %s\n'      "kernel"         "$(uname -r)"
printf '  %-22s %s\n'      "cpu vendor"     "$CPU_VENDOR"
printf '  %-22s %s\n'      "gpu vendor(s)"  "$GPU_VENDOR"
printf '  %-22s %s\n'      "audio codec"    "${CODEC_NAME:-unknown / not found}"
printf '  %-22s %s\n'      "amp"            "$AMP"
printf '  %-22s %s\n'      "keyboard"       "$KBD"

if ! is_g615_board; then
  note "Board doesn't match G615* -- the keyboard-zone and theme-following"
  note "fixes below target that family specifically and will read N/A."
fi

# ------------------------------------------------------------------- vmd -----

section "Intel VMD (idle power)"
if ! is_vmd_capable_vendor; then
  na "VMD is an Intel-only feature; CPU vendor is $CPU_VENDOR"
elif lspci -D 2>/dev/null | grep -q '^10000:'; then
  fail "NVMe still behind VMD ${D}(devices in PCI domain 10000:)${N}"
  note "VMD blocks PCIe ASPM: the package never leaves PC2 and idle costs"
  note "a large, board-specific amount more than it needs to. No OS tuning"
  note "recovers this. Fix it in the BIOS -- docs/bios.md."
else
  pass "VMD off ${D}(all devices in domain 0000)${N}"
fi

# ----------------------------------------------------------------- sleep -----

section "Suspend"

if is_target_amp; then
  ms="$(read_or /sys/power/mem_sleep '?')"
  if [[ "$ms" == *'[s2idle]'* ]]; then
    pass "mem_sleep = $ms"
  else
    fail "mem_sleep = $ms ${D}(want [s2idle])${N}"
    note "Under deep/S3 the TAS2781 speaker amps resume unpowered and only a"
    note "cold boot revives them."
  fi

  if grep -q 'mem_sleep_default=deep' /proc/cmdline; then
    warn "kernel cmdline still has mem_sleep_default=deep"
    note "Overridden by /etc/tmpfiles.d/zz-s2idle.conf, so harmless -- but the"
    note "two disagree, which will mislead the next person. docs/suspend.md."
  fi

  [[ -f /etc/tmpfiles.d/zz-s2idle.conf ]] \
    && pass "/etc/tmpfiles.d/zz-s2idle.conf" \
    || fail "missing /etc/tmpfiles.d/zz-s2idle.conf"
else
  na "no TAS2781 amp detected -- deep/S3 suspend is likely safe here, s2idle is not required"
fi

# The warm-idle fix (and its measured ~2.65 W number) targets a CPU class
# (Intel HX-class, no S0ix), not a board. "No total_hw_sleep counter" alone
# isn't a safe stand-in for that on unrelated hardware -- lots of laptops
# lack the counter for unrelated reasons -- so the hard PASS/FAIL is gated
# on the CPU class this was actually verified against, not a board name,
# so it applies to any brand shipping the same chip. See
# docs/hardware-detection.md.
if is_no_s0ix_cpu; then
  if has_s0ix_counters && [[ "$(read_or /sys/power/suspend_stats/total_hw_sleep 0)" != 0 ]]; then
    na "total_hw_sleep > 0 -- this platform appears to support real S0ix after all"
    note "suspend-then-hibernate exists to work around platforms with NO S0ix."
    note "Yours may already sleep for real; verify before assuming you need it."
  else
    note "total_hw_sleep = 0 is EXPECTED on an Intel HX-class CPU (no S0ix)."
    note "s2idle only freezes the OS. That is the platform floor, not a"
    note "misconfiguration -- hence suspend-then-hibernate."
    for f in /etc/systemd/sleep.conf.d/10-suspend-then-hibernate.conf \
             /etc/systemd/logind.conf.d/30-lid-suspend-then-hibernate.conf; do
      [[ -f "$f" ]] && pass "$f" || fail "missing $f"
    done
  fi
else
  na "not an Intel HX-class CPU, the warm-idle (no-S0ix) fix doesn't apply here"
  if has_s0ix_counters; then
    note "total_hw_sleep on your platform: $(read_or /sys/power/suspend_stats/total_hw_sleep 0)"
    note "If it stays 0 across a real suspend, your CPU may also lack S0ix"
    note "and the same suspend-then-hibernate reasoning could apply -- but"
    note "re-measure your own idle draw before trusting these numbers."
  else
    note "no total_hw_sleep counter exposed at all; can't infer S0ix support"
    note "from that alone on this platform."
  fi
fi

# ---------------------------------------------------------------- nvidia -----

section "NVIDIA sleep units"
if has_nvidia_gpu; then
  for u in nvidia-suspend nvidia-hibernate nvidia-resume nvidia-suspend-then-hibernate; do
    state="$(systemctl is-enabled "$u.service" 2>/dev/null || echo missing)"
    if [[ "$state" == enabled ]]; then
      pass "$u.service"
    else
      fail "$u.service is $state ${D}(Arch ships these disabled)${N}"
      note "Without them hibernate resume dies: nv_pmops_freeze returns -5."
    fi
  done
else
  na "no NVIDIA GPU detected (vendor(s): $GPU_VENDOR)"
fi

# ----------------------------------------------------------------- audio -----

section "Audio"

# Soft-mixer and the alsa-gain-pinning unit are ACP/PipeWire/Omarchy config
# problems, not specific to this codec or amp, checked regardless of
# hardware match.
if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
  if pactl list sinks 2>/dev/null | grep -q soft-mixer; then
    fail "api.alsa.soft-mixer is active"
    note "This is the one-way ratchet to silence: ACP applies its downward"
    note "mixer writes on every port switch but never the upward ones."
  else
    pass "soft-mixer not in use ${D}(PipeWire owns the hardware mixer)${N}"
  fi
fi

if systemctl --user is-enabled omarchy-fix-alsa-gain.service >/dev/null 2>&1; then
  warn "omarchy-fix-alsa-gain.service is enabled"
  note "With soft-mixer gone this unit fights ACP -- it forces Auto-Mute"
  note "Enabled and unmutes both paths. Disable it."
fi

# power_save and idle-suspend exist to protect a fragile smart amp from
# repeated power cycling, gated on the amp itself, not on ASUS or this
# exact codec: any laptop with a TAS2781 needs the same protection.
if is_target_amp; then
  ps_val="$(read_or /sys/module/snd_hda_intel/parameters/power_save '?')"
  if [[ "$ps_val" == 0 ]]; then
    pass "snd_hda_intel power_save = 0"
  else
    fail "snd_hda_intel power_save = $ps_val ${D}(want 0)${N}"
    note "If modprobe.d looks right but the live value disagrees, a LATE writer"
    note "is overriding it after modprobe. Check /usr/local/bin and custom units"
    note "-- not just modprobe.d/udev/tlp/PPD."
  fi

  # Assert the property, not the state. A node that has not been opened since
  # WirePlumber started is legitimately `suspended`; the rule only stops an
  # *idle* node from being closed. Checking state alone false-alarms after every
  # wireplumber restart.
  if command -v pw-dump >/dev/null 2>&1; then
    read -r tmo state < <(pw-dump 2>/dev/null | python3 -c "
import json, sys
for o in json.load(sys.stdin):
    info = o.get('info') or {}
    p = info.get('props') or {}
    if p.get('node.name', '').startswith('alsa_output.pci-0000_00_1f.3'):
        print(p.get('session.suspend-timeout-seconds', 'unset'), info.get('state', '?'))
        break
else:
    print('no-node', '?')
" 2>/dev/null)

    case "$tmo" in
      0)       pass "built-in sink will not idle-suspend ${D}(timeout 0, currently $state)${N}"
               [[ "$state" == suspended ]] && note "suspended = nothing has played since wireplumber started; normal" ;;
      no-node) warn "built-in analog sink not found" ;;
      *)       fail "built-in sink suspend-timeout is '$tmo' ${D}(want 0)${N}"
               note "WirePlumber will close the PCM after 5 s idle, letting the"
               note "codec and amps drop power. Check 50-no-suspend-builtin-audio.conf." ;;
    esac
  fi
else
  na "no TAS2781 amp detected -- power-save/idle-suspend amp protection not needed here"
fi

# The control cache can disagree with the codec's real amp registers. amixer,
# wpctl and pactl all read the cache, so they pass while the speakers are dead.
# The exact DAC node addresses (0x02 headphone, 0x03 speaker) are ALC294-
# specific, so unlike the checks above, this one genuinely needs this codec.
if is_target_codec; then
  # Node 0x02 = Headphone DAC, node 0x03 = Speaker DAC. One of them reading
  # [0x00 0x00] is normal -- that is auto-mute muting the path that is not in use.
  # BOTH at zero is the stranded-cache failure.
  codec="$(detect_codec_proc_path)"
  amp_of() {
    sed -n "/^Node $1 /,/^  Connection/p" "$codec" \
      | grep -m1 -o 'Amp-Out vals: *\[[^]]*\]' | grep -o '\[.*\]'
  }
  if [[ -n "$codec" && -r "$codec" ]]; then
    hp="$(amp_of 0x02)"; spk="$(amp_of 0x03)"
    if [[ "$hp" == '[0x00 0x00]' && "$spk" == '[0x00 0x00]' ]]; then
      fail "both DACs stranded at [0x00 0x00] = -65.25 dB (silence)"
      note "The mixer will still read 100%. The HDA driver caches amp values and"
      note "skips the write when the new value equals the cached one, so re-setting"
      note "100% is a no-op. Nudge through another value to force a real write:"
      note "  amixer -c 0 sset Speaker 50% && amixer -c 0 sset Speaker 100%"
      note "Silence on speakers AND headphones rules out the TAS2781 amps --"
      note "headphones do not pass through them. Look at the codec."
    elif [[ -n "$hp$spk" ]]; then
      pass "codec amps live ${D}(headphone $hp, speaker $spk)${N}"
      [[ "$hp"  == '[0x00 0x00]' ]] && note "headphone muted = auto-mute, nothing plugged in"
      [[ "$spk" == '[0x00 0x00]' ]] && note "speaker muted = auto-mute, headphones plugged in"
    fi
  fi
else
  na "audio codec is '${CODEC_NAME:-unknown}', not ALC294+TAS2781"
  note "the codec-cache diagnostic needs this exact codec's DAC node addresses"
fi

# -------------------------------------------------------------- keyboard -----

section "Keyboard RGB"
if ! command -v asusctl >/dev/null 2>&1; then
  na "asusctl not installed"
elif ! has_asus_nkey_keyboard; then
  na "no ASUS N-KEY (0b05:19b6) keyboard detected -- asusd is present, but the"
  note "zone patch below targets that keyboard's device table entry specifically."
  note "If your ASUS keyboard reports NotSupported for zoned effects, check"
  note "your own board's basic_zones entry in aura_support.ron."
else
  RON=/usr/share/asusd/aura_support.ron
  if [[ -r "$RON" ]]; then
    zones="$(python3 - "$RON" <<'PY' 2>/dev/null
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'\(\s*device_name:\s*"G615JM",.*?basic_zones:\s*(\[[^\]]*\])', src, re.DOTALL)
print(m.group(1) if m else "NO-ENTRY")
PY
)"
    if ! is_g615_board; then
      na "board is not G615* -- the G615JM entry this repo patches isn't yours"
      note "detected zones for reference: $zones"
    else
      case "$zones" in
        '[]')       fail "G615JM declares no zones ${D}(every zoned effect returns NotSupported)${N}"
                    note "Run: sudo /usr/local/bin/asusd-aura-zones && sudo systemctl restart asusd" ;;
        NO-ENTRY|'') warn "no G615JM entry in $RON ${D}(upstream may have renamed it)${N}" ;;
        *)          pass "G615JM zones = $zones" ;;
      esac
      [[ -f /etc/pacman.d/hooks/zz-asusd-aura-zones.hook ]] \
        && pass "pacman hook present ${D}(survives asusctl upgrades)${N}" \
        || fail "missing pacman hook -- the next asusctl upgrade reverts the zones"

      # Theme-following zones. Both hooks matter: theme-set repaints on a theme
      # change, post-boot because asusd persists multizone_on: false and restores
      # the flat colour at boot.
      if [[ -x "$HOME/.local/bin/omarchy-theme-set-keyboard-zones" ]]; then
        for h in theme-set post-boot; do
          [[ -f "$HOME/.config/omarchy/hooks/$h.d/omarchy-theme-set-keyboard-zones" ]] \
            && pass "$h hook installed" \
            || warn "$h hook missing ${D}(omarchy hook install $h ~/.local/bin/omarchy-theme-set-keyboard-zones)${N}"
        done
      else
        note "theme-following zones not installed (optional)"
      fi
    fi
  else
    note "$RON not readable"
  fi
fi

# ------------------------------------------------------------------ done -----

section "Result"
if (( FAIL )); then
  printf '  %sSomething applicable to this machine is off. Read the FAIL lines above.%s\n' "$R" "$N"
else
  printf '  %sAll checks that apply to this machine passed.%s\n' "$G" "$N"
fi
(( NA )) && printf '  %s%d check(s) not applicable to this hardware -- see the fingerprint above.%s\n' "$D" "$NA" "$N"
exit "$FAIL"
