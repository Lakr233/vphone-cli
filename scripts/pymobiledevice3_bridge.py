import asyncio
import inspect
import plistlib
import sys
import time
from collections.abc import Awaitable
from pathlib import Path
from typing import Optional

from ipsw_parser.ipsw import IPSW
from pymobiledevice3 import usbmux
from pymobiledevice3.exceptions import (
    ConnectionFailedError,
    ConnectionFailedToUsbmuxdError,
    IRecvNoDeviceConnectedError,
    IncorrectModeError,
)
from pymobiledevice3.irecv import IRecv
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.restore.device import Device
from pymobiledevice3.restore.recovery import Behavior, Recovery
from pymobiledevice3.restore.restore import Restore
import typer


def parse_ecid(value: Optional[str]) -> Optional[int]:
    if not value:
        return None
    raw = value.strip().lower()
    if raw.startswith("0x"):
        raw = raw[2:]
    if not raw:
        raise ValueError("ECID is empty")
    if any(c not in "0123456789abcdef" for c in raw):
        raise ValueError(f"Invalid ECID: {value}")
    return int(raw, 16)


def normalize_udid(value: Optional[str]) -> Optional[str]:
    return None if value is None else value.strip().upper()


def find_restore_dir(vm_dir: Path) -> Path:
    candidates = sorted(p for p in vm_dir.glob("iPhone*_Restore") if p.is_dir())
    if not candidates:
        raise FileNotFoundError(f"No iPhone*_Restore directory found in {vm_dir}")
    if len(candidates) > 1:
        raise RuntimeError(
            "Multiple iPhone*_Restore directories found; keep only one active restore tree"
        )
    return candidates[0]


async def resolve_device(ecid: Optional[int], udid: Optional[str]) -> Device:
    udid_normalized = normalize_udid(udid)

    try:
        devices = [d for d in await usbmux.list_devices() if d.connection_type == "USB"]
    except ConnectionFailedToUsbmuxdError:
        devices = []

    for usb_device in devices:
        serial = normalize_udid(getattr(usb_device, "serial", None))
        if udid_normalized and serial != udid_normalized:
            continue

        try:
            lockdown = await create_using_usbmux(serial=usb_device.serial, connection_type="USB")
        except (ConnectionFailedError, IncorrectModeError):
            continue

        lockdown_ecid = int(str(lockdown.ecid), 0)
        if ecid is not None and lockdown_ecid != ecid:
            continue

        return Device(lockdown=lockdown)

    if ecid is None and udid_normalized is not None:
        raise RuntimeError(
            "Target UDID not available over usbmux in lockdownd mode and ECID is unset; "
            "set RESTORE_ECID for DFU/Recovery targeting"
        )

    return Device(irecv=IRecv(ecid=ecid))


async def cmd_usbmux_list(usb_only: bool) -> None:
    devices = await usbmux.list_devices()
    for device in devices:
        if usb_only and getattr(device, "connection_type", None) != "USB":
            continue
        serial = getattr(device, "serial", None)
        if serial:
            print(serial)


def wait_for_irecv(ecid: Optional[int], timeout: int, is_recovery: Optional[bool] = None) -> IRecv:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            return IRecv(ecid=ecid, timeout=2, is_recovery=is_recovery)
        except (IRecvNoDeviceConnectedError, ValueError):
            time.sleep(1)
    mode_label = "recovery" if is_recovery else "dfu/recovery"
    raise TimeoutError(f"Timed out waiting for {mode_label} endpoint")


def irecv_send_file(irecv: IRecv, image_path: Path) -> None:
    data = image_path.read_bytes()
    irecv.send_buffer(data)


def resolve_kernel_image(ramdisk_dir: Path) -> Path:
    ramdisk_variant = ramdisk_dir / "krnl.ramdisk.img4"
    if ramdisk_variant.exists():
        return ramdisk_variant
    default_kernel = ramdisk_dir / "krnl.img4"
    if default_kernel.exists():
        return default_kernel
    raise FileNotFoundError(f"Kernel image not found in {ramdisk_dir}")


def cmd_ramdisk_send(ecid: Optional[int], ramdisk_dir: Path, timeout: int) -> None:
    if not ramdisk_dir.is_dir():
        raise FileNotFoundError(f"Ramdisk directory not found: {ramdisk_dir}")

    kernel_img = resolve_kernel_image(ramdisk_dir)

    print(f"[*] Sending ramdisk from {ramdisk_dir}")
    if kernel_img.name == "krnl.ramdisk.img4":
        print("  [*] Using ramdisk kernel variant: krnl.ramdisk.img4")

    irecv = wait_for_irecv(ecid, timeout=timeout, is_recovery=False)

    # 1) DFU stage: iBSS + iBEC, then switch to recovery.
    print("  [1/8] Loading iBSS...")
    irecv_send_file(irecv, ramdisk_dir / "iBSS.vresearch101.RELEASE.img4")

    print("  [2/8] Loading iBEC...")
    irecv_send_file(irecv, ramdisk_dir / "iBEC.vresearch101.RELEASE.img4")
    irecv.send_command("go", b_request=1)
    time.sleep(1)

    print("  [*] Waiting for device to reconnect in recovery...")
    irecv = wait_for_irecv(ecid, timeout=timeout, is_recovery=True)
    print("  [*] Reconnected in recovery")

    # 2) Recovery stage payload chain.
    print("  [3/8] Loading SPTM...")
    irecv_send_file(irecv, ramdisk_dir / "sptm.vresearch1.release.img4")
    irecv.send_command("firmware")

    print("  [4/8] Loading TXM...")
    irecv_send_file(irecv, ramdisk_dir / "txm.img4")
    irecv.send_command("firmware")

    print("  [5/8] Loading trustcache...")
    irecv_send_file(irecv, ramdisk_dir / "trustcache.img4")
    irecv.send_command("firmware")

    print("  [6/8] Loading ramdisk...")
    irecv_send_file(irecv, ramdisk_dir / "ramdisk.img4")
    time.sleep(2)
    irecv.send_command("ramdisk")

    print("  [7/8] Loading device tree...")
    irecv_send_file(irecv, ramdisk_dir / "DeviceTree.vphone600ap.img4")
    irecv.send_command("devicetree")

    print("  [8/8] Loading SEP...")
    irecv_send_file(irecv, ramdisk_dir / "sep-firmware.vresearch101.RELEASE.img4")
    irecv.send_command("firmware")

    print("  [*] Booting kernel...")
    irecv_send_file(irecv, kernel_img)
    irecv.send_command("bootx", b_request=1)

    print("[+] Boot sequence complete. Device should be booting into ramdisk.")


def derive_shsh_output(vm_dir: Path, ecid: Optional[int]) -> Path:
    tag = f"{ecid:016X}" if ecid is not None else "auto"
    return vm_dir / f"{tag}.shsh"


async def cmd_restore_get_shsh(
    vm_dir: Path, ecid: Optional[int], udid: Optional[str], out: Optional[Path]
) -> None:
    restore_dir = find_restore_dir(vm_dir)
    ipsw = IPSW.create_from_path(str(restore_dir))
    device = await resolve_device(ecid, udid)
    tss = await Recovery(ipsw, device, behavior=Behavior.Erase).fetch_tss_record()

    out_path = out or derive_shsh_output(vm_dir, device.get_ecid_value())
    with out_path.open("wb") as handle:
        plistlib.dump(tss, handle)

    print(f"[+] SHSH saved: {out_path}")


async def cmd_restore_update(vm_dir: Path, ecid: Optional[int], udid: Optional[str], erase: bool) -> None:
    restore_dir = find_restore_dir(vm_dir)
    ipsw = IPSW.create_from_path(str(restore_dir))
    behavior = Behavior.Erase if erase else Behavior.Update
    device = await resolve_device(ecid, udid)
    await Restore(ipsw, device, behavior=behavior, ignore_fdr=False).update()


def require_ecid(value: str) -> Optional[int]:
    try:
        return parse_ecid(value)
    except ValueError as exc:
        raise typer.BadParameter(str(exc)) from exc


app = typer.Typer(help="pymobiledevice3 bridge for vphone", pretty_exceptions_enable=False)


@app.command("usbmux-list", help="List usbmux UDIDs")
def usbmux_list_command(
    usb_only: bool = typer.Option(
        True,
        "--usb-only/--no-usb-only",
        help="Include network devices with --no-usb-only.",
    ),
) -> Awaitable[None]:
    return cmd_usbmux_list(usb_only=usb_only)


@app.command("recovery-probe", help="Probe for DFU/recovery endpoint")
def recovery_probe_command(
    ecid: Optional[str] = typer.Option(None, help="Hex ECID (with/without 0x)"),
    timeout: int = typer.Option(2, help="Probe timeout in seconds"),
) -> None:
    parsed_ecid = require_ecid(ecid)
    wait_for_irecv(parsed_ecid, timeout=timeout)


@app.command("ramdisk-send", help="Send ramdisk chain over irecv")
def ramdisk_send_command(
    ecid: Optional[str] = typer.Option(None, help="Hex ECID (with/without 0x)"),
    timeout: int = typer.Option(90, help="Send timeout in seconds"),
    ramdisk_dir: Path = typer.Option(
        Path("Ramdisk"),
        help="Ramdisk directory",
        exists=False,
        file_okay=False,
        dir_okay=True,
    ),
) -> None:
    cmd_ramdisk_send(require_ecid(ecid), ramdisk_dir, timeout)


@app.command("restore-get-shsh", help="Fetch SHSH from prepared restore dir")
def restore_get_shsh_command(
    vm_dir: Path = typer.Option(
        Path("."),
        help="VM directory",
        exists=False,
        file_okay=False,
        dir_okay=True,
    ),
    ecid: Optional[str] = typer.Option(None, help="Hex ECID (with/without 0x)"),
    udid: Optional[str] = typer.Option(None, help="Target USB UDID"),
    out: Optional[Path] = typer.Option(
        None,
        help="Output SHSH path",
        exists=False,
        file_okay=True,
        dir_okay=False,
    ),
) -> Awaitable[None]:
    return cmd_restore_get_shsh(vm_dir, require_ecid(ecid), udid, out)


@app.command("restore-update", help="Run erase/update restore from prepared dir")
def restore_update_command(
    vm_dir: Path = typer.Option(
        Path("."),
        help="VM directory",
        exists=False,
        file_okay=False,
        dir_okay=True,
    ),
    ecid: Optional[str] = typer.Option(None, help="Hex ECID (with/without 0x)"),
    udid: Optional[str] = typer.Option(None, help="Target USB UDID"),
    erase: bool = typer.Option(True, "--erase/--no-erase", help="Run update-in-place with --no-erase."),
) -> Awaitable[None]:
    return cmd_restore_update(vm_dir, require_ecid(ecid), udid, erase=erase)


async def main(argv: list[str]) -> None:
    result = app(args=argv, prog_name="pymobiledevice3_bridge.py", standalone_mode=False)
    if inspect.isawaitable(result):
        await result


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:]))
