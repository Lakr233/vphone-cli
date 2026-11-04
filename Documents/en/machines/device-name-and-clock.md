# Device Name and Clock

The guest takes its device name from the VM and its clock and time zone from your Mac. Read this page when a name or time in the guest is not what you expect.

## Device name

To change the name the guest shows, rename the VM:

```sh
vphone-cli vm rename myphone <new-name>
```

The guest shows the VM's name as its device name, in Xcode's device list and in `xcrun devicectl list devices`.

- You cannot rename the device from inside the guest, or from Finder, Xcode or `idevicename`. A rename there reports success and changes nothing.
- After `vm rename`, Finder and `ideviceinfo` show the new name as soon as the machine is up. Xcode and `devicectl` read the name when the device appears and may show the old name until the following boot.
- A VM name of more than 255 UTF-8 bytes, or with a control character, is not used; the guest then shows its own name.

`vphone-vm` hands the name to the guest each time it connects to vphoned, a few seconds into every boot, and the guest keeps it for the next boot. The guest's own name stays in its preferences, untouched.

An existing machine moved to a bundle with this feature receives the guest library with its environment update and uses it from the boot after that.

For the implementation, see [`Research/Guest/device_name_pinning.md`](../../../Research/Guest/device_name_pinning.md).

## Clock and time zone

The guest follows the Mac's time zone and clock. You do not need to set anything.

`vphone-vm` sends the Mac's time zone each time it connects to vphoned, and the Mac's time then and every minute after. A guest that was off for a day, or sat under a sleeping Mac, is back on the Mac's time within a minute without reaching an NTP server. A guest within a second of the Mac is left alone.

To give the guest a different date or time:

1. In the guest, open **Settings > General > Date & Time**.
2. Pick the date or time. This turns the guest's automatic time off, and the Mac's time is no longer applied.

To go back to the Mac's time, turn **Set Automatically** on again there.

## See also

- [Create and Run a VM](create-and-run.md)
- [Library and Backups](../storage/library-and-backups.md)
- [Networking](../networking/overview.md)
