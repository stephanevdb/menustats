cask "menustats" do
  version "1.0.2"
  sha256 "776440375a27eb938ac0eb0fed1590aff2df895ce73fc8320ddda036c713c554"

  url "https://github.com/stephanevdb/menustats/releases/download/v#{version}/MenuStats-#{version}.zip"
  name "MenuStats"
  desc "Compact system stats in the menu bar"
  homepage "https://github.com/stephanevdb/menustats"

  depends_on macos: :sonoma

  app "MenuStats.app"

  # The app is self-signed rather than notarized, so clear the download quarantine
  # or Gatekeeper refuses to open it.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/MenuStats.app"]
  end

  uninstall quit: "com.stephanevdb.MenuStats"

  zap trash: "~/Library/Preferences/com.stephanevdb.MenuStats.plist"
end
