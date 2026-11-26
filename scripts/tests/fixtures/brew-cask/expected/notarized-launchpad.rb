# frozen_string_literal: true

cask "vphone-launchpad" do
  version "1.0.0"
  sha256 "a584e1b352cc659f2502133076d04686dd19c40a603d08a5a22ae1bb3f475c03"

  url "https://github.com/octo/vphone/releases/download/#{version}/vphone-launchpad-#{version}-notarized.zip"
  name "vphone-launchpad"
  desc "Launchpad for the vphone virtual iPhone"
  homepage "https://github.com/octo/vphone"

  livecheck do
    url :url
    strategy :github_releases do |json|
      json.filter_map do |release|
        next if release["draft"] || release["prerelease"]

        tag = release["tag_name"]
        names = release["assets"]&.map { |asset| asset["name"] } || []
        wanted = ["vphone-launchpad-#{tag}-notarized.zip", "vphone-skills-#{tag}.zip"]
        next unless (wanted - names).empty?

        tag
      end
    end
  end

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "vphone-launchpad.app"
  binary "#{appdir}/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli"

  uninstall quit: "com.vphone.launchpad"

  caveats <<~EOS
    Open Launchpad once to complete Host Setup, then run:
      vphone-launchpad-cli bundle install-release #{version}

    The vphone-guest-control agent skill is a separate, optional cask:
      brew install --cask acme/tap/vphone-skills
  EOS
end
