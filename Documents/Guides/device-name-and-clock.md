# Device name and clock

[Documentation](../README.md) · [Create and Run](create-and-run.md) · [Networking](networking.md)

## Device name

The guest shows the VM's name as its device name, in Xcode's device list and `xcrun devicectl list devices`, and cannot be renamed from inside the guest or from Finder, Xcode or `idevicename`: a rename there reports success and changes nothing. `vphone-vm` hands the name to the guest each time it connects to vphoned, a few seconds into every boot, and the guest keeps it for the next boot. After `vm rename`, Finder and `ideviceinfo` see the new name as soon as the machine is up; Xcode and `devicectl` read it when the device appears and may show the old name until the following boot. An existing machine moved to a bundle with this feature receives the guest library with its environment update and uses it from the boot after that. The guest's own name stays in its preferences, untouched. A VM name of more than 255 UTF-8 bytes, or with a control character, is not used, and the guest shows its own name. See `Research/Guest/device_name_pinning.md`.

## Clock and time zone

The guest follows the Mac's time zone and clock. `vphone-vm` sends the Mac's zone each time it connects to vphoned, and the Mac's time then and every minute after, so a guest that was off for a day, or sat under a sleeping Mac, is back on the Mac's time within a minute without reaching an NTP server. A guest within a second of the Mac is left alone. To give the guest another date or time, pick it in the guest's Settings › General › Date & Time: that turns its automatic time off and the Mac's time is no longer applied. Turning Set Automatically on there brings the Mac's time back.
