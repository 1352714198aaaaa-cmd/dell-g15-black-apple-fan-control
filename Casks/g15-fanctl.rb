# Homebrew Cask for the current GitHub release.
#
# The release asset is published as FanCtl-v<version>.zip. When a new tag is
# released, update `version` and `sha256` (shasum -a 256 FanCtl-v<version>.zip).
cask "g15-fanctl" do
  version "1.2.0"
  sha256 "30f0116ce5ad35f7db6e3fa454ec176822340c10c3e1b75ecc0881720a93f7d6"

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
