cask "menustats" do
  version "1.0.0"
  sha256 "70d599f8e93db8dd32f19c75d6d29e2c74af08ef9874933fe9b76ce048f080ca"

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
