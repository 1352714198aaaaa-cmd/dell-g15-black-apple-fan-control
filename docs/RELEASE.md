# Release checklist

This is the release procedure for FanCtl. The asset naming is part of the
contract with the Homebrew Cask: every release must upload
`FanCtl-v<version>.zip`, and the Cask URL is built from that name.

Current state: **v2.1.0** is published and `Casks/g15-fanctl.rb` points at its
asset. Use this checklist as the template for the next version.

## 1. Preconditions

- CI is green on `main`.
- `app/Info.plist` has the release version (`CFBundleShortVersionString`).
- README, `docs/ARCHITECTURE.md` and `docs/EC-REGISTERS.md` are up to date.
- `Casks/g15-fanctl.rb` still points at the previous published release. Do not
  point it at a version whose asset does not exist.
- Release notes exist at `docs/RELEASE-NOTES-v<version>.md`.

## 2. Build and package

```bash
# Requires Xcode Command Line Tools and iasl (brew install acpica)
./kext/build.sh
./ssdt/build.sh
./app/build.sh

# Creates dist/FanCtl-v2.1.0.zip and dist/FanCtl-v2.1.0.zip.sha256
./scripts/package-release.sh 2.1.0
```

The packaging script refuses to run if the built app version does not match the
version argument, and fails if any of the four artifacts are missing.

## 3. Smoke test

```bash
unzip -l dist/FanCtl-v2.1.0.zip
shasum -a 256 -c dist/FanCtl-v2.1.0.zip.sha256

open app/FanCtl.app
```

Check:

- Left-click the menu bar icon: CPU/GPU temperature, fan 1/2 RPMs, full-speed
  toggle.
- Right-click: Open Control Panel / Show RPM in Menu Bar / Quit.
- Toggle full speed on and off: `kern.fanprobe.lastret` stays `0`; the EC mode
  goes `0xAB` then back to `0xA0`; the fan curve resumes.
- `fanctl diag` (if the CLI is installed) shows the kext and tach registers.

## 4. Tag and publish

```bash
git tag -a v2.1.0 -m "FanCtl v2.1.0"
git push origin v2.1.0
```

The `release.yml` workflow builds on `macos-15-intel` and creates a GitHub
Release with:

- `FanCtl-v2.1.0.zip`
- `FanCtl-v2.1.0.zip.sha256`

It uses the workflow's `GITHUB_TOKEN` with `contents: write`. If the workflow is
not available, create the release manually:

```bash
gh release create v2.1.0 \
  dist/FanCtl-v2.1.0.zip \
  dist/FanCtl-v2.1.0.zip.sha256 \
  --title "FanCtl v2.1.0" \
  --notes-file docs/RELEASE-NOTES-v2.1.0.md
```

Or use the GitHub web UI and upload both files.

## 5. Update the Cask

Only after the release asset exists:

```bash
./scripts/bump-cask.sh 2.1.0
git diff -- Casks/g15-fanctl.rb
```

The script downloads the published asset, computes its SHA-256, updates
`version` and `sha256`, and runs `ruby -c` on the Cask. Commit and push:

```bash
git add Casks/g15-fanctl.rb
git commit -m "chore(cask): update to 2.1.0"
git push origin main
```

Optional verification on a Mac with Homebrew:

```bash
brew audit --cask Casks/g15-fanctl.rb
brew install --cask ./Casks/g15-fanctl.rb
```

## 6. Post-release verification

- `https://github.com/1352714198aaaaa-cmd/dell-g15-black-apple-fan-control/releases/download/v2.1.0/FanCtl-v2.1.0.zip` returns 200.
- The Cask SHA-256 matches the downloaded asset.
- `brew install --cask g15-fanctl` succeeds and installs `FanCtl.app` + `fanctl`.
- The Cask caveats point at the staged `FanProbe.kext` and `SSDT-FANEC.aml`.
- The release notes mention the unsigned app / OpenCore kext requirement.

## 7. Rollback

If the asset is wrong before anyone installs it:

```bash
gh release delete v2.1.0 --yes
git push origin :refs/tags/v2.1.0
git tag -d v2.1.0
```

If the Cask was already bumped, revert the Cask commit or run
`./scripts/bump-cask.sh <previous-version>` after restoring the previous asset.
The Cask must never point at a missing asset.
