# vphone-cli setup on this Mac (thread thr_8qrq3xpzcm)

What the setup thread did on this Mac (Apple silicon, macOS 26.5.1 25F80), on
2026-11-25. Later work by other threads (local bundles, the Basil machine,
jailbreak experiments) is not described here; only its visible result is noted
under "State on 2026-11-26".

## Install

The release route from `Skills/vphone-guest-control/references/install.md`, no
source build in this thread:

```sh
git clone --depth 1 https://github.com/Lakr233/vphone-cli.git
gh release download 2.18.0 -R Lakr233/vphone-cli -p 'vphone-launchpad-2.18.0-notarized.zip'
ditto -x -k vphone-launchpad-2.18.0-notarized.zip out
spctl -a -vv out/vphone-launchpad.app      # accepted, Notarized Developer ID
ditto out/vphone-launchpad.app /Applications/vphone-launchpad.app
mkdir -p ~/.local/bin
ln -sf /Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli ~/.local/bin/
vphone-launchpad-cli status
```

Then the owner, in the Launchpad window (Host Setup): turned on Developer Tools
access and installed the helper (administrator password). After that `status`
showed `helper: ready (22)`, `developerTools: true`, `canInstallBundles: true`,
and `VPhone.bundle` 2.18.0 (same series as Launchpad 2.18.0) was installed from
the app and made the default.

This thread did not run `bundle install-local`. The `2.18.0-local.*` bundles in
the store come from other threads.

## Recovery (owner only)

The 2.18.0 preflight failed with "SIP debugging restrictions are enabled". The
fix needs macOS Recovery; `csrutil` refuses to run from the booted system
("This tool needs to be executed from Recovery OS"), so an agent cannot do it.

1. Shut down, hold the power button until "Loading startup options", Options.
2. Utilities > Terminal:

   ```sh
   csrutil enable --without debug
   csrutil allow-research-guests enable
   ```

3. Restart.

A plain restart does not count: the first reboot on 2026-11-25 left SIP fully
on. No `boot-args` were set; the `amfi_get_out_of_my_way=1` route was not used.

## Disk space

A machine needs tens of GB; the Mac had 23 GB free. The thread freed space to
about 110 GB: caches (`~/Library/Caches`, `~/.cache`, npm, brew), `cargo clean`
in one project, Ollama models, `docker system prune -af` and anonymous plus
`saathicash-dify-*` Docker volumes, iOS 18.0/18.1/18.2 simulator runtimes,
stale `go-build*`/`pip-unpack-*` in `$TMPDIR`, clean freehire worktrees, and
five old `~/Projects` folders archived to the USB drive `FLASH`
(`/Volumes/FLASH/Projects-archive/<name>.tar.gz.part-*`; restore with
`cat <name>.tar.gz.part-* | tar -xzf - -C ~/Projects`).

`FLASH` is FAT32: no file over 4 GB, so it cannot hold a machine, a `Disk.img`
or an IPSW. Its first write after mounting took over two minutes.

## The archive script bug (not a vphone script)

The script that archived projects to `FLASH` (thread storage `archive.zsh`, not
part of this repository) had, before `tar`:

```zsh
rm -f "$D/$p.tar.gz.part-"* "$D/._$p.tar.gz.part-"*
```

On the second run no old parts existed, so the glob matched nothing. zsh's
default `NOMATCH` turns that into an error that aborts a non-interactive script,
so it stopped at the first project without writing or deleting anything. The
user stopped the transfer at that point; the script was not fixed or re-run.
The fix would be `setopt NULL_GLOB` at the top (or `rm -f -- $D/$p.tar.gz.part-*(N)`).

## Start order

1. Host prerequisites above: SIP `--without debug`, Research Guests on,
   Launchpad helper ready, Developer Tools access on.
2. `vphone-launchpad-cli status`: `hostReady`, `bundleReady` true.
3. `vphone-launchpad-cli bundle list`: default bundle `preflight: passed`.
4. Create a machine only after checking free disk (one at a time), then start
   it: see `Skills/vphone-guest-control/references/machines.md`.

This thread stopped before step 4; it created and started no machine.

## State on 2026-11-26 (read-only check)

- `csrutil status`: Custom Configuration, Debugging Restrictions disabled,
  everything else enabled. Research Guests: enabled. `boot-args`: none.
- Launchpad 2.18.0. Bundles: `2.18.0` (default) and three `2.18.0-local.*`,
  all `preflight: passed`.
- A machine (Basil) runs, created by another thread.

## Known problems / not covered

- ssh into a guest and moving machines to other hosts were not done in this
  thread; see `Skills/vphone-guest-control/references/guest-layout.md` and
  `Research/Host/machine_identity_and_clone.md`.
- Not checked here: creating, booting or restoring a machine; the AMFI
  allowlist being applied for each bundle cdhash (preflight passing implies it);
  firmware choice; whether `FLASH` is healthy.
