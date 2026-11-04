# Machines: create, run, update

## Contents

- Inspect
- Create
- Retry a failed creation
- Start, wait, stop
- Logs
- Core Bundle of a machine
- Updating a machine's guest components
- Where things live

## Inspect

```sh
vphone-launchpad-cli vm list
```

One object per machine: `name`, `libraryRoot`, `state` (`stopped`, `running`,
`busy: <activity>`), `cpuCount`, `memoryMB`, `network`, `panicked`, `log`,
`controlSocket` (null until the machine serves `vphone.sock`), `bundle`,
`guestEnvironmentBundle`, `bootChainBundle` (see
[Core Bundle of a machine](#core-bundle-of-a-machine)), and when known `udid`,
`ios` and `cloudOS`. Check `state` before any machine command; start and
update refuse a machine that is not `stopped`.

## Create

A creation downloads two IPSWs, patches the boot chain, restores through DFU,
installs the custom firmware into the guest, and boots once to prove vphoned
answers. It leaves a **stopped** machine. Success is not a running guest.

Before starting, check free disk (tens of GB, more with `--keep-artifacts`),
that no other creation is running, and that `status` shows `bundleReady` (or
that the version you pass to `--bundle` passed its checks in `bundle list`).

```sh
vphone-launchpad-cli vm create myphone [--bundle <version>] \
  [--iphone-source <path-or-url>] [--cloudos-source <path-or-url>] [--device <product-type>] \
  [--cpu 8] [--memory 8192] [--disk-size 64] \
  [--network nat|bridged|none] [--preset standard|experimental] \
  [--keep-artifacts] [--no-wait]
```

- **`--bundle`** binds the machine to an installed version; the default bundle
  otherwise. Every step runs with it, and the result reports it as `bundle`.
- **Sources are optional.** If either is omitted, the newest pairing from
  `vphone-cli fw catalog` is used (the CLI prints `firmware: <iphone> + <cloudos>`).
  Pass both explicitly to pin a pairing; verified pairings are listed in
  `Documents/en/firmware/compatibility.md`. Local paths are read in place; URLs are
  cached in `~/.vphone/ipsws/`.
- **`--device`** makes an iPad guest: `iPad16,1`, `iPad15,7`, `iPad15,3`,
  `iPad15,5`, `iPad16,3`, `iPad16,5`, `iPad17,1` or `iPad17,3`. Without sources
  it takes that iPad's newest catalog pairing; with an iPad IPSW that covers
  two sizes it picks the size. See `Documents/en/firmware/ipados.md`.
  `AppleTV5,3` makes an Apple TV HD guest on tvOS 26.6: always without a
  template or slimming, with the `tvos` preset unless `--preset` names
  another. `AppleTV14,1` makes an Apple TV 4K guest the same way, with the
  `tvos-4k` preset; `fw prepare` takes its device tree and arm64e userland
  from the catalog's OTA. See `Research/Firmware/tvos_support.md`.
- **Units:** `--cpu` is a count, `--memory` is **MB**, `--disk-size` is **GB**.
  Defaults 8, 8192, 64. All must be positive integers.
- **Name:** letters, digits, `.`, `-`, `_`. Keep it short: the machine path must
  fit a Unix socket path, and the command says so if it does not.
- **`--preset`** picks the patch preset: `standard` (default) or `experimental`.
- **`--no-wait`** returns at once with a report instead of streaming the
  pipeline. Without it the CLI streams the creation log and returns when the
  pipeline stops.
- The nine steps, in order: `create`, `prepare`, `patch`, `bootDFU`, `waitDFU`,
  `restore`, `stopDFU`, `installCFW`, `firstBoot`. The final JSON report lists
  each with `status` and `seconds`, plus the `log` path.
- Creation needs network access for the restore ticket. Do not interrupt a
  restore by killing processes; the window owns it.

If the name exists or a creation under it is running, the command refuses.
Choose a new name rather than reusing a half-built machine.

## Retry a failed creation

```sh
vphone-launchpad-cli vm create myphone --from restore
```

`--from` takes one of the step names above and reruns from there. It works only
for a creation **this running Launchpad has started since it launched**; after a
relaunch it says there is nothing to retry. In that case create under a new
name. Read why it failed first:

```sh
vphone-launchpad-cli vm log myphone --kind create --lines 200   # create | dfu | patch
```

## Start, wait, stop

```sh
vphone-launchpad-cli vm start myphone --wait [--timeout 300]
vphone-launchpad-cli vm start myphone --headless --wait
vphone-launchpad-cli vm wait myphone --timeout 300
vphone-launchpad-cli vm stop myphone
```

- `--wait` pings vphoned over `vphone.sock` every second until it answers. It
  fails early, with the console log path, on a kernel panic or when the VM
  process exits. The default timeout is 300 s, which first boots can use up.
- A window opens by default. `--headless` runs without one, and the guest is
  driven entirely through `vphone.sock`.
- `vm start` refuses a machine that is running or busy. If the VM was started
  elsewhere, use `vm wait`.

## Logs

```sh
vphone-launchpad-cli vm log myphone --lines 100
vphone-launchpad-cli vm log myphone --kind create|dfu|patch --lines 200
```

Files live in `~/Library/Logs/vphone-launchpad/`: `<name>.log` (VM console and
kernel output), `<name>-create.log`, `<name>-dfu.log`, `<name>-patch.log`.

## Core Bundle of a machine

Each machine is bound to one installed `VPhone.bundle` version, kept in
`launchpad.json` in its folder. Installing a bundle or changing the default
never moves a machine. Three layers come from a bundle at different times:

| Layer | `vm list` field | Changes when |
| --- | --- | --- |
| Host programs (`vphone-cli`, `vphone-vm`) | `bundle` | At the next start after `vm set-bundle` |
| Guest environment (vphoned, hook dylibs) | `guestEnvironmentBundle` | `cfw install`, `cfw update-environment` |
| Boot chain and patches | `bootChainBundle` | Never; create a new machine |

```sh
vphone-launchpad-cli vm set-bundle myphone 2.2.4 --update-environment
```

`vm set-bundle` rebinds the machine. With `--update-environment` it also
redeploys that version's guest environment, which needs a stopped machine;
without it, the guest keeps the old vphoned and hooks, and `vm list` shows
`guestEnvironmentBundle` differing from `bundle`. A running machine picks up
the new host programs at its next start. `bundle remove` refuses a version
while a machine is bound to it. Rebind only when the user asks; it changes
what their machine runs.

## Updating a machine's guest components

For a **stopped** machine:

```sh
vphone-launchpad-cli cfw update-environment myphone
```

This redeploys the guest resources (vphoned and the hook dylibs) of the
machine's own bundle and changes nothing else. Do it when
`guestEnvironmentBundle` differs from `bundle`, such as after `vm set-bundle`
without `--update-environment`. `cfw install myphone` redoes the whole custom-firmware install through the root
helper; use it only to repair a machine, and only when asked.

## Where things live

| Path | Contents |
| --- | --- |
| `~/.vphone/machines/<name>/` | One machine: disk, `config.plist`, `launchpad.json` (its Core Bundle), `vphone.sock` while running |
| `~/.vphone/ipsws/` | Downloaded source IPSWs, shared |
| `~/.vphone/gpu-drivers/<version>_<build>/` | GPU driver extracted per cloudOS build, shared |
| `~/Library/Logs/vphone-launchpad/` | Console and creation logs |

`VPHONE_ROOT` relocates the library and caches. Launchpad can hold several
libraries; `status.libraries` lists them.
