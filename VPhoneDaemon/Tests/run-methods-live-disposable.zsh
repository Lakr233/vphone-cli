#!/bin/zsh
set -euo pipefail

# Builds the bundle, creates a throw-away VM from nothing but the build's own options (no existing VM is read or
# touched), runs run-methods-live.zsh against it (its launch installs the freshly built vphoned), then deletes the VM.
#   zsh VPhoneDaemon/Tests/run-methods-live-disposable.zsh
# `vm create` clones the VM from the template matching this build and iOS version. The first run for a build that
# changes the template key (a new boot-chain patch, bundle series or slimming) builds the template from the
# cached or downloaded IPSWs: about 5 minutes, ~18 GB, and root for `cfw install`. Later runs clone it in about a
# second. The template is kept as a cache between runs (`vm template list`); delete it with `vm template delete`.
# Environment:
#   VPHONE_BUNDLE          use this VPhone.bundle and do not build
#   VPHONE_SKIP_BUILD=1    use the existing .build bundle instead of building
#   VPHONE_IPHONE_VERSION  guest iOS version for the VM (default 27.0.1); the cloudOS defaults to the recommended one
#   VPHONE_KEEP_VM=1       keep the VM after the run (its name is printed)
# Only the VM this run created is ever stopped or deleted.
# The AMFI allowlist step is not run here: when host preflight fails, the sudo command to run is printed (exit 2).
# Exit: the exit code of run-methods-live.zsh (0 pass, 1 failure, 2 unavailable), or 2 for a setup problem here.

root=${0:a:h:h:h}
version=${VPHONE_IPHONE_VERSION:-27.0.1}

if [ -n "${VPHONE_BUNDLE-}" ]; then
  bundle=$VPHONE_BUNDLE
elif [ -n "${VPHONE_SKIP_BUILD-}" ]; then
  bundle=$root/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle
else
  bundle=$(zsh "$root/scripts/build-bundle.zsh")
fi
cli=$bundle/Contents/MacOS/vphone-cli
[ -x "$cli" ] || { print -u2 "no built bundle at $bundle"; exit 2; }
"$cli" host preflight > /dev/null 2>&1 || {
  print -u2 "preflight failed; operator must run: sudo $bundle/Contents/MacOS/vphone-escalator allow $bundle/Contents/MacOS/vphone-vm"
  exit 2
}

vm=live-$$
created=0
cleanup() {
  if [ $created = 1 ] && [ -z "${VPHONE_KEEP_VM-}" ]; then
    "$cli" vm stop "$vm" > /dev/null 2>&1 || true
    "$cli" vm delete "$vm" --force > /dev/null 2>&1 || print -u2 "could not delete $vm; remove it with: $cli vm delete $vm --force"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --skip-first-boot: run-methods-live.zsh boots the VM itself and waits for the new vphoned.
created=1
createlog=$root/.build/methods-create.log
if ! "$cli" vm create "$vm" --iphone-version "$version" --skip-first-boot 2>&1 | tee "$createlog"; then
  if grep -q 'needs root' "$createlog"; then
    created=0
    print -u2 "no template for this build yet; operator must build it once (kept as a cache), then rerun and delete the seed VM:"
    print -u2 "  sudo -E $cli vm create live-seed --iphone-version $version --skip-first-boot"
    print -u2 "  $cli vm delete live-seed --force"
  fi
  print -u2 "vm create failed"
  exit 2
fi
print -r -- "vm=$vm"
code=0
VPHONE_BUNDLE=$bundle VPHONE_VM=$vm zsh "$root/VPhoneDaemon/Tests/run-methods-live.zsh" || code=$?
[ -n "${VPHONE_KEEP_VM-}" ] && print -r -- "kept vm $vm"
exit $code
