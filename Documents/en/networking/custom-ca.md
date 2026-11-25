# Custom CA certificates

The `vm ca` commands install, list and remove trusted root CA certificates in a running guest's TrustStore. Use them when the guest must trust a certificate that the system does not ship, such as the root of an intercepting HTTPS proxy whose CA certificate you want the guest to trust.

All three commands talk to a running VM, so start the machine with `vm launch` first. Pass the VM name explicitly, as in the examples below; the required argument comes first and the VM name second. If you omit the name, an interactive picker lists every VM in the library, running or not (even if only one exists), and asks you to choose. With no terminal (scripts, CI) the command fails with `No VM name given, and this is not an interactive terminal`, so always give the name in automation.

## Install

```sh
vphone-cli vm ca install <pem-file> <vm-name> [--admin] [--json]
```

Installs a single-certificate PEM file (at most 64 KiB) as a trusted root CA in the guest. It prints one line:

```text
sha256<TAB>subject
```

| Option | Meaning |
| --- | --- |
| `--admin` | Install into the admin trust domain instead of the default user domain. |
| `--json` | Emit `{sha256, subject, domain}` as pretty-printed JSON with sorted keys instead of the single line. |

## List

```sh
vphone-cli vm ca list <vm-name>
```

Lists the installed anchors, one per line as `sha256<TAB>subject`, sorted by sha256.

## Remove

```sh
vphone-cli vm ca remove <sha256> <vm-name>
```

Removes the anchor with that 64-character hex sha256, as shown by `list`.

## Example

Trust the root of an intercepting HTTPS proxy whose CA certificate you want the guest to trust, confirm it landed, then remove it when you are done:

```sh
vphone-cli vm ca install proxy-ca.pem my-vm
vphone-cli vm ca list my-vm
vphone-cli vm ca remove 9f2b8c1d4e6a0f3b5c7d9e1a2b4c6d8e0f1a2b3c4d5e6f708192a3b4c5d6e7f8 my-vm
```

## See also

- [Networking](overview.md)
- [Tunnel mode](tunnel.md)
