#!/bin/zsh
# common.sh — shared helpers for the custom-firmware-kit variant installers.
#
# Every function here is lifted from vphone-cli's scripts/cfw_install.sh so the
# two variants behave identically to the upstream installer on the code paths
# they keep. Do not "improve" them here — if upstream changes, re-sync.
#
# Contract expected by the callers (same as upstream cfw_install.sh):
#   - running as root, VM powered off
#   - CFW_HOST_CONTAINER set to the attached APFS container (e.g. disk4)
#   - cwd = the VM directory, $1 = the VM directory
#   - VPHONE_REPO points at a vphone-cli checkout (for the built binary and
#     the resources/ archives)

# ── Restore caller's PATH — Nix /etc/zshenv resets PATH on zsh startup ─
[[ -n "${_VPHONE_PATH:-}" ]] && export PATH="$_VPHONE_PATH"

die() {
    echo "[-] $*" >&2
    exit 1
}

warn() { echo "[!] $*" >&2; }

# ── Repo location ───────────────────────────────────────────────
# The kit does not fork the patchers; it calls the repo's `vphone-cli cfw`.
# The checkout marker is scripts/cfw_install.sh — the upstream installer this
# kit is derived from, and the one file whose absence really does mean "not a
# vphone-cli checkout". It is deliberately not the built binary: a fresh clone
# has no .build yet, and "run make build" is a better error than "wrong path".
resolve_repo() {
    local candidate="${VPHONE_REPO:-}"
    if [[ -z "$candidate" ]]; then
        # The kit now lives inside the checkout, so the enclosing directory is
        # the answer in the normal case. The other two are kept for running it
        # from outside a checkout, which is how it was developed.
        for c in "${KIT_DIR:h}" "$HOME/Documents/GitHub/Lakr233/vphone-cli" "${KIT_DIR:h}/vphone-cli"; do
            [[ -f "$c/scripts/cfw_install.sh" ]] && candidate="$c" && break
        done
    fi
    [[ -n "$candidate" ]] || die "VPHONE_REPO unset and no vphone-cli checkout found. Pass --repo <path>."
    [[ -f "$candidate/scripts/cfw_install.sh" ]] \
        || die "Not a vphone-cli checkout (no scripts/cfw_install.sh): $candidate"
    echo "${candidate:a}"
}

# ── vphone-cli resolver — every CFW patcher lives in the binary ─
# Same order as scripts/cfw_install_host.sh and run.sh: VPHONE_CLI_BIN when a
# vphone-cli subcommand invoked us, otherwise the repo's dev build or the .app,
# where the kit sits beside Contents/Resources and the binaries are one level
# up in MacOS. Never `command -v` — it has to be the binary built from this
# checkout, not whatever else is on PATH.
resolve_vphone_cli() {
    if [[ -n "${VPHONE_CLI_BIN:-}" ]]; then
        echo "$VPHONE_CLI_BIN"
        return
    fi
    local c
    for c in "$REPO_DIR/.build/release/vphone-cli" "${REPO_DIR:h}/MacOS/vphone-cli"; do
        [[ -x "$c" ]] && { echo "$c"; return }
    done
    echo "$REPO_DIR/.build/release/vphone-cli"   # report the expected path
}

cfw_cli() { "$VPHONE_CLI" cfw "$@"; }

# ── Signing ─────────────────────────────────────────────────────
require_signing_tools() {
    command -v ldid &>/dev/null \
        || die "ldid not found (brew install ldid-procursus). Run: make setup_tools"
}

ldid_sign() {
    local file="$1" bundle_id="${2:-}"
    local args=(-S -M "-K$VM_DIR/$CFW_INPUT/signcert.p12")
    [[ -n "$bundle_id" ]] && args+=("-I$bundle_id")
    ldid "${args[@]}" "$file"
}

# Like ldid_sign but re-applies an entitlements plist (for binaries whose
# entitlements must survive the re-sign).
ldid_sign_ent() {
    local file="$1" ent="$2" bundle_id="${3:-}"
    local args=("-S$ent" -M "-K$VM_DIR/$CFW_INPUT/signcert.p12")
    [[ -n "$bundle_id" ]] && args+=("-I$bundle_id")
    ldid "${args[@]}" "$file"
}

# ── Host image helpers ──────────────────────────────────────────
host_hdiutil() {
    local rc
    [[ -n "${SUDO_ASKPASS:-}" ]] && { sudo -A hdiutil "$@"; return; }
    hdiutil "$@" && return 0
    rc=$?
    if sudo -n true 2>/dev/null; then
        sudo hdiutil "$@"
        return
    fi
    return "$rc"
}

safe_detach() {
    local mnt="$1"
    if mount | grep -Fq " on $mnt "; then
        host_hdiutil detach -force "$mnt" 2>/dev/null || true
    fi
}

assert_mount_under_vm() {
    local mnt="$1" label="${2:-mountpoint}"
    local abs_vm abs_mnt
    abs_vm="$(cd "$VM_DIR" && pwd -P)"
    abs_mnt="$(cd "$mnt" && pwd -P)"
    case "$abs_mnt/" in
        "$abs_vm/"*) ;;
        *) die "Unsafe ${label}: ${abs_mnt} (must be inside ${abs_vm})" ;;
    esac
}

mount_vol() {  # mount_vol <slice, e.g. s1> <mountpoint> [opts]
    local dev="/dev/${CFW_HOST_CONTAINER}$1" mnt="$2" opts="${3:-rw}"
    /bin/mkdir -p "$mnt"
    /sbin/mount | /usr/bin/grep -q " on $mnt " && return 0
    /sbin/mount_apfs -o "$opts" "$dev" "$mnt" 2>/dev/null || true
    /sbin/mount | /usr/bin/grep -q " on $mnt " || die "mount failed: $dev -> $mnt"
}

find_restore_dir() {
    for dir in "$VM_DIR"/iPhone*_Restore; do
        [[ -f "$dir/BuildManifest.plist" ]] && echo "$dir" && return
    done
    die "No restore directory found in $VM_DIR"
}

setup_cfw_input() {
    [[ -d "$VM_DIR/$CFW_INPUT" ]] && return
    local archive
    for search_dir in "$REPO_DIR/scripts/resources" "$REPO_DIR/scripts" "$VM_DIR"; do
        archive="$search_dir/$CFW_ARCHIVE"
        if [[ -f "$archive" ]]; then
            echo "  Extracting $CFW_ARCHIVE..."
            "$TAR" --zstd --warning=no-unknown-keyword -xf "$archive" -C "$VM_DIR"
            return
        fi
    done
    die "Neither $CFW_INPUT/ nor $CFW_ARCHIVE found"
}

# ── Preflight ───────────────────────────────────────────────────
# Everything that can fail is checked BEFORE the first write to the volume.
# This is the only cheap protection against a half-modified guest volume:
# the installer is streaming and there is no snapshot to roll back to.
preflight() {
    local fatal=0

    command -v ipsw >/dev/null 2>&1 \
        || { warn "'ipsw' not found. Install: brew install blacktop/tap/ipsw"; fatal=1; }
    command -v aea  >/dev/null 2>&1 \
        || { warn "'aea' not found (requires macOS 12+)"; fatal=1; }
    command -v ldid >/dev/null 2>&1 \
        || { warn "'ldid' not found. Install: brew install ldid-procursus"; fatal=1; }

    # GNU tar: macOS bsdtar lacks --no-overwrite-dir / --warning=.
    if [[ ! -x "$TAR" ]]; then
        warn "GNU tar not found at '$TAR'. Install: brew install gnu-tar"; fatal=1
    fi
    # --zstd in GNU tar spawns an external zstd(1); it is NOT linked in.
    if [[ -x "$TAR" ]] && ! command -v zstd >/dev/null 2>&1; then
        warn "'zstd' not found — GNU tar's --zstd shells out to it. Install: brew install zstd"
        fatal=1
    fi

    if [[ ! -x "$VPHONE_CLI" ]]; then
        warn "vphone-cli not found (tried: $VPHONE_CLI) — build it with 'make build' in $REPO_DIR"
        fatal=1
    else
        # Every cfw subcommand this variant will call must exist up front. Ask
        # the binary, not a source file, by reading the verb list out of its own
        # help. Probing `cfw <sub> --help` looks tidier and is WRONG: swift
        # argument-parser intercepts --help anywhere in argv and prints the group
        # help with exit 0, so every name on earth "passes". And `cfw <sub>` with
        # no arguments cannot be used either — it exits 64 for a real verb
        # (missing argument) and 64 for a typo, and would actually RUN any verb
        # that happens to need no arguments.
        local -a have
        # (@f) on empty output yields one empty element, not an empty array, so
        # a count test never fires. Drop empties first — that is what makes the
        # "could not read the list" branch below reachable at all.
        have=(${(@f)"$("$VPHONE_CLI" cfw --help 2>&1 |
            awk '/^SUBCOMMANDS:/ {f = 1; next} f && /^  [a-z]/ {print $1}')"})
        have=(${have:#})
        if (( ${#have} == 0 )); then
            warn "could not read the subcommand list from '$VPHONE_CLI cfw --help'"
            fatal=1
        else
            local sub
            for sub in "${REQUIRED_CFW_SUBCOMMANDS[@]}"; do
                (( ${have[(I)$sub]} )) \
                    || { warn "vphone-cli has no 'cfw $sub' subcommand — binary too old or too new for this kit"; fatal=1; }
            done
        fi
    fi

    (( fatal == 0 )) || die "Preflight failed — nothing was written."
    echo "[+] preflight OK"
}

# ── Volume layout (set by the caller after sourcing) ────────────
init_paths() {
    : "${CFW_HOST_CONTAINER:?CFW_HOST_CONTAINER unset — run via run.sh or cfw_install_host.sh}"
    HOST_MNT="${CFW_HOST_MNT:-/private/tmp/cfwhost}"
    MNT1="$HOST_MNT/mnt1"   # disk1s1 (System / rootfs)
    MNT3="$HOST_MNT/mnt3"   # disk1s3
    TAR="$(command -v gtar 2>/dev/null || echo /opt/homebrew/bin/gtar)"
    mkdir -p "$HOST_MNT"
}

# Read the installed userland version off the mounted rootfs. Every
# version-gated patch below keys off this, exactly as upstream does.
read_ios_version() {
    /usr/bin/plutil -extract ProductVersion raw -o - \
        "$MNT1/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null || true
}

# Patch a rootfs binary from its pristine .bak, sign it, put it back.
# Upstream does this inline in four places; same semantics, one helper.
patch_rootfs_binary() {  # <relpath> <cfw subcommand> [bundle_id]
    local rel="$1" sub="$2" bundle_id="${3:-}"
    local live="$MNT1/$rel" bak="$MNT1/$rel.bak" work="$TEMP_DIR/${rel:t}"

    [[ -e "$live" || -e "$bak" ]] || die "missing on volume: /$rel"
    if ! [[ -e "$bak" ]]; then
        echo "  Creating backup of /$rel..."
        /bin/cp "$live" "$bak"
    fi
    /bin/cp "$bak" "$work"
    cfw_cli "$sub" "$work"
    ldid_sign "$work" "$bundle_id"
    /bin/cp -R "$work" "$live"
    /bin/chmod 0755 "$live"
}
