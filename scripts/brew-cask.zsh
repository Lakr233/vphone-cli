#!/bin/zsh
# Render the Homebrew casks for the newest of the given tags whose notarized
# Launchpad zip and skills zip are both attached, optionally committing and
# pushing them to a tap checkout. Uses only public release assets. Exits 3
# and writes nothing when no given tag has both.
set -euo pipefail

usage() {
  print -u2 -r -- "Usage: brew-cask.zsh <tag>... [--repo <owner/name>] [--tap <owner/name>] [--out <dir>] [--push <tap-checkout>]"
}
die() { print -u2 -r -- "brew-cask: $1"; exit ${2:-1}; }
usage_die() { print -u2 -r -- "brew-cask: $1"; usage; exit 2; }

repo_re='^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
tag_re='^[0-9]+\.[0-9]+\.[0-9]+$'

tags=() repo="${VPHONE_REPO:-Lakr233/vphone-cli}" tap="${TAP_REPO:-}" out=".build/brew" push=""
while (( $# )); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --repo|--tap|--out|--push)
      (( $# >= 2 )) || usage_die "$1 needs a value"
      case $1 in
        --repo) repo=$2 ;; --tap) tap=$2 ;; --out) out=$2 ;; --push) push=$2 ;;
      esac
      shift 2 ;;
    -*) usage_die "unknown option: $1" ;;
    *) [[ $1 =~ $tag_re ]] || usage_die "invalid tag: $1"; tags+=($1); shift ;;
  esac
done

# Homebrew names a tap owner/name for the repository owner/homebrew-name,
# in lowercase.
if [[ $tap == */* ]]; then
  tap=${(L)tap}
  tap="${tap%%/*}/${${tap#*/}#homebrew-}"
fi
(( $#tags )) || usage_die "a tag is required"
[[ -n $tap ]] || usage_die "--tap (or TAP_REPO) is required"
[[ $repo =~ $repo_re ]] || usage_die "invalid --repo: $repo"
[[ $tap =~ $repo_re ]] || usage_die "invalid --tap: $tap"
if [[ -n $push ]]; then
  [[ $(git -C "$push" rev-parse --is-inside-work-tree 2>/dev/null) == true ]] \
    || usage_die "--push is not a git work tree: $push"
  out=$push
fi

asset_base="${VPHONE_ASSET_BASE:-https://github.com/$repo/releases/download}"
work=$(mktemp -d "${TMPDIR:-/tmp}/brew-cask.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$work"' EXIT

# published <tag> <asset>: succeeds when the asset answers 200, fails when it
# answers 404, and exits on any other status.
published() {
  local code
  code=$(curl -sIL -o /dev/null -w '%{http_code}' "$asset_base/$1/$2") || die "probe failed: $2"
  case $code in
    200) return 0 ;;
    404) return 1 ;;
    *) die "unexpected HTTP $code for $2" ;;
  esac
}
# fetch <tag> <asset>: downloads it into $work and prints its sha256.
fetch() {
  curl -fsSL -o "$work/$2" "$asset_base/$1/$2" || die "download failed: $2"
  shasum -a 256 "$work/$2" | awk '{print $1}'
}
# newer <a> <b>: succeeds when version a sorts above version b.
newer() {
  local pair=($1 $2)
  [[ $1 != $2 && ${${(On)pair}[1]} == $1 ]]
}

tag=""
for t in ${(On)tags}; do
  if published $t "vphone-launchpad-$t-notarized.zip" && published $t "vphone-skills-$t.zip"; then
    tag=$t
    break
  fi
  print -u2 -r -- "brew-cask: skipping $t: the notarized Launchpad zip or the skills zip is not attached"
done
[[ -n $tag ]] || die "no release has both the notarized Launchpad zip and the skills zip" 3

if [[ -n $push && -f $push/Casks/vphone-launchpad.rb ]]; then
  current=$(sed -n 's/^  version "\(.*\)"$/\1/p' "$push/Casks/vphone-launchpad.rb")
  if [[ -n $current ]] && newer "$current" "$tag"; then
    print -r -- "brew-cask: the tap already has $current; not publishing $tag"
    exit 0
  fi
fi

launchpad_sha=$(fetch $tag "vphone-launchpad-$tag-notarized.zip")
skills_sha=$(fetch $tag "vphone-skills-$tag.zip")

ver='#{version}'
url_base="https://github.com/$repo/releases/download/$ver"

livecheck_block() {
  cat <<'EOF'
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
EOF
}

render_launchpad() {
  cat <<EOF
# frozen_string_literal: true

cask "vphone-launchpad" do
  version "$tag"
  sha256 "$launchpad_sha"

  url "$url_base/vphone-launchpad-$ver-notarized.zip"
  name "vphone-launchpad"
  desc "Launchpad for the vphone virtual iPhone"
  homepage "https://github.com/$repo"

$(livecheck_block)

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "vphone-launchpad.app"
  binary "#{appdir}/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli"

  uninstall quit: "com.vphone.launchpad"

  caveats <<~EOS
    Open Launchpad once to complete Host Setup, then run:
      vphone-launchpad-cli bundle install-release #{version}

    The vphone-guest-control agent skill is a separate, optional cask:
      brew install --cask $tap/vphone-skills
  EOS
end
EOF
}

render_skills() {
  cat <<EOF
# frozen_string_literal: true

cask "vphone-skills" do
  version "$tag"
  sha256 "$skills_sha"

  url "$url_base/vphone-skills-#{version}.zip"
  name "vphone-skills"
  desc "Agent skill for driving vphone"
  homepage "https://github.com/$repo"

$(livecheck_block)

  depends_on arch: :arm64
  depends_on macos: :sequoia

  binary "vphone-guest-control", target: "#{Dir.home}/.claude/skills/vphone-guest-control"
  binary "vphone-guest-control", target: "#{Dir.home}/.codex/skills/vphone-guest-control"
end
EOF
}

mkdir -p "$out/Casks" || die "cannot create $out/Casks"
render_launchpad > "$out/Casks/vphone-launchpad.rb" || die "write failed"
render_skills > "$out/Casks/vphone-skills.rb" || die "write failed"
print -r -- "$out/Casks/vphone-launchpad.rb"
print -r -- "$out/Casks/vphone-skills.rb"

if [[ -n $push ]]; then
  files=(Casks/vphone-launchpad.rb Casks/vphone-skills.rb)
  git -C "$push" add -- $files || die "git add failed"
  if ! git -C "$push" diff --cached --quiet -- $files; then
    git -C "$push" \
      -c user.name='github-actions[bot]' \
      -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
      commit -q -m "vphone $tag" -- $files || die "git commit failed"
    git -C "$push" push -q || die "git push failed"
  fi
fi
