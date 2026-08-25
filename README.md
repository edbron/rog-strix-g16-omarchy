# ROG Strix G16 (G615JMR) on Omarchy

Fixes for an ASUS ROG Strix G16 running [Omarchy](https://omarchy.org) (Arch +
Hyprland). Out of the box this machine idles at nearly twice the power it needs
to, loses its speakers after suspend, ships a keyboard whose RGB zones the
daemon refuses to address, and fails to resume from hibernate.

All of it is fixable. Most of it took a long time to diagnose because the
obvious diagnostic lies, the mixer reads 100% while the speakers are dead, the
GPU reads `active` while it is asleep, `modprobe -c` reports a value the running
kernel doesn't have. The notes here try to save you that.

**Hardware this was written against**

| | |
|---|---|
| Board | `G615JMR` (ASUS ROG Strix G16), BIOS 318 |
| CPU | Intel Core i9-14900HX (Raptor Lake-HX) |
| GPU | NVIDIA RTX 5060 Max-Q + Raptor Lake UHD iGPU |
| Audio | Realtek ALC294 + 2× TI TAS2781 smart amps (`1043:1204`) |
| Keyboard | ASUS N-KEY `0b05:19b6`, 4-zone RGB |
| OS | Omarchy, kernel 7.1, `nvidia-open-dkms` 610, `asusctl` 6.3.8 |

Close siblings (G615LR, G615JHR, other G615* Strix G16s) should be fine; the
audio and keyboard sections assume this exact codec and keyboard.

---

## Quick start

```sh
git clone https://github.com/edbron/rog-strix-g16-omarchy
cd rog-strix-g16-omarchy

./check.sh              # read-only: what's wrong right now
./install.sh --dry-run  # what would change
./install.sh            # apply it
reboot
```

`install.sh` is idempotent and backs up anything it replaces to
`<file>.bak.<epoch>`. `./uninstall.sh` reverts it. You can apply one area at a
time: `./install.sh audio sleep`.

`check.sh` fingerprints your hardware first and only fails a check when the
matching hardware is actually present, reporting `N/A` for anything that
isn't. On a machine other than a G615JMR, expect mostly `N/A`, that's
correct, not a bug: see [docs/hardware-detection.md](docs/hardware-detection.md).

**Do the BIOS change too.** It is the single biggest win here and no script can
do it for you: **[docs/bios.md](docs/bios.md)**.

---

## What gets fixed

The **Applies to** column is what `check.sh`/`install.sh` actually gate
each fix on, not a guess. "This board" fixes stay narrow on purpose, see
[ROADMAP.md](ROADMAP.md); everything else already targets the underlying
hardware or software trait, not the ASUS badge, and will self-detect on
other brands that share it.

| Problem | Fix | Applies to | Where |
|---|---|---|---|
| **Idles at 21.5 W, ~4 h on battery** | Disable Intel VMD in BIOS → **13.0 W, ~6.8 h** | Any Intel laptop | [bios.md](docs/bios.md) *(manual)* |
| Speakers dead after suspend, only a cold boot revives them | Force s2idle; never S3 | Any laptop with a TAS2781 amp | [suspend.md](docs/suspend.md) |
| Warm in the bag after a long "suspend" | `suspend-then-hibernate`, 30 min | Any Intel HX-class CPU | [suspend.md](docs/suspend.md) |
| Hibernate resume fails with `-5` | Enable the four `nvidia-*.service` sleep units | Any NVIDIA GPU | [suspend.md](docs/suspend.md) |
| Audio goes quiet or silent, keeps coming back | Remove the `soft-mixer` drop-in; let PipeWire own the mixer | Any Realtek+ACP setup (self-checking) | [audio.md](docs/audio.md) |
| Speakers crackle / drop out when idle | `snd_hda_intel power_save=0` + no WirePlumber idle-suspend | Any laptop with a TAS2781 amp | [audio.md](docs/audio.md) |
| `asusctl aura ... --zone N` returns `NotSupported` | Patch the four zones into `aura_support.ron`, pinned by a pacman hook | This board (G615JMR) | [keyboard.md](docs/keyboard.md) |
| Super key stops working | It's a firmware lock. Press **Fn+Super** (twice) | ASUS N-KEY keyboard | [keyboard.md](docs/keyboard.md) |
| Keyboard is one flat colour per theme | Spread the theme across all four zones, re-applied at boot | This board (G615JMR) | [keyboard.md](docs/keyboard.md) |
| Wi-Fi bar icon shows disconnected on a working link | NM profile missing `802-11-wireless.mode` | Any Omarchy install | [network.md](docs/network.md) |

---

## The one number that matters

Everything else on this list is a papercut next to VMD.

```
Intel VMD enabled   21.5 W idle    4.0 h on the 88.1 Wh battery
Intel VMD disabled  13.0 W idle    6.8 h
```

VMD-managed PCIe links cannot negotiate ASPM, so the CPU package never leaves
PC2. Every sysfs knob that gets recommended for laptop battery life was measured
on this machine and was worthless by comparison, 165 Hz → 60 Hz saved 0.27 W,
and PCI/USB runtime PM, `panel_od`, audio idle tuning and Wi-Fi powersave
produced *no measurable change at all*.

So: don't tune sysfs chasing idle watts here. Turn off VMD, then stop. The
remaining floor is hardware.

If you dual-boot Windows, **read [docs/bios.md](docs/bios.md) before flipping
the switch**. Windows will not boot with VMD off until you prepare it, and if
your C: is BitLocker-encrypted the storage-mode change moves TPM PCRs and you
will need your recovery key.

---

## Repo layout

```
install.sh          apply (idempotent, --dry-run supported, per-section)
uninstall.sh        revert
check.sh            read-only health check, fingerprints the machine first and
                     gates each check on whether the hardware it targets is
                     present (N/A rather than FAIL on unrelated hardware),
                     exits non-zero only if an applicable check is off

lib/hardware-detect.sh   shared board/CPU/codec/keyboard/GPU detection, used
                          by both install.sh and check.sh

etc/                system files, installed to the same paths
  tmpfiles.d/zz-s2idle.conf
  systemd/sleep.conf.d/10-suspend-then-hibernate.conf
  systemd/logind.conf.d/30-lid-suspend-then-hibernate.conf
  modprobe.d/90-snd-hda-no-powersave.conf
  pacman.d/hooks/zz-asusd-aura-zones.hook
usr/local/bin/asusd-aura-zones
home/.local/bin/omarchy-theme-set-keyboard-zones
home/.config/…      user files, installed under $HOME

docs/               the reasoning, the dead ends, and how to diagnose a relapse
  hardware-detection.md   how check.sh decides what applies to your machine
```

Every config file carries its own rationale in comments. If you only take one
thing from this repo, take the comments they say *why*, which is the part that
stops you undoing the fix six months later.

---

## Reading the diagnostics on this machine

Four readings here are actively misleading. Each cost real time:

- **The ALSA mixer lies about the speakers.** `amixer`, `wpctl` and `pactl` all
  read the driver's control cache, which can disagree with the codec's actual
  amp registers. A perfect-looking 100% mixer with total silence is a real
  state. Ground truth is `/proc/asound/card0/codec#0`.
- **`runtime_status` on the dGPU is meaningless across a system suspend.**
  System suspend bypasses runtime PM, so the file simply never updates and reads
  `active` whether or not the GPU slept. Don't conclude anything from it.
- **`nvidia-smi` wakes the GPU.** Polling it during a power measurement creates
  the very problem you're measuring. Read PM state from sysfs only.
- **`modprobe -c` describes intent, not reality.** A script running late in boot
  can overwrite a module parameter long after modprobe applied it. When the two
  disagree, go looking for a late writer in `/usr/local/bin` and custom units.

- **`total_hw_sleep` stuck at 0 is not a bug.** Raptor Lake-HX implements no
  S0ix at all. Neither do the LPIT residency counters. `turbostat` will also
  refuse `Pkg%pc10`. Use `Pkg%pc2`/`pc3`/`pc6` instead.

---

## Contributing

If you have a G615-series Strix G16 and something here is wrong for your board,
especially a different keyboard entry in `aura_support.ron`, or amps that behave
differently across S4, please open an issue with the output of `./check.sh`.

Running this on different hardware entirely, a different ASUS board or
another brand, is also useful: `./check.sh` will mostly report `N/A`, and the
fingerprint it prints (board, codec, amp, keyboard) is exactly what's needed
to eventually extend `lib/hardware-detect.sh` to recognize your machine.
See **[ROADMAP.md](ROADMAP.md)** for the staged plan to get there.

One thing genuinely untested: **whether the TAS2781 amps survive a hibernate
(S4) resume.** They do not survive S3. Hibernate *may* differ, because resume is
a cold power-on with fresh kernel init. If yours come back dead, try
`HibernateMode=shutdown` before giving up, and please report it.

## License

MIT. These are config files and shell scripts; use them however you like.
