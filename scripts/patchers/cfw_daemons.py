"""Daemon injection and cryptex path helpers."""

import os
import plistlib
import subprocess
import sys

try:
    from . import cfw_records as records
except ImportError:  # direct self-test / standalone execution
    import cfw_records as records


DROPBEAR_KEY_ARGS = [
    "-r",
    "/var/dropbear/dropbear_rsa_host_key",
    "-r",
    "/var/dropbear/dropbear_ecdsa_host_key",
]

def parse_cryptex_paths(manifest_path):
    """Extract Cryptex DMG paths from BuildManifest.plist.

    Searches ALL BuildIdentities for:
    - Cryptex1,SystemOS -> Info -> Path
    - Cryptex1,AppOS -> Info -> Path

    vResearch IPSWs may have Cryptex entries in a non-first identity.
    """
    with open(manifest_path, "rb") as f:
        manifest = plistlib.load(f)

    # Search all BuildIdentities for Cryptex paths
    for bi in manifest.get("BuildIdentities", []):
        m = bi.get("Manifest", {})
        sysos = m.get("Cryptex1,SystemOS", {}).get("Info", {}).get("Path", "")
        appos = m.get("Cryptex1,AppOS", {}).get("Info", {}).get("Path", "")
        if sysos and appos:
            return sysos, appos

    print(
        "[-] Cryptex1,SystemOS/AppOS paths not found in any BuildIdentity",
        file=sys.stderr,
    )
    sys.exit(1)


# ══════════════════════════════════════════════════════════════════
# LaunchDaemon injection
# ══════════════════════════════════════════════════════════════════


def inject_daemons(plist_path, daemon_dir):
    """Inject bash/dropbear/trollvnc entries into launchd.plist."""
    # Snapshot before the plutil conversion: the Swift port replaces that step
    # too, so the reference input is the pristine binary plist.
    records.set_group("inject_daemons")
    before = records.snapshot_file(plist_path)

    # Convert to XML first (macOS binary plist -> XML)
    subprocess.run(["plutil", "-convert", "xml1", plist_path], capture_output=True)

    with open(plist_path, "rb") as f:
        target = plistlib.load(f)

    for name in ("bash", "dropbear", "trollvnc", "vphoned", "rpcserver_ios"):
        src = os.path.join(daemon_dir, f"{name}.plist")
        if not os.path.exists(src):
            print(f"  [!] Missing {src}, skipping")
            continue

        with open(src, "rb") as f:
            daemon = plistlib.load(f)

        if name == "dropbear":
            patch_dropbear_daemon(daemon)

        key = f"/System/Library/LaunchDaemons/{name}.plist"
        target.setdefault("LaunchDaemons", {})[key] = daemon
        print(f"  [+] Injected {name}")

    with open(plist_path, "wb") as f:
        plistlib.dump(target, f, sort_keys=False)

    records.record_after_write(
        plist_path, before, component="launchd.plist",
        patch_id="inject_daemons.launch_daemons",
        description="LaunchDaemons entries injected for bash/dropbear/trollvnc/vphoned/rpcserver_ios",
    )


def patch_dropbear_daemon(daemon):
    """Make dropbear use host keys on writable Data instead of read-only /etc."""
    args = list(daemon.get("ProgramArguments", []))
    if not args:
        return

    # -R generates default keys under /etc/dropbear, which is read-only during
    # normal VM boot. Use explicit /var/dropbear keys seeded by cfw_install.
    cleaned = []
    idx = 0
    while idx < len(args):
        arg = args[idx]
        if arg == "-R":
            idx += 1
            continue
        if arg == "-r":
            idx += 2
            continue
        cleaned.append(arg)
        idx += 1
    args = cleaned + DROPBEAR_KEY_ARGS
    daemon["ProgramArguments"] = args


def patch_dropbear_plist(plist_path):
    records.set_group("dropbear_plist")
    before = records.snapshot_file(plist_path)
    with open(plist_path, "rb") as f:
        daemon = plistlib.load(f)
    patch_dropbear_daemon(daemon)
    with open(plist_path, "wb") as f:
        plistlib.dump(daemon, f, sort_keys=False)
    records.record_after_write(
        plist_path, before, component="dropbear.plist",
        patch_id="dropbear_plist.host_keys",
        description="ProgramArguments rewritten to use /var/dropbear host keys",
    )
