# Guest layout, ssh and the bootstrap

A fresh guest has vphoned and the system changes the project ships, and
nothing else: no package manager, no sshd, no shell tools. Everything in this
file is about adding that environment (the "bootstrap") and then finding your
way around it. Until it is installed, work only through `guest send` and
`guest rpc` — including `script.eval`, which runs JavaScript with vphoned's
identity and needs nothing installed at all (see
[rpc-methods](rpc-methods.md)).

## Contents

- Two layouts: roothide and rootless
- Installing the bootstrap
- First package install
- Inspecting and removing it
- ssh: the shell is not in the real root
- Handing a file to vphoned
- Installing a `.deb`

## Two layouts: roothide and rootless

| | roothide (recommended) | rootless (deprecated) |
| --- | --- | --- |
| Root of the environment | `/var/containers/Bundle/Application/.jbroot-<16 hex>` | `/var/jb`, a symlink to a physical directory under `/private/preboot` |
| Default directory name | `.jbroot-000114514191980C` when none exists (the last byte is a checksum) | none |
| Apps go in | `<jbroot>/Applications` | `/var/jb/Applications` |
| After installing an app | register it: `system.uicache` or `apps.refresh` | same |

Always find the real root with `bootstrap.inspect`; do not hard-code it.

```sh
vphone-launchpad-cli guest rpc myphone bootstrap.inspect
vphone-launchpad-cli guest rpc myphone device.info     # see the layout fields below
```

`device.info` reports `jailbreak.layout` (`roothide`, `rootless`, `rootful` or
`null`), `jailbreak.jbroot` and `jailbreak.source`. These key names belong to
the host-guest protocol; read them as they are. Both null means there is no
bootstrap yet (a read-only `/` is not evidence of a rootful one).

Prefer **roothide**. tvOS and HomePod guests have only roothide:
`vm create --bootstrap rootless` is refused for them.

## Installing the bootstrap

The bootstrap is the Irisin app plus the base directories and links a package
manager needs. Three ways:

- **In the VM window:** menu **Apps > Install Bootstrap…**, pick the layout in
  the sheet. Holding Option shows **Install Bootstrap from File…** (a local
  Irisin `.deb`). The item is enabled only when vphoned advertises
  `bootstrap_install`.
- **At creation:** `vphone-launchpad-cli exec vm create <name> --bootstrap roothide`
  installs the bootstrap and then `owngoal-bootstrap-vphone` during first boot,
  so the next section is already done. It conflicts with `--skip-first-boot`.
- **Over RPC:**

  ```sh
  vphone-launchpad-cli guest rpc myphone bootstrap.install '{"layout":"roothide"}'
  vphone-launchpad-cli guest rpc myphone bootstrap.status
  ```

What `bootstrap.install` does, in order, and what to look at when a step fails:

1. **preparing**: selects the layout. Refuses with an error if
   `/private/var/db/vphoned/bootstrap.json` says a bootstrap is already
   installed. (An uninstall writes a tombstone so this check is accurate.)
2. **downloading**: fetches the latest `Lakr233/Irisin` release for the guest's
   architecture and checks the GitHub SHA-256 digest and the Debian control
   fields. The guest needs network. `bootstrap.status` reports
   `downloaded_bytes` and `total_bytes` when the server gives a length.
3. **extracting / installing**: unpacks the `.deb`, copies the payload into the
   environment, creates Irisin's mobile-owned data directory, registers the app
   and loads its daemon. No maintainer script runs.
4. **firmware**: writes the `firmware` record (the guest iOS version) into the
   environment's `Library/dpkg/status`, so Irisin's resolver sees it.
5. **completed** or **failed** (with `error`). A launchd start error comes back
   as `service_start_warning` while the install still stands; the daemon starts
   on demand when Irisin opens, or after a reboot.

For a local package: upload the `.deb` to exactly
`/var/root/Library/Caches/vphoned-irisin-<UUID>.deb` (regular file, at most
64 MiB, no symlinks) and pass it as `package_path`. vphoned validates name,
architecture, version, executables and the launchd plist.

For roothide, vphoned also builds what a bootstrap installer would (`tmp`,
`var`, `etc`, the `dev` and `rootfs` links, passwd and user databases, the
`.jbroot` loader links) and creates the sshd host keys on the next package
operation. Do not recreate these by hand.

## First package install

A machine created with `--bootstrap roothide` has this already. Otherwise do it
in Irisin in the guest UI; there is no RPC for it.

1. Open Irisin and the **OwnGoal Packages** repository
   (`https://apt.owngoal.dev/`). Find **OwnGoal Bootstrap for vphone**
   (`owngoal-bootstrap-vphone`).
2. Install it with **Bootstrap Install**.

That one meta package depends on everything a guest needs: `apt`, `dpkg`,
`bash`, `zsh`, `sudo`, the core command-line tools, `openssh-server`, `curl`,
`git`, `uikittools`, `launchctl` and the OwnGoal apps. Do not install those packages one by one: they depend on each
other, and `openssh-server` declares some dependencies circularly, so separate
installs can fail partway. After the first pass, install further packages
normally. If the first pass fails, do not repair it in place:
**Apps > Uninstall Bootstrap…**, then start over.

Drive it with `ui.tree`, `ui.tap_element` and screenshots, or ask the user.

## Inspecting and removing it

```sh
vphone-launchpad-cli guest rpc myphone bootstrap.inspect       # every root found
vphone-launchpad-cli guest rpc myphone bootstrap.uninstall '{"roots":["<path from inspect>"],"force":true}'
```

Uninstall removes **every listed root**, unloads their daemons, unregisters
their apps, marks the record uninstalled and **reboots the guest**. Add
`"reboot":false` to skip the reboot; the menu equivalent is the Option
alternate **Uninstall Bootstrap Without Restarting…**. The paths must match the
current inspection exactly.

Uninstall destroys the user's installed packages, so run it only when asked or
as the stated recovery for a failed first install. Rootless Irisin keeps its
data in the system's `/var/mobile/Documents`, which stays. RootHide Irisin keeps
it in the jbroot's `var/mobile`, which goes with the root.

## ssh: the shell is not in the real root

ssh exists only after `openssh-server` is installed (see above); a fresh guest
refuses port 22. `iproxy`, `idevice_id` and `ideviceinstaller` are third-party
libimobiledevice tools; ask the user before installing them. Reach the guest
through the host's usbmuxd with `iproxy`:

```sh
UDID=$(idevice_id -l | head -1)     
iproxy 2222 22 -u "$UDID" &
ssh -p 2222 mobile@127.0.0.1         # the credentials are not documented in the repo; ask the user
```

On roothide the session lands **inside the jbroot**, not the real root:

- `/` in the shell is the environment's root. `/tmp`, `/var/mobile` and `/etc`
  there are the bootstrap's copies, not the guest's.
- The real filesystem is at **`/rootfs`**. `/rootfs/private/var/...` is the
  guest's `/private/var/...`. Logs, app data and preferences are found there.
- vphoned's `files.*`, `apps.*` and other RPCs use the **real** paths. A path
  you see in the ssh shell is not valid for RPC until it is translated.
- There is no `sudo` in a bare jbroot. Install `sudo` as a package first, log in
  as root if the user has set that up, or do root work over RPC.

## Handing a file to vphoned

`guest push` copies a Mac file to a real-root guest path, streamed, any size,
with no ssh and no `--api-listen`. `guest pull` brings one back:

```sh
vphone-launchpad-cli guest push myphone App.ipa /private/var/tmp/
vphone-launchpad-cli guest rpc myphone apps.install '{"path":"/private/var/tmp/App.ipa"}'
vphone-launchpad-cli guest pull myphone /private/var/mobile/Library/Logs/x.log .
```

The mode follows the Mac file (`--mode 755` to set it), so an executable
stays executable. Paths are real-root paths, so a roothide file goes under the
absolute `.jbroot-<hex>` path from `bootstrap.inspect`, not `/var/jb`. It needs
a Core Bundle that has `push` on `vphone.sock`. On an older one, use
`files.write` for small files (size limit in [rpc-methods](rpc-methods.md)) and
ssh for larger ones.

## Installing a `.deb`

With a bootstrap present, copy the package with `scp -P 2222` and run
`sudo dpkg -i` over ssh. A package that ships an app must be registered
afterwards with `system.uicache` over RPC.

When something here misbehaves, read the notes listed in
[finding-docs](finding-docs.md), especially `Research/Guest/roothide_bootstrap_base.md`
and `Research/roothide_loader_links.md`.
