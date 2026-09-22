# custom-firmware-kit

Two independently buildable CFW environments for vphone-cli guests, sharing one
base install path.

| | vanilla | jb |
| --- | --- | --- |
| goal | boots to SpringBoard, nothing else | jailbroken kernel, empty userland |
| boot chain | `make fw_patch` (52 patches) | `make fw_patch_jb` (**127 patches**) |
| SSH / VNC / RPC | none | none (slot's job) |
| daemons added | none | none |
| `launchd.plist` | untouched | untouched |
| userland | yours to design | slot: `rootless` / `roothide`, both empty |

The kit does **not** fork the Python patchers. It calls the repo's
`scripts/patchers/cfw.py`, so patch behaviour cannot drift from upstream.
It does not modify the vphone-cli repo at all.

## Use

```sh
# boot chain first — the kit only does the filesystem layer
cd ~/Documents/GitHub/Lakr233/vphone-cli && make fw_patch      # or fw_patch_jb

# then, with the VM restored and POWERED OFF
~/Desktop/custom-firmware-kit/run.sh --variant vanilla /path/to/vm
~/Desktop/custom-firmware-kit/run.sh --variant jb      /path/to/vm
```

`run.sh` re-execs itself under `sudo` (owners-honoured mounts need root),
attaches `Disk.img`, runs the variant installer against the mounted volumes,
then flips the boot snapshot offline via the repo's `tools/apfs_snap_rename.py`.

Check what would happen without touching anything — **no root, no attach, no
writes**:

```sh
KIT_CHECK_ONLY=1 ./run.sh --variant jb
```

### Knobs

| variable | default | effect |
| --- | --- | --- |
| `JB_USERLAND` | `none` | `rootless` \| `roothide`; jb only. Both slots are empty, so anything but `none` is currently a hard error *before* the image is attached |
| `VANILLA_LSD_EMBEDDED_REG` | `0` | vanilla, 27 bases: open lsd's JB app-registration path |
| `FORCE_DSC_MAXSLIDE` | `0` | zero maxSlide on non-27 bases (normally self-gated to a no-op) |
| `KIT_CHECK_ONLY` | `0` | preflight and stop |
| `VPHONE_REPO` / `--repo` | auto | vphone-cli checkout to take `cfw.py` and resources from |
| `VPHONE_DROP_ARTIFACTS` | `0` | delete the extracted `cfw_input/` afterwards |

## Layout

```
run.sh                  host driver: attach, dispatch, snapshot flip
lib/common.sh           helpers lifted from upstream cfw_install.sh + preflight
lib/base_stages.sh      the stages both variants need
vanilla/install.sh      minimal boot
jb/install.sh           + jetsam guard, debugserver, Campo, two slot hooks
jb/userland/            empty slots (rootless, roothide) + how to fill them
docs/phase-matrix.md    every upstream phase → variant, with evidence
```

`../paravirt-gpu-provenance-kit/` is separate and unchanged. It documents where
the two binaries in the GPU bundle come from; this kit only installs them.

## Design notes

**Preflight is the only safety net.** The installer streams onto a mounted
volume with no snapshot to roll back to, so everything that can fail is checked
before the first write: tools, Python deps, and every `cfw.py` subcommand this
variant *and its userland slot* will call. A userland flavour is sourced before
preflight precisely so its requirements get checked too.

**`umount` is never forced.** If something still holds a file on the volume the
kit wants to hear about it, not paper over it with `umount -f`
(`lib/base_stages.sh`).

**Why vanilla drops `launchd_cache_loader`.** That patch exists only to let
launchd accept a modified `launchd.plist`, and upstream's phase 7/7
(`inject-daemons`) is the only thing that modifies it. Vanilla installs no
daemons, so the patch has nothing to enable and stock validation passes
untouched. A userland flavour that *does* rewrite `launchd.plist` must declare
`USERLAND_MODIFIES_LAUNCHD_PLIST=1`, which re-arms the patch automatically.
Full reasoning in `docs/phase-matrix.md`.

## Verification status — read this before trusting the kit

Done, and repeatable:

- `zsh -n` on all five scripts
- `KIT_CHECK_ONLY=1` preflight actually executed for both variants, and for
  vanilla with the lsd flag on — all pass on this host
- all 12 `cfw.py` subcommands the kit can call confirmed present
- payload paths confirmed present: `cfw_input/signcert.p12`,
  `cfw_input/custom/AppleParavirtGPUMetalIOGPUFamily.tar`,
  `campo_mach_lookup_exceptions.py`, `tools/apfs_snap_rename.py`
- slot contract exercised with a throwaway flavour: `REQUIRED_CFW_SUBCOMMANDS`
  appends reach preflight, `USERLAND_MODIFIES_LAUNCHD_PLIST=1` pulls in
  `patch-launchd-cache-loader`, and a flavour demanding a nonexistent
  subcommand is rejected with nothing written
- `run.sh` error paths: missing `--variant`, unknown variant, unknown
  `JB_USERLAND`, empty slot

**Not done — no VM was available on the authoring host:**

- no real install has ever run
- **no guest has ever booted from either variant**
- whether vanilla actually reaches SpringBoard is a static inference from
  upstream's code and the research docs, not a measurement

Treat the phase matrix as a reviewed argument, not a test result. The first real
run should be vanilla on a 26.x base, where the fewest version gates fire.
