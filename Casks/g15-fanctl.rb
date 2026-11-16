# Homebrew Cask for the current GitHub release.
#
# The release asset is published as FanCtl-v<version>.zip. After a release,
# run ./scripts/bump-cask.sh <version> to update `version`, `sha256` and verify
# the download URL.
cask "g15-fanctl" do
  version "2.1.0"
  sha256 "5c768195874bd7472e5300be381789c95a1d50d4a08e125f38a570a61f4a1fb5"

  url "https://github.com/1352714198aaaaa-cmd/dell-g15-black-apple-fan-control/releases/download/v#{version}/FanCtl-v#{version}.zip",
      verified: "github.com/1352714198aaaaa-cmd/dell-g15-black-apple-fan-control/"
  name "G15 FanCtl"
  desc "Fan control for Dell G15 laptops running macOS"
  homepage "https://github.com/1352714198aaaaa-cmd/dell-g15-black-apple-fan-control"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe
  depends_on arch: :x86_64

  app "FanCtl.app"
  binary "fanctl"

  caveats <<~EOS
    The FanCtl app is unsigned and not notarized. If macOS blocks the first
    launch, right-click the app and choose Open, or remove the quarantine flag:
      xattr -dr com.apple.quarantine "/Applications/FanCtl.app"

    Fan control also requires FanProbe.kext and SSDT-FANEC.aml. This Cask does
    not install them into your OpenCore EFI. Copies from the release are kept at:
      #{staged_path}/FanProbe.kext
      #{staged_path}/SSDT-FANEC.aml

    Add them to EFI/OC/Kexts and EFI/OC/ACPI, declare them in config.plist, and
    reboot. Without the kext, fanctl and FanCtl cannot read or set fan speeds.

    If you previously installed fanctl by hand in /usr/local/bin, remove that
    copy before installing this Cask to avoid a link conflict.
  EOS
end
