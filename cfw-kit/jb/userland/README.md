# JB userland slot

Both flavour directories here are **empty on purpose**. `jb/install.sh` installs
the firmware and filesystem layers; everything above that — BaseBin hooks, the
procursus bootstrap, a package manager, a tweak loader, a first-boot setup
daemon — is left to a flavour, because rootless and roothide disagree about
where any of it lives.

With no flavour selected the guest boots a **jailbroken kernel under a stock
userland**. That is a valid, deliberate end state, not a half-finished install.

> The authoritative hook contract — exact call sites, variables in scope,
> available helpers, and the two declarations a flavour must make — is
> **§10 of `~/Desktop/vphone-cli-migration-plan.md`**. This page is only how to
> drive it. If the two ever disagree, the plan wins.

## Selecting a flavour

```sh
JB_USERLAND=rootless ../../run.sh --variant jb /path/to/vm
```

`JB_USERLAND` is `none` by default. Naming a flavour whose directory has no
`install.sh` is a hard error raised **before the disk image is attached**, so a
half-built flavour cannot leave a half-modified volume behind.

## Adding one

Drop an `install.sh` in `rootless/` or `roothide/`. It is **sourced**, not
executed, so it must define functions rather than run work at the top level.
Two optional hooks:

| function | when it runs |
| --- | --- |
| `userland_launchd_hook <workfile>` | on the launchd work copy, after its entitlements are saved and before the jetsam patch and re-sign |
| `userland_install` | after J3, with the volumes still mounted, just before unmount |

Top-level statements run at source time — before `preflight`, before anything is
written. That is where a flavour declares what it needs:

```zsh
# checked by preflight, before the first write
REQUIRED_CFW_SUBCOMMANDS+=(inject-dylib)

# if you rewrite /System/Library/xpc/launchd.plist you MUST set this, or
# launchd will refuse the modified plist and the guest will not boot
USERLAND_MODIFIES_LAUNCHD_PLIST=1
```

## Payloads already in the repo

`scripts/resources/cfw_jb_input.tar.zst` carries a rootless-shaped set:

- `basebin/launchdhook.dylib`, `basebin/libellekit.dylib`, `basebin/systemhook.dylib`
- `jb/bootstrap-iphoneos-arm64.tar.zst`
- `jb/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb`

None of these are Apple binaries — they are ElleKit/Dopamine-derived, so the
provenance question that applies to the GPU bundle does not apply here.

**roothide has no payload in this repo.** A roothide flavour has to bring its
own BaseBin; the dylibs above are built for rootless path assumptions and
will not work unmodified.
