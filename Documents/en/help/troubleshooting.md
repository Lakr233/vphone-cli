# Troubleshooting

Find the symptom or error message you see, then follow the fix under it. For network problems, see [Networking](../networking/overview.md).

## `vphone-vm` is killed before the VM opens

1. Run the host preflight:

   ```sh
   vphone-cli host preflight
   ```

   The CLI is unentitled, so it keeps running and can explain an AMFI refusal of its signed `vphone-vm` companion.
2. If you rebuilt the bundle, the cdhash changed. Allow the new binaries with the bundled helper as described in [Host setup](../get-started/host-setup.md).

## `Virtualization is not available on this hardware`

PV=3 guests cannot be nested. Boot on an Apple Silicon Mac, not inside another macOS VM.

## `vm create` printed vphoned success, but no VM is running

That is expected. Creation starts a temporary GUI boot, sends a real ping, and stops that boot before returning. Start the VM for use:

```sh
vphone-cli vm launch <name>
```

## Stuck at "Press home to continue"

Click the Home button in the VM window's title bar. The current JB workflow does not install a VNC server.

## App exits with `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`

The kernel patch `kernel-boot-thread_guard_violation` stops fatal Mach port guard delivery. It applies only on an iOS 18 base, where it is needed to boot, and every preset turns it on there. Other bases cannot select it, so an app that trips this guard on a 26.x base still exits. See [issue #291](https://github.com/Lakr233/vphone-cli/issues/291).

## Restore or first boot fails

- In a manual flow, keep the VM in DFU until `restore` exits.
- Check that online ticket requests can reach Apple.
- For the complete pipeline, rerun `vm create` with a **new name** and `-v` for tool detail.
- Avoid creating VMs in parallel when memory or disk is tight.
- Before combining an iPhone IPSW with a PCC image, check [Firmware compatibility](../firmware/compatibility.md).

## The guest boots, but vphoned does not answer during creation

The first-boot check times out after 300 seconds. Creation uses a GUI boot because a newly restored guest may not bring up vphoned during its first headless boot. See [Create and run](../machines/create-and-run.md) for what the success marker proves.

## Xcode or Instruments lists the guest as offline

CoreDevice pairs a guest as a wired device, but keeps its tunnel up only while a program holds it. Without the tunnel, `xcrun xctrace list devices` lists the guest under "Devices Offline", and `xctrace record --device <UDID>` waits for the device to boot and gives up after about 30 seconds. Instruments offers to connect only network devices, never a wired one.

Have `vphone-vm` hold the tunnel open while the guest runs:

- In the VM window, choose **Diagnostics > Keep Developer Tunnel Open**. It applies at once and is saved to the machine.
- Or, from Terminal:

  ```sh
  vphone-cli vm config <name> --developer-tunnel on
  ```

  This applies from the next start. `vm info` shows the setting as `developer tunnel`.

Once vphoned answers, `vphone-vm` runs `/usr/bin/devicectl` against the guest and starts it again whenever it exits. On a Mac without `/usr/bin/devicectl`, the VM log shows one `[developer-tunnel]` line and the tunnel is not held.

A bundle without this setting can hold the tunnel from Terminal instead. Take the guest's UDID from `vphone-cli vm info <name>` and leave the command running:

```sh
/usr/bin/devicectl device notification observe --device <UDID> \
  --name com.vphone.keepalive --session-timeout 3500 --timeout 3600
```

`--session-timeout` must be less than `--timeout`. The command exits after an hour; run it again then.

For a minute or so after the tunnel comes up, `xctrace record --attach` can fail with `Cannot find process matching name` or `Cannot find process for provided pid`. Wait, then try again.

## See also

- [Host setup](../get-started/host-setup.md)
- [Create and run](../machines/create-and-run.md)
- [Firmware compatibility](../firmware/compatibility.md)
