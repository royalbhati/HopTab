# Mirror of the published cask at royalbhati/homebrew-tap (Casks/hoptab.rb).
# scripts/release.sh rewrites the `version` and `sha256` lines in the tap after
# each release; keep this copy in sync so the repo does not drift from the tap.
cask "hoptab" do
  version "1.5.0"
  sha256 "2a7e66ebb42c621a46869dacf87698968583850bd6e84b7aeeb22f9a2dc57596"

  url "https://github.com/royalbhati/HopTab/releases/download/v#{version}/HopTab-#{version}.zip"
  name "HopTab"
  desc "The workspace manager macOS should have shipped with"
  homepage "https://github.com/royalbhati/HopTab"

  livecheck do
    url :url
    strategy :github_latest
  end

  # HopTab checks for updates and points you at the release, but it does not
  # replace itself in place — Homebrew stays the upgrade path.
  auto_updates false
  depends_on macos: ">= :sonoma"

  app "HopTab.app"

  zap trash: [
    "~/Library/Caches/com.hoptab.app",
    "~/Library/Preferences/com.hoptab.app.plist",
    "~/Library/Application Support/HopTab",
  ]
end
