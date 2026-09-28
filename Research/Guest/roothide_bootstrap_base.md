# RootHide bootstrap base

## Observation

Irisin's RootHide bootstrap unpacks packages but nothing builds the parts a
jailbreak's bootstrap installer normally creates. On the 26.4 vphone (jbroot
`/var/containers/Bundle/Application/.jbroot-000114514191980C`), none of them
existed:

- iGhostVT stayed on "Starting…". Its Ghostty config goes under `/tmp`, and
  `var/tmp → ../tmp` pointed at nothing. libghostty only logs the failed write.
- Tools under vroot could not open `/dev/null`.
- `id root` and `id mobile` failed with `no such user: Invalid argument`, while
  group lookups worked.
- OpenSSH reset every connection before its banner: there were no host keys,
  and `ssh-keygen` could not create any because `getpwuid(0)` failed.

Procursus tools link libiosexec, whose `ie_getpw*` replace libc's user lookups.
They read the Berkeley databases (`/etc/pwd.db`, and `/etc/spwd.db` for root)
rather than the text files; icli's `account set-password` edits `spwd.db` for
the same reason. This is inferred from the failure, not from libiosexec's
source. Group lookups still read `/etc/group`. Running
`pwd_mkdb -p /etc/master.passwd` under vroot fixed every user lookup.

A `root/private/etc → ../etc` link was tried and had no effect: libroothide
does not wrap the `getpw*` family.

## Ownership

vphoned creates what a bootstrap installer creates; Irisin keeps what packages
and their maintainer scripts create (for example the `update-alternatives`
links, which Irisin's Bootstrap Install runs). None of the items below is a
package file, so reinstalling packages does not bring them back.

## Implementation

`GuestIrisinInstaller.ensureRootHideBase(root:)` runs right after
`ensureRootHideLinks` in the RootHide install path and in
`refreshBootstrapOnStartup`. Paths are physical; `root/x` is `/x` under vroot.

| Item | Created as |
| --- | --- |
| `root/tmp` | directory `1777`, `0:0` |
| `root/var`, `root/etc` | directory `0755`, `0:0`, when missing |
| `root/var/root` | directory `0700`, `0:0` |
| `root/var/tmp` | link `../tmp` |
| `root/dev` | link `/rootfs/dev`, the convention of RootHide's own `private/preboot → /rootfs/private/preboot` |
| `root/etc/passwd`, `root/etc/group` | copies of `/private/etc/…`, `0644`, `0:0` |
| `root/etc/master.passwd` | copy of `/private/etc/master.passwd`, created `0600`, `0:0` |
| `root/etc/pwd.db`, `root/etc/spwd.db` | `root/usr/sbin/pwd_mkdb -p /etc/master.passwd`, then `0644` and `0600`; checked with `root/usr/bin/id root` when present |
| `root/etc/ssh/ssh_host_*_key` | `root/usr/bin/ssh-keygen -A`, after the databases |

Rules:

- A missing item is created; an existing item is left alone whatever its type,
  owner or mode. A `root/tmp` made by hand keeps its owner.
- The databases are rebuilt only when either is missing or older than
  `master.passwd`, so a password changed with `passwd` survives a restart.
- Host keys are generated only when `root/etc/ssh` exists (openssh is
  installed) and a default key is missing. `-A` never replaces a key.
- vphoned runs `pwd_mkdb`, `id` and `ssh-keygen` by physical path. Each loads
  libroothide through the `.jbroot` link `ensureRootHideLinks` seeds beside
  it, so its arguments are vroot paths.
- On a first install the bootstrap has no `pwd_mkdb` or `ssh-keygen` yet.
  Those steps are reported under `deferred` in the install result and run on
  the next vphoned start after Irisin's Bootstrap Install.
- Any other failure names the path. At install it rolls the install back like
  the other RootHide steps; at startup it is logged.

## Open issues

- **PAM.** With accounts and keys in place, the bootstrap's sshd (OpenSSH 9.2,
  `UsePAM yes`) still fails with `PAM: initialisation failed`, although
  `root/etc/pam.d/sshd` and every module it names exist. With
  `-o UsePAM=no`, password login works. The likely cause, unverified, is a PAM
  library that is not vroot-aware; check `otool -L root/usr/sbin/sshd`.
  `sshd_config` is the package's conffile, so vphoned does not edit it. The fix
  belongs in the bootstrap's libpam or the openssh package.
- **Alternatives links** such as `/usr/bin/pager` only exist when maintainer
  scripts ran. Check whether Irisin's Bootstrap Install creates them on a fresh
  vphone; if it does not, that is an Irisin bug.

## Validation

On a freshly restored vphone, with Irisin installed through vphoned, after
Irisin's Bootstrap Install and one restart, without manual changes:

```sh
# under vroot, in iGhostVT or over ssh
ls -ld /tmp /var/tmp /dev /var/root   # 1777 dir, link, link to /rootfs/dev, 0700 dir
: > /dev/null && echo dev-ok
id root && id mobile                  # both resolve
ls -l /etc/pwd.db /etc/spwd.db /etc/ssh/ssh_host_*_key
```

- iGhostVT opens a shell.
- From the Mac, `ssh mobile@<guest address>` reaches a password prompt (and
  logs in once PAM is settled).
- Change a password with `passwd`, restart, and confirm it still works and
  that the startup log reports nothing created.
