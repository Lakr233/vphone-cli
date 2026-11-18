# Install problems seen in issues

These come from the repository's issue tracker (`Lakr233/vphone-cli`). Each
entry gives the symptom the user reports, the cause, and the fix. Match on the
symptom and apply the fix. Issue numbers are for `gh issue view <n>`.

## Contents

- Launchpad will not open
- Host checks fail
- The host cannot run vphone at all
- Creating a machine
- After the machine exists

## Launchpad will not open

**"vphone-launchpad is damaged and can't be opened"** (#527). The user
downloaded a Launchpad zip that is not notarized. Download
`vphone-launchpad-<version>-notarized.zip` for a notarized version of the same
series as the bundle they want (the list is in
`Documents/en/get-started/downloads.md`). The plain zip can be opened once via
System Settings > Privacy & Security > **Open Anyway**.

## Host checks fail

| Symptom | Cause and fix |
| --- | --- |
| `csrutil: invalid command` for `allow-research-guests` (#226, also "does it work on Intel / hackintosh", #227, #253) | Check the spelling first. If it is right, the Mac is not Apple silicon: there is no workaround, vphone needs an M-series Mac on macOS 15 or newer |
| `vphone-vm` is killed before a window opens (`zsh: killed`) | AMFI refused the entitled `vphone-vm`; in 2.x `vphone-cli` is unentitled. `vphone-launchpad-cli bundle verify <version>` re-runs the allowlist. If SIP is on, the user needs the relaxation from `Documents/en/get-started/host-setup.md` (Option A keeps SIP enabled with only debugging restrictions off; Option B disables SIP and AMFI). Do not suggest `csrutil disable` as a first step |
| "Can I keep SIP on?" (#445) | Yes: `csrutil enable --without debug` plus `csrutil allow-research-guests enable` in Recovery; the allowlist tool ships in the bundle |

## The host cannot run vphone at all

- Running inside another macOS VM or Parallels (#166) is not supported; the
  guests need physical Apple silicon.
- 1.x machines (#483, #495) do not start in 2.x and there is no in-place
  upgrade. Create a new machine and do not follow 1.x instructions.

## Creating a machine

| Symptom | Cause and fix |
| --- | --- |
| Creation fails at restore or first boot | [troubleshooting](troubleshooting.md) ("Creating a machine"), `vm log --kind create` |

## After the machine exists

| Symptom | Cause and fix |
| --- | --- |
| Irisin cannot install `openssh` (#528) | `launchctl` and the other base packages are missing. Install `owngoal-bootstrap-vphone` with Bootstrap Install ([guest-layout](guest-layout.md)) |
| ssh fails on roothide, `sudo` does not work (#502, #519, #520) | Missing bootstrap base items or loader links. See [guest-layout](guest-layout.md) and `Research/Guest/roothide_bootstrap_base.md` |
| An app is killed by `EXC_GUARD` (#291) | `Documents/en/help/troubleshooting.md` |

