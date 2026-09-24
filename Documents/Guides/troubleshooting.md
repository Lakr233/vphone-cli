# Troubleshooting

[Documentation](../README.md) · [Host setup](host-setup.md) · [Create a VM](create-and-run.md)

## `vphone-vm` is killed before the VM opens

Run `vphone-cli host preflight`. The CLI is unentitled and can explain an AMFI refusal of its signed `vphone-vm` companion. If you rebuilt, the cdhash changed: allow the new binaries with the bundled helper as described in [host setup](host-setup.md).

## `Virtualization is not available on this hardware`

PV=3 guests cannot be nested. Boot on an Apple Silicon Mac rather than inside another macOS VM.

## `vm create` printed vphoned success, but no VM is running

That is expected. Creation starts a temporary GUI boot, sends a real ping, and stops that boot before returning. Start the VM for use with `vphone-cli vm launch <name>`.

## Stuck at “Press home to continue”

Use the VM window's **Keys → Home** action. The current JB workflow does not install a VNC server.

## App exits with `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`

The optional `vphone-cli fw patch <name> --force-exc-guard` patch can address this class of crash. Repatching firmware alone does not alter an already restored guest: restore and reinstall CFW after changing the patch set. See [issue #291](https://github.com/Lakr233/vphone-cli/issues/291).

## Restore or first boot fails

Keep the VM in DFU until `restore` exits in a manual flow, and check that online ticket requests can reach Apple. For the complete pipeline, rerun `vm create` with a **new name** and `-v` for tool detail; avoid parallel VM creation when memory or disk is tight. Inspect [firmware compatibility](compatibility.md) before combining an iPhone IPSW with a PCC image.

If the guest boots but vphoned does not answer, the first-boot check times out after 300 seconds. A GUI boot is used because a newly restored guest may not bring up vphoned during its first headless boot. See [create and run](create-and-run.md) for what the success marker proves.
