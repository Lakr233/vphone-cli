#!/bin/zsh
# Tests for scripts/brew-cask.zsh against fixture assets served locally.
set -euo pipefail
tests=${0:a:h}
root=${tests:h:h}
script="$root/scripts/brew-cask.zsh"
fx="$tests/fixtures/brew-cask"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/brew-cask-tests.XXXXXX")
server_pid=""
cleanup() {
  [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() { print -u2 -r -- "FAIL: $1"; exit 1; }

# Fixture server: brew-cask-server.swift serves the assets (200/404) and
# answers 503 for vphone-launchpad-1.0.3-notarized.zip.
swiftc -O -o "$tmp/server" "$tests/brew-cask-server.swift" || fail "cannot build the fixture server"
"$tmp/server" "$fx/assets" "$tmp/port" &
server_pid=$!
for _ in {1..50}; do [[ -s $tmp/port ]] && break; sleep 0.1; done
[[ -s $tmp/port ]] || fail "fixture server did not start"
export VPHONE_ASSET_BASE="http://127.0.0.1:$(<"$tmp/port")"
unset TAP_REPO VPHONE_REPO

render() { zsh "$script" "$@" --repo octo/vphone; }
run() { render "$@" --tap acme/tap; }
# none <name> <expected exit> <args...>: the run exits with that code and
# writes nothing.
none() {
  local name=$1 want=$2 out="$tmp/$1" rc=0
  shift 2
  run "$@" --out "$out" > "$tmp/$name.stdout" 2> /dev/null || rc=$?
  [[ $rc -eq $want ]] || fail "$name: exit $rc, expected $want"
  [[ ! -s $tmp/$name.stdout && ! -e $out/Casks ]] || fail "$name: left output"
}
same() {
  diff "$fx/expected/notarized-launchpad.rb" "$1/Casks/vphone-launchpad.rb" || fail "$2: launchpad cask differs"
  diff "$fx/expected/skills-1.0.0.rb" "$1/Casks/vphone-skills.rb" || fail "$2: skills cask differs"
}

# 1. Both casks match the fixtures.
run 1.0.0 --out "$tmp/o1" > /dev/null || fail "render 1.0.0"
same "$tmp/o1" "1.0.0"

# 2. An unsigned newer release does not hide the signed older one.
run 1.0.0 1.0.1 --out "$tmp/o2" > /dev/null 2>&1 || fail "render 1.0.0 1.0.1"
same "$tmp/o2" "1.0.0 1.0.1"

# 3. The highest publishable tag wins, compared as numbers, in any order.
for order in "1.0.9 1.0.10" "1.0.10 1.0.9"; do
  run ${=order} --out "$tmp/o3" > /dev/null || fail "render $order"
  grep -q '^  version "1.0.10"$' "$tmp/o3/Casks/vphone-launchpad.rb" || fail "$order: did not pick 1.0.10"
done

# 4. A release with only the unsigned zip is not published: exit 3.
none unsigned 3 1.0.1

# 5. A release without the skills zip is not published: exit 3.
none no-skills 3 1.0.2

# 6. A 5xx is not treated as absent.
none server-error 1 1.0.3

# 7. A tag carrying extra words is a usage error, not options.
none hostile-tag 2 '1.0.0 --repo evil/repo'

# 8. --tap and TAP_REPO are both lowercased and lose homebrew-; a tap
#    without a slash is a usage error.
render 1.0.0 --tap Acme/Homebrew-Tap --out "$tmp/o6a" > /dev/null || fail "render --tap Acme/Homebrew-Tap"
TAP_REPO=Acme/homebrew-tap render 1.0.0 --out "$tmp/o6b" > /dev/null || fail "render TAP_REPO=Acme/homebrew-tap"
same "$tmp/o6a" "--tap Acme/Homebrew-Tap"
same "$tmp/o6b" "TAP_REPO=Acme/homebrew-tap"
rc=0
render 1.0.0 --tap noslash --out "$tmp/o6c" > "$tmp/o6c.stdout" 2> /dev/null || rc=$?
[[ $rc -eq 2 && ! -s $tmp/o6c.stdout && ! -e $tmp/o6c/Casks ]] || fail "--tap noslash: exit $rc, expected 2 and no output"

# 9. A second identical --push makes no commit and no push, with no git
#    identity configured. The second run's remote does not exist, so any push
#    would fail.
export HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME"
git init -q --bare -b main "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/tap" 2> /dev/null
git -C "$tmp/tap" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$tmp/tap" push -q origin HEAD:main
run 1.0.0 --push "$tmp/tap" > /dev/null || fail "first --push"
[[ $(git -C "$tmp/remote.git" log -1 --format=%s main) == "vphone 1.0.0" ]] || fail "push subject"
first=$(git -C "$tmp/tap" rev-parse HEAD)
git -C "$tmp/tap" remote set-url origin "$tmp/missing.git"
run 1.0.0 --push "$tmp/tap" > /dev/null 2>&1 || fail "second --push pushed or failed"
[[ $(git -C "$tmp/tap" rev-parse HEAD) == $first ]] || fail "second --push committed"

# 10. A tap with a newer version is not downgraded, compared as numbers.
sed -i '' 's/^  version "1.0.0"$/  version "1.0.10"/' "$tmp/tap/Casks/vphone-launchpad.rb"
git -C "$tmp/tap" -c user.name=t -c user.email=t@example.com commit -q -am "vphone 1.0.10"
newer=$(git -C "$tmp/tap" rev-parse HEAD)
run 1.0.9 --push "$tmp/tap" > /dev/null || fail "downgrade run failed"
[[ $(git -C "$tmp/tap" rev-parse HEAD) == $newer ]] || fail "downgrade committed"
grep -q '^  version "1.0.10"$' "$tmp/tap/Casks/vphone-launchpad.rb" || fail "downgrade rewrote the cask"

print "brew-cask: ten cases passed"
