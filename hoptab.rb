cask "hoptab" do
  version "1.2.0"
  sha256 "c2829f2e06412d3315c852edb629a9045da341788b260aee604f53b067cc150a"

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
