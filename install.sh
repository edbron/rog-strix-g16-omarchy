#!/usr/bin/env bash
#
# Apply the ROG Strix G16 (G615JMR) fixes to an Omarchy / Arch install.
#
# Everything here is idempotent: re-running changes nothing that is already
# correct. Nothing is overwritten without a .bak.<epoch> beside it.
#
#   ./install.sh              apply everything
#   ./install.sh --dry-run    print what would change, touch nothing
#   ./install.sh audio sleep  apply only the named sections
#
# Sections: audio sleep keyboard nvidia theme menu
#
# NOT covered here because it cannot be scripted -- see docs/bios.md. Disabling
# Intel VMD in the BIOS is the single biggest win on this machine (-8.5 W idle)
# and no amount of OS config substitutes for it.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/hardware-detect.sh
source "$REPO/lib/hardware-detect.sh"
STAMP="$(date +%s)"
DRY=0
CHANGED=0

# ---------------------------------------------------------------- output ----

if [[ -t 1 ]]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'
else
  B=; G=; Y=; R=; C=; D=; N=
fi

section() { printf '\n%s== %s%s\n' "$B" "$1" "$N"; }
ok()      { printf '  %s.%s %s\n'      "$G" "$N" "$1"; }
act()     { printf '  %s+%s %s\n'      "$Y" "$N" "$1"; CHANGED=$((CHANGED+1)); }
warn()    { printf '  %s!%s %s\n'      "$R" "$N" "$1"; }
skip()    { printf '  %sN/A%s %s\n'    "$C" "$N" "$1"; }
note()    { printf '    %s%s%s\n'      "$D" "$1" "$N"; }

# ------------------------------------------------------------- primitives ----

# install_file <src-relative-to-repo> <dest> [mode]
# Copies only when the content differs. Backs up any file it replaces.
install_file() {
  local src="$REPO/$1" dest="$2" mode="${3:-644}" sudo_=""
  [[ "$dest" == /home/* || "$dest" == "$HOME"/* ]] || sudo_="sudo"

  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    ok "$dest"
    return
  fi

  if [[ -e "$dest" ]]; then
    act "$dest ${D}(replacing, backup at ${dest}.bak.${STAMP})${N}"
    (( DRY )) || $sudo_ cp -a "$dest" "$dest.bak.$STAMP"
  else
    act "$dest"
  fi

  (( DRY )) && return
  $sudo_ install -Dm"$mode" "$src" "$dest"
}

need_pkg() {
  pacman -Qq "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------ preflight -----

preflight() {
  section "Preflight"

  local board; board="$(detect_board)"
  if is_g615_board; then
    ok "board $board"
  else
    warn "board reads '$board', not a G615* ROG Strix G16"
    note "This repo was written for the G615JMR, but most fixes below gate on"
    note "the actual hardware they target (an amp, a CPU class, a keyboard),"
    note "not on this board name, and will report N/A rather than write"
    note "anything irrelevant. Only the keyboard zone patch is ASUS-only."
    note "Ctrl-C now if you'd rather not run this at all on unfamiliar hardware."
    sleep 5
  fi

  if is_target_amp; then
    ok "TAS2781 amp detected, amp-protection audio/suspend fixes apply"
  else
    note "no TAS2781 amp detected, the amp-protection parts of audio and"
    note "sleep will report N/A below (not ASUS-specific, any brand with"
    note "this amp needs them)."
  fi

  if is_no_s0ix_cpu; then
    ok "Intel HX-class CPU detected, warm-idle (no-S0ix) fix applies"
  else
    note "not an Intel HX-class CPU, the suspend-then-hibernate and menu"
    note "sections will report N/A below (not board-specific, any brand"
    note "shipping this CPU class hits the same problem)."
  fi

  if has_asus_nkey_keyboard; then
    ok "ASUS N-KEY keyboard detected, zone patch applies"
  else
    note "no ASUS N-KEY (0b05:19b6) keyboard detected, the keyboard and"
    note "theme sections will report N/A below. This one genuinely is"
    note "ASUS-only, it patches asusd's own device table."
  fi

  if [[ -r /etc/os-release ]] && grep -q '^ID=omarchy' /etc/os-release; then
    ok "Omarchy"
  else
    note "Not Omarchy -- everything except the menu section still applies."
  fi

  if (( DRY )); then
    printf '\n  %sdry run: nothing will be written%s\n' "$Y" "$N"
  fi
}

# ---------------------------------------------------------------- audio -----

do_audio() {
  section "Audio (ACP mixer + TAS2781 amp protection)"

  # The soft-mixer ratchet and the alsa-gain-pinning unit are ACP/PipeWire/
  # Omarchy config problems, not specific to this codec or amp: PipeWire's
  # ACP does jack-based port switching on any Realtek laptop codec it
  # manages this way, not just ALC294. Both blocks below only act if the
  # specific drop-in or service they target actually exists, so they're
  # safe to run on any hardware, nothing to gate here. See docs/audio.md.
  local sm
  for sm in "$HOME"/.config/wireplumber/wireplumber.conf.d/*.conf; do
    [[ -f "$sm" ]] || continue
    grep -q 'api\.alsa\.soft-mixer' "$sm" || continue
    act "disabling $(basename "$sm") ${D}(sets api.alsa.soft-mixer)${N}"
    note "This is the one-way ratchet to silence. Renamed, not deleted."
    (( DRY )) || mv "$sm" "$sm.disabled-$STAMP"
  done

  # A gain-pinning login unit fights ACP once soft-mixer is gone: it unmutes
  # both paths and forces Auto-Mute Enabled, the opposite of what ACP wants.
  if systemctl --user is-enabled omarchy-fix-alsa-gain.service >/dev/null 2>&1; then
    act "disabling omarchy-fix-alsa-gain.service ${D}(conflicts with ACP)${N}"
    (( DRY )) || systemctl --user disable --now omarchy-fix-alsa-gain.service
  fi

  # Everything below exists to protect a fragile smart amp from repeated
  # power cycling. Gated on the amp itself, not on ASUS or this exact
  # codec: any laptop with a TAS2781 benefits, regardless of brand.
  if is_target_amp; then
    install_file etc/modprobe.d/90-snd-hda-no-powersave.conf \
                 /etc/modprobe.d/90-snd-hda-no-powersave.conf

    install_file home/.config/wireplumber/wireplumber.conf.d/50-no-suspend-builtin-audio.conf \
                 "$HOME/.config/wireplumber/wireplumber.conf.d/50-no-suspend-builtin-audio.conf"

    # A late boot-time writer can silently override modprobe.d. This one bit us.
    if [[ -x /usr/local/bin/omarchy-powersave-tune ]] \
       && grep -qE '^[^#]*snd_hda_intel/parameters/power_save' /usr/local/bin/omarchy-powersave-tune 2>/dev/null; then
      warn "/usr/local/bin/omarchy-powersave-tune writes power_save at boot"
      note "It runs after modprobe, so it silently overrides the modprobe.d file."
      note "Comment that line out by hand; see docs/audio.md."
    fi
    note "power_save takes effect on reboot (or: sudo modprobe -r snd_hda_intel)"
  else
    skip "no TAS2781 amp detected, skipping the power-save/idle-suspend fixes"
  fi

  (( DRY )) || systemctl --user restart wireplumber 2>/dev/null || true
}

# ---------------------------------------------------------------- sleep -----

do_sleep() {
  section "Suspend / hibernate"

  # Forcing s2idle exists purely to protect the TAS2781 amps from an S3
  # resume that leaves them unpowered. No amp, no reason to override
  # mem_sleep.
  if is_target_amp; then
    install_file etc/tmpfiles.d/zz-s2idle.conf \
                 /etc/tmpfiles.d/zz-s2idle.conf
    if (( ! DRY )); then
      sudo systemd-tmpfiles --create /etc/tmpfiles.d/zz-s2idle.conf >/dev/null 2>&1 || true
    fi

    # mem_sleep_default=deep on the cmdline contradicts the tmpfiles rule. The
    # tmpfiles rule wins today, but leaving both in place is a trap for
    # whoever reads the cmdline next.
    if grep -q 'mem_sleep_default=deep' /proc/cmdline; then
      warn "kernel cmdline still carries mem_sleep_default=deep"
      note "Harmless today (the tmpfiles rule overrides it) but contradictory."
      note "Remove it by hand -- see docs/suspend.md. Not scripted: editing the"
      note "bootloader config wrong leaves you unbootable."
    fi
  else
    skip "no TAS2781 amp detected, s2idle is not required to protect it here"
  fi

  # The warm-idle fix (suspend-then-hibernate) exists because this CPU class
  # (Intel's "HX" mobile workstation line) has no S0ix. That's a CPU-die
  # limitation, not a G615JMR-specific one: any laptop built on an Intel
  # HX-class chip hits the same problem, regardless of brand. The measured
  # ~2.65 W number is specific to this machine; the mechanism isn't. See
  # docs/hardware-detection.md.
  if is_no_s0ix_cpu; then
    install_file etc/systemd/sleep.conf.d/10-suspend-then-hibernate.conf \
                 /etc/systemd/sleep.conf.d/10-suspend-then-hibernate.conf

    install_file etc/systemd/logind.conf.d/30-lid-suspend-then-hibernate.conf \
                 /etc/systemd/logind.conf.d/30-lid-suspend-then-hibernate.conf

    # Hibernation must actually be provisioned or suspend-then-hibernate is a
    # 30-minute countdown to nothing.
    if command -v omarchy-hibernation-available >/dev/null 2>&1; then
      if omarchy-hibernation-available >/dev/null 2>&1; then
        ok "hibernation provisioned"
      else
        warn "hibernation is NOT available -- suspend-then-hibernate will not hibernate"
        note "Run: omarchy-hibernate-setup  (or see docs/suspend.md)"
      fi
    elif ! grep -q '^resume=' /proc/cmdline && ! grep -q 'resume=' /proc/cmdline; then
      warn "no resume= on the kernel cmdline; hibernation will not resume"
    fi
  else
    skip "not an Intel HX-class CPU, the warm-idle (no-S0ix) fix doesn't apply here"
  fi

  # Omarchy's lock-before-suspend inhibitor needs longer than the 5 s default
  # when a lid close also reconfigures displays. Generic to any Omarchy
  # install, not gated on this laptop's hardware.
  install_file etc/systemd/logind.conf.d/20-inhibit-delay.conf \
               /etc/systemd/logind.conf.d/20-inhibit-delay.conf
}

# --------------------------------------------------------------- nvidia -----

do_nvidia() {
  section "NVIDIA sleep units"

  if ! has_nvidia_gpu; then
    skip "no NVIDIA GPU detected"
    return
  fi

  local u missing=()
  for u in nvidia-suspend nvidia-hibernate nvidia-resume nvidia-suspend-then-hibernate; do
    if systemctl list-unit-files "$u.service" >/dev/null 2>&1 \
       && systemctl cat "$u.service" >/dev/null 2>&1; then
      if [[ "$(systemctl is-enabled "$u.service" 2>/dev/null)" == enabled ]]; then
        ok "$u.service"
      else
        missing+=("$u.service")
      fi
    else
      warn "$u.service not installed ${D}(nvidia-utils missing?)${N}"
    fi
  done

  if (( ${#missing[@]} )); then
    act "enabling ${missing[*]}"
    note "Arch ships these disabled. Without them hibernate resume dies with -5."
    (( DRY )) || sudo systemctl enable "${missing[@]}"
  fi
}

# ------------------------------------------------------------- keyboard -----

do_keyboard() {
  section "Keyboard RGB zones (asusd)"

  if ! need_pkg asusctl; then
    note "asusctl not installed, skipping"
    note "Install it for fan curves, RGB and power profiles: pacman -S asusctl"
    return
  fi

  # aura_support.ron is one file shared across every board asusd knows about.
  # Without this gate, running the patcher on any machine with asusctl
  # installed rewrites the G615JM entry regardless of whether that's the
  # board actually present.
  if ! has_asus_nkey_keyboard; then
    skip "no ASUS N-KEY (0b05:19b6) keyboard detected"
    note "the G615JM entry this section patches isn't yours to rewrite"
    return
  fi

  install_file usr/local/bin/asusd-aura-zones /usr/local/bin/asusd-aura-zones 755
  install_file etc/pacman.d/hooks/zz-asusd-aura-zones.hook \
               /etc/pacman.d/hooks/zz-asusd-aura-zones.hook

  if (( ! DRY )); then
    if sudo /usr/local/bin/asusd-aura-zones; then
      systemctl is-active asusd >/dev/null 2>&1 && sudo systemctl restart asusd
    fi
  fi
}

# ---------------------------------------------------------------- theme -----

do_theme() {
  section "Keyboard follows the theme"

  if ! need_pkg asusctl; then
    note "asusctl not installed, skipping"
    return
  fi
  if ! command -v omarchy >/dev/null 2>&1; then
    note "not Omarchy, skipping"
    return
  fi
  if ! has_asus_nkey_keyboard; then
    skip "no ASUS N-KEY (0b05:19b6) keyboard detected, no zones to repaint"
    return
  fi

  # Omarchy already paints the whole keyboard the theme colour via
  # omarchy-theme-set-keyboard-asus-rog. This adds the four-zone gradient on
  # top, and runs after it. See docs/keyboard.md.
  install_file home/.local/bin/omarchy-theme-set-keyboard-zones \
               "$HOME/.local/bin/omarchy-theme-set-keyboard-zones" 755

  # theme-set repaints on every theme change; post-boot is needed because asusd
  # persists multizone_on: false and restores the flat colour at boot.
  local h
  for h in theme-set post-boot; do
    local dest="$HOME/.config/omarchy/hooks/$h.d/omarchy-theme-set-keyboard-zones"
    if [[ -f "$dest" ]] && cmp -s "$HOME/.local/bin/omarchy-theme-set-keyboard-zones" "$dest"; then
      ok "$h hook"
    else
      act "$h hook"
      (( DRY )) || omarchy hook install "$h" "$HOME/.local/bin/omarchy-theme-set-keyboard-zones" >/dev/null
    fi
  done

  (( DRY )) || bash "$HOME/.local/bin/omarchy-theme-set-keyboard-zones" || true
  note "modes: gradient (default), palette, accent -- set MODE in"
  note "~/.config/omarchy/keyboard-zones.conf"
}

# ----------------------------------------------------------------- menu -----

do_menu() {
  section "Omarchy menu"

  local dest="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  local key='"system.suspend"'

  # This override exists to route Suspend at the warm-idle (no-S0ix) fix in
  # do_sleep, gated the same way that is.
  if ! is_no_s0ix_cpu; then
    skip "not an Intel HX-class CPU, the suspend-then-hibernate rationale doesn't apply here"
    return
  fi

  if [[ ! -d "$HOME/.config/omarchy" ]]; then
    note "no ~/.config/omarchy, skipping"
    return
  fi

  if [[ -f "$dest" ]] && grep -q "$key" "$dest"; then
    ok "$dest ${D}(system.suspend already overridden)${N}"
    return
  fi

  if [[ ! -f "$dest" ]]; then
    install_file home/.config/omarchy/extensions/omarchy-menu.jsonc "$dest"
    return
  fi

  act "$dest ${D}(appending system.suspend override)${N}"
  (( DRY )) && return
  cp -a "$dest" "$dest.bak.$STAMP"
  # Insert before the final closing brace so existing entries survive.
  python3 - "$dest" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
entry = (
    '\n  // Suspend should end in hibernation rather than an open-ended s2idle:\n'
    '  // this platform has no S0ix, so a "suspended" machine still burns ~2.65 W\n'
    '  // with the fan off. See /etc/systemd/sleep.conf.d/10-suspend-then-hibernate.conf.\n'
    '  "system.suspend": {"action":"systemctl suspend-then-hibernate"},\n'
)
i = src.rstrip().rfind('}')
if i == -1:
    sys.exit("omarchy-menu.jsonc has no closing brace; edit it by hand")
open(path, 'w').write(src[:i] + entry + src[i:])
PY
  command -v omarchy >/dev/null 2>&1 && omarchy restart shell >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ main -----

SECTIONS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY=1 ;;
    -h|--help)    sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" \
                    | sed '$d; s/^# \?//'; exit 0 ;;
    audio|sleep|keyboard|nvidia|menu|theme) SECTIONS+=("$arg") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
(( ${#SECTIONS[@]} )) || SECTIONS=(audio sleep nvidia keyboard theme menu)

preflight
for s in "${SECTIONS[@]}"; do "do_$s"; done

section "Done"
if (( DRY )); then
  printf '  %d change(s) would be made.\n' "$CHANGED"
else
  printf '  %d change(s) made.\n' "$CHANGED"
  if (( CHANGED )); then
    printf '  %sReboot to pick up the modprobe and cmdline-adjacent changes.%s\n' "$B" "$N"
  fi
fi
printf '  Verify any time with: %s./check.sh%s\n' "$B" "$N"
printf '  %sThe BIOS VMD change is not applied by this script -- read docs/bios.md.%s\n' "$Y" "$N"
