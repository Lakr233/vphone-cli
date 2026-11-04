# Install problems seen in issues

These come from the repository's issue tracker (`Lakr233/vphone-cli`). Each
entry gives the symptom the user reports, the cause, and the fix. Match on the
symptom, apply the fix, and say which issue it was. Issue numbers are for
`gh issue view <n>`.

## Contents

- Launchpad will not open, or Developer Tools access keeps switching off
- Host checks fail
- The host cannot run vphone at all
- Bundle and Launchpad versions
- Creating a machine
- After the machine exists
- Not an install problem

## Launchpad will not open, or Developer Tools access keeps switching off

**"vphone-launchpad is damaged and can't be opened"** (#527). The user
downloaded a Launchpad zip that is not notarized. Releases 2.1.3 to 2.1.7 and
2.2.1 are not notarized; the current list is in `Documents/en/get-started/downloads.md`.
Fix: download `vphone-launchpad-<version>-notarized.zip` for a notarized version
of the **same series** as the bundle they want, and update the bundle to match
(2.1.2 with bundle 2.1.5 was the answer in #527). A non-notarized zip can still
be opened once via System Settings > Privacy & Security > **Open Anyway**, but
see the next entry before recommending it.

**Developer Tools access turns itself off again after the user enables it**
(#540, also "Failed to get developer tools access" on macOS 27). Cause: macOS's
privacy database still holds a Developer Tools entry for `com.vphone.launchpad`
pinned to the code signature of an **earlier build**, typically an ad hoc
signed copy from the plain zip or a self-build. On every launch the system
compares that entry with the notarized app, sees a mismatch and revokes the
grant. Flipping the switch changes only whether access is allowed, not the
stale requirement. Fix:

```sh
tccutil reset DeveloperTool com.vphone.launchpad
```

then open Launchpad, choose **Open Settings**, turn the switch on for
vphone-launchpad, and switch back to Launchpad; Host Setup checks again.
Prevent a repeat by installing only the `-notarized` zip. Mixing the plain and
the notarized zip, or a local build and a release, recreates the problem. A
user on an ad hoc build must reset after every switch. `status` →
`developerTools` shows the result.

## Host checks fail

| Symptom | Cause and fix |
| --- | --- |
| `csrutil: invalid command` for `allow-research-guests` (#226, also "does it work on Intel / hackintosh", #227, #253) | Check the spelling first (the #226 reporter typed `allow-research-agents`). If it is right, the Mac is not Apple silicon: there is no workaround, vphone needs an M-series Mac on macOS 15 or newer |
| Host preflight says "This computer has several macOS installations … Pick a macOS installation" (#503, #511) | Dual-boot or an extra macOS volume. Fixed by PR #512; update Launchpad and the bundle within the series. Until then, the preflight cannot be satisfied from the app |
| `vphone-vm` is killed before a window opens (#435 was a 1.x-era report of `zsh: killed`, closed as outdated; in 2.x `vphone-cli` is unentitled) | AMFI refused the entitled `vphone-vm`. `vphone-launchpad-cli bundle verify <version>` re-runs the allowlist. If SIP is on, the user needs the relaxation from `Documents/en/get-started/host-setup.md` (option B keeps SIP enabled with only debugging restrictions off). Do not suggest `csrutil disable` as a first step |
| "Can I keep SIP on?" (#445) | Yes: `csrutil enable --without debug` plus `csrutil allow-research-guests enable` in Recovery; the allowlist tool ships in the bundle, no third-party tool needed |
| `vphone-escalator` fails with `invalid address` reading the amfid singleton on macOS 27 (#506) | Seen on 2.0.8 with macOS 27.0 on a new chip; fixed by PR #518 in 2.1.0. Move to a newer series, then read `Research/Host/macos27_m6_amfi.md` |
| `VZErrorDomain Code=6 … maximum supported number of active virtual machines has been reached` (#432) | macOS caps concurrent VMs (8 were running). Stop one. The limit is Apple's and is not something to bypass |

## The host cannot run vphone at all

- Running inside another macOS VM or Parallels (#166): not supported; the
  guests need physical Apple silicon. EC2 Mac instances (#482) got no answer.
- 1.x machines (#483, #495): VMs made by 1.x do not start in 2.x and there is no
  in-place upgrade. Create a new machine. The 1.x tooling (Makefile, Python
  scripts, amfidont) is gone; do not follow instructions written for it.

## Bundle and Launchpad versions

- Launchpad refuses a bundle that is too old; it may list bundles from a newer
  series. Stay in the same series (`Documents/en/get-started/downloads.md`).
- Launchpad never updates itself; the user replaces the app.
- A rebuilt local bundle needs `install-local` again (new signature). It
  installs as a new `<version>-local.<hash>` beside the old build; machines stay
  on theirs until `vm set-bundle`.

## Creating a machine

| Symptom | Cause and fix |
| --- | --- |
| Every new machine downloads the IPSW again (#513) | Fixed in 2.0.9: remote IPSWs are cached once in `~/.vphone/ipsws`, GPU drivers per build in `~/.vphone/gpu-drivers/`. A leftover `.ipsw-cache/` inside an old machine can be deleted |
| Creation with a 128 GB or 256 GB disk is slow or fails (#522), the disk shows a different size than requested (#523), firmware download is slow (#524) | All three are fixed since 2.1.1. On an older bundle, update within the series. Check free space before a large disk either way |
| Creation fails at restore or first boot | [troubleshooting](troubleshooting.md) ("Creating a machine"), `vm log --kind create` |
| `fw patch` crashes with SIGBUS (#466) | Fixed in the Capstone package that every 2.x release uses. On 2.1.0 or later it is a new bug: collect the version, the command and its output |

## After the machine exists

| Symptom | Cause and fix |
| --- | --- |
| Guest panics at launch ("Library not loaded: libSystem", no dyld cache) (#532) | The 2.1.6 `mis_trust_auth` patch broke the shared cache; fixed in c53733b, first released in 2.2.0. Update the bundle within the series and recreate the machine |
| Guest panics at launch on a 27 base (#531) | The maintainer thought the first CFW install most likely did not finish (an inference). Running `cfw install` again on the stopped machine is a repair, not a routine step; do it only if the user asks |
| Ethernet or location services missing (#521, #438) | The user chose the **experimental** preset. It is known to break things; recreate with `--preset standard`. (#536 also reported a host location-permission bug, since fixed; update the bundle within the series) |
| iOS 18 machine stuck at the Apple logo after the first reboot, bundle newer than 2.1.0 (#541) | Open issue. Report it; do not recreate repeatedly. Bundle 2.1.0 booted that machine |
| Irisin cannot install `openssh` (#528) | `launchctl` (and the other base packages) were missing. Install `owngoal-bootstrap-vphone` from OwnGoal Packages with Bootstrap Install ([guest-layout](guest-layout.md)) |
| ssh fails on roothide, `sudo` does not work (#502, #519, #520) | Missing bootstrap base items or loader links, fixed in later bundles. [guest-layout](guest-layout.md), `Research/Guest/roothide_bootstrap_base.md` |
| A commercial app (WeChat, TikTok, games) crashes with `CODESIGNING Invalid Page` or is blocked by FairPlay (#212, #220, #356) | The project does not support specific third-party apps; those issues were closed as not planned. Say so, and do not try to patch around it. Apple's own and open-source apps are in scope |
| An app is killed by `EXC_GUARD` (#291) | `Documents/en/help/troubleshooting.md` |

## Not an install problem

"Does Apple ID / App Store / iMessage work", "can I use the Mac's camera",
"iPhone Duo", "passkeys" (#282, #326, #456, #481, #439): these are product
questions. Read `Documents/en/firmware/compatibility.md` and the open issue, and
say plainly that it is unsupported or unresolved rather than guessing.
