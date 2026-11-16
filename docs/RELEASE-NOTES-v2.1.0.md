# FanCtl v2.1.0

The first binary release since v1.2.0. It includes the v2.0 documentation,
Homebrew Cask, and the new compact menu bar panel.

## Highlights

- **Menu bar popover**: left-click the status item for CPU/GPU temperature, both
  fan RPMs, and the full-speed switch. Right-click keeps the existing menu.
- **Full-speed mode**: the switch writes G-Mode (`0xAB`), remembers the previous
  curve or manual state, and restores it when switched off. Any curve/manual
  action exits G-Mode first.
- **State-aware launch**: if the EC is already in G-Mode, the app starts with the
  full-speed switch on and does not overwrite it with the curve.
- **Homebrew Cask**: `Casks/g15-fanctl.rb` installs `FanCtl.app` and the
  `fanctl` CLI; the kext/SSDT still go through OpenCore.
- **Documentation**: architecture, sysctl ABI, EC register table, verification
  experiments, and launchd examples.
- **CI**: builds on `macos-15-intel` (the `macos-13` image was retired), checks
  the Cask/launchd syntax, and packages the app, kext and SSDT.

## Install

```bash
# Homebrew: app + CLI
brew tap 1352714198aaaaa-cmd/dell-g15-black-apple-fan-control https://github.com/1352714198aaaaa-cmd/dell-g15-black-apple-fan-control
brew install --cask g15-fanctl
```

Then install `FanProbe.kext` and `SSDT-FANEC.aml` through OpenCore, reboot, and
run `fanctl diag`. See the README for the full manual steps.

The app is unsigned and not notarized; the Cask caveats explain the Gatekeeper
workaround. The kext is Intel-only and this release is tested only on the Dell
G15 5511.

## Compatibility

- Dell G15 5511 (i7-11800H + RTX 3060 Laptop), macOS 26 on OpenCore.
- Intel `x86_64` only.
- The ACPI/EC interface is model-specific and reverse-engineered.

## Checksums

The release includes `FanCtl-v2.1.0.zip.sha256`. Verify with:

```bash
shasum -a 256 -c FanCtl-v2.1.0.zip.sha256
```
