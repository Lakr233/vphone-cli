# Installing vphone

Read `status` first (`vphone-launchpad-cli status`) and skip every step it
already shows as done. Steps 1 and 2 happen once per Mac, by the Mac's owner.

## Contents

- Host requirements
- Launchpad
- The CLI on PATH
- VPhone.bundle and series matching
- Testing a local build
- When an install step fails
- Checking the result

## Host requirements

- Apple Silicon, macOS 15 or newer. It does not run inside another VM, because
  the guests need nested-free paravirtualization.
- The entitled `vphone-vm` must be admitted by AMFI. The owner chooses one of
  two host configurations in macOS Recovery (SIP off with
  `amfi_get_out_of_my_way=1`, or SIP on `--without debug` plus an allowlist),
  and both need `csrutil allow-research-guests enable`. The details are in
  `Documents/en/get-started/host-setup.md` of the repository.
- Launchpad's Host Setup page checks these, the network (`updates.cdn-apple.com`,
  `api.github.com`), Developer Tools access and the root helper. When the
  allowlist is the only thing missing, Launchpad applies it for you through its
  helper, per bundle signature.

Do not change SIP, boot-args or nvram yourself. They need a reboot into
Recovery and are the owner's call. Say which check failed and stop.

## Launchpad

1. Open <https://github.com/Lakr233/vphone-cli/releases>.
2. Download `vphone-launchpad-<version>-notarized.zip`. Use the plain
   `vphone-launchpad-<version>.zip` only when the release has no notarized one;
   macOS blocks it the first time, and the user must open System Settings >
   Privacy & Security and click **Open Anyway**.
3. Unzip and move the app to `/Applications`. Launchpad does not update itself:
   to update, download the new version and replace the app.
4. Open it once. On first launch the user completes Host Setup: allow
   Developer Tools access, and install the helper (it asks for an administrator
   password). Developer Tools access takes effect as soon as the switch is on;
   Launchpad checks it again when it comes to the front, without a relaunch.
   `canInstallBundles` in `status` turns `true` when both are done.

Which versions are notarized is listed in `Documents/en/get-started/downloads.md`.

## The CLI on PATH

```sh
mkdir -p ~/.local/bin
ln -sf /Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli ~/.local/bin/
vphone-launchpad-cli help
```

Do not use `sudo` for this; `~/.local/bin` must be on PATH, and calling the CLI by its full path works the same. The CLI starts Launchpad in the
background if it is not running and waits for the control socket
(`~/Library/Application Support/vphone-launchpad/control.sock`, mode 0600,
same user only). Nothing listens on the network; reach it over ssh from another
machine.

## VPhone.bundle and series matching

Launchpad and the bundle must share a **series**: the first two numbers of the
version. Launchpad 2.2.3 works with any 2.2.x bundle, and the reverse. Patch
releases inside a series stay interchangeable, so take the newest in the series.
Launchpad refuses a bundle that is too old, but it may still list bundles from a
newer series; do not install those, update Launchpad first.

```sh
vphone-launchpad-cli bundle install-release 2.2.3           # an explicit X.Y.z of Launchpad's series
vphone-launchpad-cli bundle list
vphone-launchpad-cli bundle set-default 2.2.3            # what new machines get
vphone-launchpad-cli bundle verify 2.2.3                 # re-check
```

`install-release` downloads the release from GitHub, verifies it, installs it
into the root-owned store through the helper, makes it the default (unless
`--keep-default`), and runs host preflight. Existing machines keep the bundle
they are bound to; see [machines](machines.md#core-bundle-of-a-machine).
`bundle list` shows per version: `default`, `machines` (bound to it),
`accepted`, `policy`, `preflight`, `preflightDetail`, `cdhashes`, `path`.

Always pass an explicit version. `latest` means the newest release by publish
date, prereleases included, and it is installed and made the default at once,
so it can land in a newer series than Launchpad. Read Launchpad's version with
`/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/vphone-launchpad.app/Contents/Info.plist`
(`status` does not report it), then pick the newest non-prerelease `X.Y.z` of the
same `X.Y` from `gh release list -R Lakr233/vphone-cli` or the releases page.

`bundle accept <version>` uses a version although its checks failed and
`--off` takes that back. `bundle remove <version>` deletes one, and refuses
while a machine is bound to it. Neither is for routine use; ask first.

The first step that needs the helper after its five-minute authorization
expires asks the user for an administrator password on the Mac. Warn them
before running one, and do not retry in a loop while a prompt is open.

## Testing a local build

From a source checkout:

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build

vphone-launchpad-cli bundle install-local .build/XcodeBundle/Build/Products/Debug/VPhone.bundle
```

`install-local` takes a folder or a `.zip`, installs it as
`<version>-local.<hash>` (from the code-signature seal, so each build is its own
version), makes it the default unless `--keep-default`, adds the execution
policy exception, allows the new `vphone-vm` cdhash and runs preflight. Relative
paths are resolved by the CLI. Installing does not move existing machines: bind
one with `vm set-bundle <name> <version> --update-environment`, or create one
with `vm create <name> --bundle <version>`. Each rebuild installs as a new
version; remove old ones no machine uses. To compare two builds, see
`Documents/en/launchpad/core-bundles.md` (Comparing two builds).

## When an install step fails

Match the symptom in [install-faq](install-faq.md) before trying anything:
"damaged and can't be opened", Developer Tools access switching itself off
(`tccutil reset DeveloperTool com.vphone.launchpad`), several macOS
installations, `zsh: killed`, and the rest.

## Checking the result

`vphone-launchpad-cli status` should show `hostReady: true`, `helper` as
`ready (…)`, `bundleReady: true` and a `defaultBundle`. Then continue with
[machines](machines.md).
