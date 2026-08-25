# Audio: ALC294 + TAS2781

Realtek ALC294 with two TI TAS2781 smart amps, SSID `1043:1204`.

This one took the longest, went down the most dead ends, and had two separate
false conclusions along the way. Both are documented below, because the wrong
answers here are *convincing*.

**Short version:** don't pin the mixer by hand. Remove the `soft-mixer`
drop-in, keep the codec powered, and let PipeWire own the hardware mixer.

**Scope:** the soft-mixer fix below is an ACP/PipeWire config problem, not
specific to this codec, `install.sh` applies it on any hardware since it
only acts if a matching drop-in exists. The power_save and idle-suspend
fixes exist to protect the TAS2781 amps specifically, and apply to any
laptop with that amp, ASUS or not, gated on `has_tas2781_amp` rather than
on this exact codec. Only the codec-cache diagnostic near the end needs
ALC294's exact DAC node addresses and stays specific to that. See
[hardware-detection.md](hardware-detection.md).

---

## The root cause: `api.alsa.soft-mixer`

Many Realtek "muffled audio" recipes tell you to set
`api.alsa.soft-mixer = true` in a WirePlumber drop-in. Omarchy ships something
along these lines. **On this machine it is the bug.**

PipeWire's ACP (alsa-card-profile) does its own jack-based port switching, and
its path files *do* write ALSA controls, in
`/usr/share/alsa-card-profile/mixer/paths/`:

- `analog-output-speaker.conf` sets `[Element Auto-Mute Mode] → Option Disabled`
  (ACP disables the kernel auto-mute on purpose, since it switches ports itself)
  and `[Element Headphone] switch = off`.
- `analog-output-headphones.conf` sets `[Element Speaker] switch = off,
  volume = off`.

With `soft-mixer` on, ACP still applies those **downward** writes on every port
selection, but `volume = merge` on the newly-active path is suppressed. So
PipeWire turns the hardware gains **down and never back up**.

A one-way ratchet to silence, re-armed on every headphone plug/unplug and every
port re-selection. That's why it kept coming back.

**Fix:** rename the drop-in out of the way. `install.sh` does this for any
drop-in in `~/.config/wireplumber/wireplumber.conf.d/` that mentions
`api.alsa.soft-mixer`, renaming it to `.disabled-<epoch>` rather than deleting.

Verified afterwards: the speaker DAC (node `0x03`) tracks the `wpctl` slider,
0.30 → `0x2e`, 0.60 → `0x46`, 1.00 → `0x57`. Self-healing. No manual pinning.

```sh
pactl list sinks | grep soft-mixer      # should print nothing
```

### Auto-Mute Mode reading `Disabled` is now CORRECT

ACP sets it deliberately because it handles port switching itself. **Do not
"fix" it back to Enabled.** A login script that forces `Auto-Mute Enabled` and
unmutes both paths actively fights ACP, that's the opposite of what it wants.
If you have such a unit (e.g. `omarchy-fix-alsa-gain.service`), disable it.
`install.sh` does.

---

## Keep the codec powered

Two settings, both needed:

**`/etc/modprobe.d/90-snd-hda-no-powersave.conf`**

```
options snd_hda_intel power_save=0 power_save_controller=N
```

The codec was dropping to D3 after one second of silence, cycling power to amps
that are already fragile across PM transitions.

**`~/.config/wireplumber/wireplumber.conf.d/50-no-suspend-builtin-audio.conf`**

WirePlumber otherwise closes an idle node after 5 s, which lets the codec drop
regardless of the module parameter. The rule sets
`session.suspend-timeout-seconds = 0`, scoped by node name to the built-in card
so **HDMI and Bluetooth sinks still suspend normally**, that matters, because
the dGPU audio function needs to reach D3 for the GPU to sleep.

(In `suspend-node.lua` a timeout of 0 hits an explicit `return`, so 0 really
does mean never.)

Verify:

```sh
pactl list sinks short    # the analog sink sits at IDLE, never SUSPENDED,
                          # more than 5 s after playback
cat /sys/bus/hdaudio/devices/hdaudioC0D0/power/control   # -> on
```

### ⚠ When a module parameter disagrees with `modprobe -c`, look for a late writer

This cost a full debugging session. `power_save` read **1** at runtime while
`modprobe -c` correctly resolved to 0. Nothing in modprobe.d, udev, tlp or PPD
set it.

The culprit was `/usr/local/bin/omarchy-powersave-tune`, a hand-written,
unpackaged script run by `omarchy-powersave.service` with
`After=multi-user.target`. It did `echo 1 > /sys/module/snd_hda_intel/parameters/power_save`.
Because it runs long *after* modprobe, it silently overrode the modprobe.d file
on every boot.

The tell was `power_save_controller=N` (a non-default value, so modprobe.d *had*
applied) sitting right next to `power_save=1`, plus the parameter file's mtime
landing ~2 s after module load.

`check.sh` flags the mismatch; `install.sh` warns if that script still has an
uncommented `power_save` line. Comment it out by hand (keep a `.bak`).

**Generalise it:** check `/usr/local/bin` and custom units before concluding
nothing set a module parameter.

---

## Residual risk, not yet observed

`power_save=0` is a **global** module parameter. If the NVIDIA HDMI codec
(`hdaudioC1D0`) is ever woken, it may be forbidden from re-suspending and could
hold `0000:01:00.1`, and with it D3cold on the dGPU, costing the idle-power
win from [bios.md](bios.md). It reads `auto`/`suspended` today.

**Before blaming audio config for a dGPU that won't sleep, run
`fuser -v /dev/nvidia*`.** Hyprland and a Firefox RDD process were once holding
`/dev/nvidia0`, which looks identical from the PCI sysfs side.

---

## Diagnosing silence: check this FIRST

**The ALSA control cache can desync from the codec's real amp registers.** This
is the failure mode to check before anything else, because *every other check
passes while it's happening*:

- `Master` / `Speaker` / `Headphone` all read 87 [100%] and `on`
- sink is `IDLE`, not `SUSPENDED`
- `power_save=0`
- `asound.state` holds good values
- no i2c `-121`
- …and there is total silence from both speakers **and** headphones.

The truth is only visible in `/proc/asound/card0/codec#0`:

```sh
sed -n '/^Node 0x02 /,/^Node 0x04 /p' /proc/asound/card0/codec#0 | grep 'Amp-Out vals'
```

- Node `0x02` carries `Headphone Playback Volume`, node `0x03` carries
  `Speaker Playback Volume`. The pin widgets `0x17`/`0x21` are mute-only
  (`nsteps=0x00`).
- Max is `0x57`. **`[0x00 0x00]` is −65.25 dB, i.e. silence.**

Also check `Pin-ctls` to see which path auto-mute selected: `0x17` (speaker,
`0x40` = live, `0x00` = off) and `0x21` (headphone, `0xc0` = live).

> Silence on **both** speakers and headphones rules out the TAS2781 amps
> entirely, headphones don't pass through them. Look for a common-mode fault at
> the codec instead.

### Why re-running a fix script doesn't help

The HDA driver **caches amp values and skips the verb when the new value equals
the cached one.** `amixer sset Speaker 100% unmute` against a control already
reporting 87 is a no-op, so the stranded `0x00` in hardware is never
overwritten.

Nudge through a different value first to force a real write:

```sh
amixer -c 0 sset Speaker 50%
amixer -c 0 sset Speaker 100%
# verified: 0x00 -> 0x2c -> 0x57
```

The same staleness applies to `Auto-Mute Mode`, writing the value it already
holds may not re-run the driver's automute evaluation, leaving both the speaker
and headphone pins live at once. Toggle Disabled → Enabled rather than
re-writing the current value.

---

## Dead ends, so you can skip them

**The TAS2781 side is a red herring.** DSP firmware (`TAS2XXX12040/12041.bin`)
loads fine and `Speaker Analog Volume` sits at max 20/20. Only one of the three
instantiated `tas2781-hda` I2C devices binds to the codec, which looks alarming
and is unrelated to volume.

**`sudo alsactl store 0` is not a fix, it actively regresses.** After a reboot
the speakers were silent again with `/var/lib/alsa/asound.state` itself holding
`Speaker Playback Volume 0` / `Switch false`. The state file's mtime was 22 s
*before* that boot: `alsa-store` saves the mixer at shutdown **after** the
controls have already been reset, and `alsa-restore` replays those zeros at
boot. A self-perpetuating mute.

**`Master Playback Volume` (numid=15) is an ALSA vmaster** slaving Headphone and
Speaker, confirmed because DAC node `0x03`'s `Amp-Out vals` tracked the vmaster
value (`0x3c` = 60), not the slave's 87. It attenuates speakers and headphones
alike.

**`speaker-test` spends ~5 s per channel.** A short `timeout` truncates it
mid-left-channel and fakes a very convincing "only one side works" symptom.

**Don't infer hardware state from PipeWire.** `pactl` advertises
`Flags: HARDWARE DECIBEL_VOLUME` on this card while applying volume in software.
For any level problem, dump `amixer -c 0 contents` and read the gain stages,
then confirm against the codec node dump above, since even `amixer` reads the
cache.

---

## Reverting

`./uninstall.sh` removes the modprobe and WirePlumber files. To bring back a
disabled soft-mixer drop-in, rename `alsa-soft-mixer.conf.disabled-*` back and
`systemctl --user restart wireplumber`.
