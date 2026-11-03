# Building and finding templates

[Documentation](../README.md) · [Templates](templates.md) · [Create and Run](create-and-run.md)

## Finishing a VM as a template

To turn a VM straight after creating it into a template, stop it, trim it, give it the setup boot, and adopt it. This is what Launchpad does for a template it has to build (below):

```sh
vphone-cli vm stop phone-src
vphone-cli vm template trim phone-src --tier standard   # offline, no root; frees nothing until the setup boot
vphone-cli vm template setup phone-src        # headless; --window to watch, slimming switches as for vm create
vphone-cli vm template adopt phone-src --iphone-source … --cloudos-source …   # key from its records; the sources are recorded
vphone-cli vm create phone-d --template <id> --skip-first-boot
```

`--iphone-source` and `--cloudos-source` on `vm template adopt` record the IPSWs the VM was created from in its `Template.plist`, as a `vm create` that builds a template does. `--json` prints the new template as `vm template show --json` does.

`--expect <id>` on `vm template adopt` refuses, and leaves the VM where it is, unless its records give the template identifier `<id>`: the `id` that `vm template find` printed for the options the VM was built with. Without the check, a VM whose setup boot fell short (an app it could not remove) would be saved under another key, and every later `vm create` with those options would miss it and build another template. The refusal names the fields that differ when it can work out the expected key, which it can when a template or build in the library has it or when only the slimming differs; otherwise it prints the VM's own key to compare. With `--json` the refusal is also printed to stdout as `{"adopted": false, "error": "unexpected_template", "id": …, "expected": …, "differences": […], …}`, and the command exits with status 1.

`vm template setup` refuses a running VM and a frozen template. It trims nothing itself: the tier `vm template trim` recorded is kept, and a `--trim` that names another tier is refused. On a VM it reports an app vphoned would not remove and leaves it out of the recorded steps, so the adopted key says what was really done. With `--strict` it fails instead, records nothing, and the setup boot can be run again: use it when the VM is to be adopted with `--expect` under the key `vm template find` gave for the same switches. Given a `.building-…` name from `vm template list` (a `vm create` whose setup boot failed), it sets the build up to its key, which fixes the slimming, runs the offline trim first if the build stopped before it, and freezes it on success.

## Finding a template

`vm template find` answers what template a `vm create` with the same options would clone from, without downloading, restoring or changing anything:

```sh
vphone-cli vm template find --iphone-source … --cloudos-source … [--device …] [--preset …] [--disk-size …] [--block <id>] [--allow <id>] [slimming switches] --json
```

It works out the key as `vm create` does. The builds come from the IPSWs when they are local files or already in the IPSW cache, and otherwise from a template whose record names the same two sources, so the key still resolves once the IPSWs were deleted, local ones included. `--block` and `--allow` are per-patch overrides as `fw set-patches` records them. The JSON has `resolved`, `resolvedBy` (`ipsw` or `template`), `id`, `summary`, `key`, `template` (the matching template as `vm template show --json` prints it, current or stale), `usable` (it exists and is current), `building` (a create holds its build lock) and, when unresolved, `reason`.

## In Launchpad

Launchpad 2.9 creates machines from templates by default. New Machine opens on a short page: the name, the device and iOS version from the firmware catalog, and a Slim System switch. A row below it sums up the rest and opens Advanced Options, four pages for hardware; the template and its parts (the trim tier and kept languages, the service profile, and which system apps go); the Core Bundle, custom IPSWs and patches; and the location, network and restore options. The row counts the settings that differ from the defaults and names anything there that stops Create. Turning off Create from a template restores the machine on its own, as `--no-template` does, with keys of its own and without slimming. Apple Account is not offered: the guest refuses its sign-in either way, so Launchpad passes `--accounts-off` whenever the service profile is trimmed. The sheet grows with its page up to 600 points and scrolls past that, so its buttons stay on a laptop screen.

Under Firmware, a release that also runs on its own cloudOS (`fw catalog`'s third column) offers that cloudOS beside the recommended one, with the `ipsw` that stages the kernelcache mix. The creation then stages the mix as you and has the helper link it as root, which asks for authorization once.

The 2.12 Launchpad interface still shows its legacy ipsw selector for older compatible bundles. Native Core Bundle extraction ignores the selected tool path; the CLI no longer needs it.

The iPhone XS Max runs iOS 18.1 to 18.7.2, each on its own release's cloudOS, with no template and the Minimal preset by default; Standard works as well (checked on 18.6). Its pairings always rebuild the kernelcache, so Firmware asks for the `ipsw`, and for the macOS builder: `user@host` of a Mac or macOS VM running macOS 15 or 26.0 to 26.3 with Remote Login on, and its password for ssh and sudo (empty with ssh keys and passwordless sudo). Launchpad keeps the builder like the `ipsw`, but not the password, which reaches `vphone-cli` only in its environment (`VPHONE_KMUTIL_SSH_PASSWORD`). The creation then stages and links the mix as you, over ssh; from macOS 26.4 on the builder is required, on an older Mac without one the helper links it as root.

The creation runs `vm template find` first. When a current template matches, it clones the machine (`vm create --template <id> --skip-first-boot`) and boots it. When none does, it builds the template in a temporary machine of the same library, named `template-` and eight hex digits, with its usual steps (restore, then `cfw install` through the helper), then `vm template trim`, the headless `vm template setup --strict` and `vm template adopt --iphone-source … --cloudos-source … --expect <id>`, and clones the machine from the result. The setup boot fails when an app it should remove stays, and the adopt fails when the build's key comes out other than the one `find` computed, so a build is never saved under an id later creations would not find. Each is a step of its own with its duration, and a failed one shows the reason `vphone-cli` gave.

Per-patch overrides from New Machine's Patch Settings are split the way the template key splits them. Boot-chain overrides are part of the key: the template is built with them, and `find` looks for one with them. Guest patch overrides are not: the template is built without them, and after the clone the creation records them on the new machine with `fw set-patches` and writes them with `cfw update-environment` through the helper (the Apply guest patches step) before its first boot. A template therefore never hands one creation's guest patch choice to another. Once it has built a template, the creation offers to delete the two IPSWs it came from; nothing is deleted without confirming.

File > Templates… lists every library's templates with their machines, slimming, size and state, and deletes them. Guest System… (in a machine's Actions menu and inspector) switches a running machine's service profile and restores system apps the template removed. The inspector and the machine list show each machine's exclusive disk use beside what its files allocate: the blocks no other machine or template holds, which deleting it frees (a local Time Machine snapshot taken before keeps them until it expires).
