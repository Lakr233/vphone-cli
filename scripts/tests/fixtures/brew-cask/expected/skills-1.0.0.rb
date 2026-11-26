# frozen_string_literal: true

cask "vphone-skills" do
  version "1.0.0"
  sha256 "789b43df20985e0482617d006883019a212f9c21adbe6d2c2ec1cbe13ad184d7"

  url "https://github.com/octo/vphone/releases/download/#{version}/vphone-skills-#{version}.zip"
  name "vphone-skills"
  desc "Agent skill for driving vphone"
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

  binary "vphone-guest-control", target: "#{Dir.home}/.claude/skills/vphone-guest-control"
  binary "vphone-guest-control", target: "#{Dir.home}/.codex/skills/vphone-guest-control"
end
