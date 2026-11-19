cask "menustats" do
  version "1.0.3"
  sha256 "6d2dcd6485eb211df827dbb9be024a4e2b966c37c88ef633f751f353a24281c1"

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
