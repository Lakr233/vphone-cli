# Boot ROMs

Choose which boot ROM and SEP boot ROM a VM starts from. Use this page to check which ROMs a VM uses or to switch between the open-source ROMs and Apple's.

## Check and switch

```sh
vphone-cli vm info myphone                                    # shows rom and seprom
vphone-cli vm config myphone --rom openavb --seprom opensep   # open-source ROMs
vphone-cli vm config myphone --rom apple --seprom apple       # Apple's ROMs
```

A switch applies from the VM's next start, without a restore, in either direction.

| Option | Value | ROM |
| --- | --- | --- |
| `--rom` | `openavb` | The bundle's OpenAVB |
| `--rom` | `apple` | Virtualization.framework's AVPBooter (the machine's own patched copy when it has one) |
| `--rom` | a file path | Any other boot ROM |
| `--seprom` | `opensep` | The bundle's OpenSEP |
| `--seprom` | `apple` | Virtualization.framework's AVPSEPBooter |
| `--seprom` | a file path | Any other SEP boot ROM |

Both boot ROMs load the same patched LLB, and both SEP ROMs load the SEP firmware the restore installed, which is why no restore is needed.

> [!NOTE]
> Restoring a VM that boots OpenAVB needs `VPhone.bundle` 2.10.1 or newer.

## Which ROMs a VM uses

New VMs start from two open-source ROMs instead of the closed ones in Virtualization.framework:

- [OpenAVB](https://github.com/owngoal-dev/OpenAVB) replaces AVPBooter, the boot ROM. It needs no patch, so `fw patch` leaves it alone.
- [OpenSEP](https://github.com/owngoal-dev/OpenSEP) replaces AVPSEPBooter, the SEP boot ROM.

With both, nothing Apple wrote runs before iBoot and SEPOS. VMs created by earlier versions keep Apple's ROMs until you switch them.

## Where the ROMs come from

Both ship in `VPhone.bundle`, prebuilt from pinned upstream commits. Each one's README says how to rebuild it and check it byte for byte:

- [OpenAVB README](../../../VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/README.md)
- [OpenSEP README](../../../VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/README.md)

For the details, see the research notes on [OpenAVB](../../../Research/Firmware/openavb_boot_rom.md) and [OpenSEP](../../../Research/Firmware/opensep_sep_rom.md).

## See also

- [Create and Run a VM](create-and-run.md)
- [Firmware Preparation](../firmware/firmware-preparation.md)
- [Troubleshooting](../help/troubleshooting.md)
