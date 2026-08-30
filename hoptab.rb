cask "hoptab" do
  version "1.4.0"
  sha256 "b03651533efa10f515eedc3e4a9fe5bb77d8529f371201a5c650d632dbb2a00a"

  url "https://github.com/royalbhati/HopTab/releases/download/v#{version}/HopTab-#{version}.zip"
  name "HopTab"
  desc "The workspace manager macOS should have shipped with"
  homepage "https://github.com/royalbhati/HopTab"

  depends_on macos: ">= :sonoma"

  app "HopTab.app"

  zap trash: [
    "~/Library/Preferences/com.hoptab.app.plist",
    "~/Library/Application Support/HopTab",
  ]
end
