# FanCtl v2.1.1

A small bug-fix release for the menu bar panel.

## Fix

- **First click now opens the panel.** macOS can swallow the first click on a
  status item belonging to an inactive accessory app: the click activates the
  app but does not fire the status item action, so the popover never appeared.
  FanCtl now watches the status item window with a local event monitor and
  toggles the panel on the first mouse-down.
- **Right-click still opens the menu** (Open Control Panel, Show RPM in Menu
  Bar, Quit); the app is activated first so the menu is usable from an inactive
  state.
- No changes to the fan control, kext, SSDT or Cask layout.

## Install

```bash
brew tap 1352714198aaaaa-cmd/dell-g15-black-apple-fan-control https://github.com/1352714198aaaaa-cmd/dell-g15-black-apple-fan-control
brew install --cask g15-fanctl
```

Or download `FanCtl-v2.1.1.zip` from the release assets. The app is unsigned;
the Cask caveats explain the Gatekeeper workaround and the kext/SSDT steps.

## Compatibility

- Dell G15 5511 (i7-11800H + RTX 3060 Laptop), macOS 26 on OpenCore.
- Intel `x86_64` only.

## Checksums

The release includes `FanCtl-v2.1.1.zip.sha256`. Verify with:

```bash
shasum -a 256 -c FanCtl-v2.1.1.zip.sha256
```
