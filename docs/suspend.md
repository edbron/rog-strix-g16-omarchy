# Suspend, hibernate, and why this machine sits warm

Three separate things had to be settled here:

1. Suspend **must** be s2idle, never S3: S3 kills the speakers.
2. s2idle on this platform doesn't actually save much power, and can't be made
   to. So it has to end in hibernation.
3. Hibernate resume fails outright until four NVIDIA units are enabled.

**Scope:** (1) applies to any laptop with a TAS2781 amp, gated on
`has_tas2781_amp`, not on ASUS or this board. (2) applies to any laptop
built on an Intel HX-class CPU (the "no S0ix" cause is the CPU die, not
the board), gated on `is_no_s0ix_cpu`; the exact ~2.65 W number below is
specific to this machine, the mechanism isn't. (3) applies to any NVIDIA
GPU, already vendor-level. See [hardware-detection.md](hardware-detection.md).

---

## 1. Force s2idle: never deep/S3

**Under `deep`/S3, resume leaves the TI TAS2781 speaker amps unpowered.** They
stop acknowledging on i2c entirely: every transfer returns `-121 EREMOTEIO`,
and nothing short of a cold boot brings them back.

Installed by `install.sh`:

- `/etc/tmpfiles.d/zz-s2idle.conf`: writes `s2idle` to `/sys/power/mem_sleep`.
- `SuspendState=freeze` in the sleep drop-in, which pins the suspend half by
  writing straight to `/sys/power/state`, so it cannot fall through to S3
  regardless of what `mem_sleep` holds. This belt-and-braces is deliberate.

### Settled: this is not fixable, don't re-litigate it

Tested properly and put to bed. The amps aren't resuming *out of order*, they're
resuming *unpowered*:

- Re-probing the HDA controller (`0000:00:1f.3`) from an
  `/etc/systemd/system-sleep/` hook, which runs after every device resume
  callback has completed, rebinds `tas2781-hda` cleanly and re-applies the
  mixer. The amps **still** return `-121` on every transfer.
- `i2cdetect -y -r 6` after a deep resume completes normally and finds nothing
  but the driver-claimed `0x39`. The controller is fine; the amps aren't
  answering.
- The `spd5118` DDR5 SPD sensors on the *separate* I801 SMBus fail in the same
  millisecond with `-6`. This is platform-wide i2c-after-S3 behaviour, not an
  audio driver bug.

> ### ☠ Never `unbind`/`bind` `0000:00:19.0` (intel-lpss)
>
> Tried once, to force a full LPSS re-init. The write to `bind` hangs in the
> kernel in uninterruptible D state, cannot be killed or timed out, and leaves
> **both** the I2C controller and the HDA card unbound, built-in audio gone
> entirely, recoverable only by reboot. It cost a working session.

s2idle isn't a workaround to be improved on. It's the answer. The extra suspend
drain is the price of working speakers.

### Clean up the contradictory kernel argument

The stock Omarchy cmdline may still carry `mem_sleep_default=deep`. The tmpfiles
rule overrides it, so it's harmless, but the two disagree, which will mislead
whoever reads the cmdline next. `check.sh` warns about it.

Remove it from your bootloader config (Omarchy defaults to limine,
`/boot/limine.conf`, or via `omarchy-cmdline-remove mem_sleep_default=deep` if
your version has it). **Not scripted here on purpose:** editing bootloader
config wrong leaves you unbootable, and this one is cosmetic.

---

## 2. suspend-then-hibernate

**The machine feels warm after a long suspend. That's real, and it's the
platform floor.** Instrumented over a 20-minute s2idle on battery, lid open,
nothing touched:

- **~2.65 W average draw** (`energy_now` 56690000 → 55805000 µWh over 1204 s)
- package temperature **fell** 50 °C → 47 °C during the sleep
- `LOC` 18093 wakeups / 1204 s / 32 CPUs = 0.47 per CPU per second, the CPUs
  are genuinely idle; there's no interrupt storm
- `/sys/power/suspend_stats/total_hw_sleep`: 0 → 0

**Raptor Lake-HX implements no S0ix at all.** `total_hw_sleep` never leaves 0
and both `low_power_idle_{cpu,system}_residency_us` read a constant 0. So s2idle
here only freezes the OS, no rails are cut, the package keeps drawing, and with
the fan stopped 2.65 W has nowhere to go but the chassis. **It is warm because
it is cooling slowly, not because something is running.**

There is no configuration that lowers this. The fix is to not stay there:

- `/etc/systemd/sleep.conf.d/10-suspend-then-hibernate.conf`: `SuspendState=freeze`,
  `HibernateDelaySec=30min`, `HibernateOnACPower=no` (plugged-in suspends stay in
  s2idle for a fast resume; the drain only matters on battery).
- `/etc/systemd/logind.conf.d/30-lid-suspend-then-hibernate.conf`: both
  `HandleLidSwitch` and `HandleLidSwitchExternalPower` set to
  `suspend-then-hibernate`. Because `HibernateOnACPower=no` handles the AC case,
  unplugging while already suspended still ends in hibernation.
- The Omarchy menu's *Suspend* entry is overridden to
  `systemctl suspend-then-hibernate` (it defaults to plain `systemctl suspend`).

### Don't blame the dGPU for the warmth

`/sys/bus/pci/devices/0000:01:00.0/power/runtime_status` reads `active` both
before and after a suspend, and that is **meaningless**, system suspend
bypasses runtime PM entirely, so the file never updates. It looks exactly like
"the GPU stayed awake all night" and it isn't: 2.65 W is nowhere near an awake
RTX 5060 (5–13 W), and the package wouldn't be cooling.

`NVreg_EnableS0ixPowerManagement` was considered and is **not** needed. Don't
set it on this evidence.

### Prerequisite: hibernation has to actually be provisioned

`suspend-then-hibernate` without working hibernation is a 30-minute countdown to
nothing. You need a swapfile larger than RAM and larger than
`/sys/power/image_size`, plus `resume=` and `resume_offset=` on the cmdline and
a `resume` hook in the initramfs. Omarchy provisions all of this, check with
`omarchy-hibernation-available` (exit 0 = good). `check.sh` and `install.sh`
both verify it.

---

## 3. Enable the NVIDIA sleep units: hibernate resume fails without them

On `nvidia-open-dkms` 610, hibernation writes its image fine but **resume dies
at the last step** unless all four units are enabled. **Arch ships them all
disabled.**

```sh
sudo systemctl enable nvidia-suspend nvidia-hibernate nvidia-resume nvidia-suspend-then-hibernate
```

The signature in `journalctl -b 0`:

```
NVRM: GPU 0000:01:00.0: PreserveVideoMemoryAllocations module parameter is set.
      System Power Management attempted without driver procfs suspend interface.
nvidia 0000:01:00.0: PM: pci_pm_freeze(): nv_pmops_freeze [nvidia] returns -5
PM: hibernation: Failed to load image, recovering.
PM: hibernation: resume failed (-5)
```

**Why:** driver 610 defaults `NVreg_PreserveVideoMemoryAllocations=1`, so the
driver refuses any freeze/thaw that didn't arrive via a write to
`/proc/driver/nvidia/suspend`. Only `nvidia-sleep.sh`, run by those units,
does that write. The parameter isn't exposed under
`/sys/module/nvidia/parameters/` in this driver, so its absence there proves
nothing; read the kernel log instead.

**Re-check after any nvidia package reinstall or a fresh install.** `check.sh`
covers it.

Expect a brief black-screen flicker on the way into hibernate, `nvidia-sleep.sh`
does `chvt 63` and back.

---

## Open question

**Do the TAS2781 amps survive an S4 resume?** Untested. Hibernate cuts platform
power the way S3 does, and S3 resume leaves them unpowered. Hibernate *may*
differ, because resume is a cold power-on plus fresh kernel init before the
image loads.

If your speakers come back dead after a hibernate resume, try
`HibernateMode=shutdown` in the sleep drop-in before giving up, and please open
an issue. If that fails too, `./uninstall.sh` or just delete the two systemd
drop-ins.

---

## A note on lid-close locking

The stock Omarchy `omarchy-sleep-lock.service` holds a *delay inhibitor* so the
session locks before suspending. A delay inhibitor is a timer, not a promise:
logind suspends anyway once the window expires, locked or not. The default 5 s
isn't enough when closing the lid also reconfigures displays, because Quickshell
waits for the screen set to settle before it can secure.

If you hit that, raise it:

```ini
# /etc/systemd/logind.conf.d/…
[Login]
InhibitDelayMaxSec=15
```

This costs nothing when locking works, a healthy lock releases the inhibitor in
well under a second.
