#!/bin/zsh
# base_stages.sh — the stages BOTH variants need, as functions.
#
# This is the "what does it take to boot at all" set. Nothing here installs a
# daemon, opens a port, or touches launchd.plist. Both vanilla and jb call
# these; jb then layers its own stages on top.
#
# Every function assumes lib/common.sh is already sourced and init_paths ran.

# ── Version detection ───────────────────────────────────────────
# Sets IOS_VERSION and DSC_DIR once, explicitly. Several stages key off
# IOS_VERSION; having one of them set it as a side effect made the stage order
# load-bearing in a way nothing enforced. Call this right after stage_cryptex —
# SystemVersion.plist only exists on the volume once the Cryptex is in place.
detect_ios_version() {
    IOS_VERSION=$(read_ios_version)
    DSC_DIR="$MNT1/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
    echo "  [*] userland version: ${IOS_VERSION:-unknown}"
    [[ -n "$IOS_VERSION" ]] \
        || warn "could not read ProductVersion — every version-gated fix below will be skipped"
}

# ── Cryptex SystemOS + AppOS ────────────────────────────────────
# Without this the hybrid firmware has a boot chain and no userland.
stage_cryptex() {
    echo ""
    echo "[base] Installing Cryptex (SystemOS + AppOS)..."

    echo "  Mounting rootfs rw..."
    mount_vol s1 "$MNT1"

    local os_count=0 app_count=0
    [[ -d "$MNT1/System/Cryptexes/OS" ]]  && os_count=$(/bin/ls "$MNT1/System/Cryptexes/OS/"  | /usr/bin/wc -l | tr -d ' ')
    [[ -d "$MNT1/System/Cryptexes/App" ]] && app_count=$(/bin/ls "$MNT1/System/Cryptexes/App/" | /usr/bin/wc -l | tr -d ' ')

    if [[ "${os_count:-0}" -gt 0 && "${app_count:-0}" -gt 0 ]]; then
        echo "  [*] Cryptexes already installed (OS=${os_count}, App=${app_count}), skipping copy"
        _link_dyld
        echo "  [+] Cryptex skipped (already present)"
        return
    fi

    local sysos_dmg="$TEMP_DIR/CryptexSystemOS.dmg"
    local appos_dmg="$TEMP_DIR/CryptexAppOS.dmg"
    local mnt_sysos="$TEMP_DIR/mnt_sysos"
    local mnt_appos="$TEMP_DIR/mnt_appos"

    if [[ ! -f "$sysos_dmg" ]]; then
        echo "  Extracting AEA key..."
        local aea_key
        aea_key=$(ipsw fw aea --key "$RESTORE_DIR/$CRYPTEX_SYSOS")
        echo "  Decrypting SystemOS..."
        aea decrypt -i "$RESTORE_DIR/$CRYPTEX_SYSOS" -o "$sysos_dmg" -key-value "$aea_key"
    else
        echo "  Using cached SystemOS DMG"
    fi

    if [[ ! -f "$appos_dmg" ]]; then
        cp "$RESTORE_DIR/$CRYPTEX_APPOS" "$appos_dmg"
    else
        echo "  Using cached AppOS DMG"
    fi

    safe_detach "$mnt_sysos"
    safe_detach "$mnt_appos"
    mkdir -p "$mnt_sysos" "$mnt_appos"
    assert_mount_under_vm "$mnt_sysos" "SystemOS mountpoint"
    assert_mount_under_vm "$mnt_appos" "AppOS mountpoint"

    echo "  Mounting SystemOS..."
    host_hdiutil attach -mountpoint "$mnt_sysos" "$sysos_dmg" -nobrowse -owners off \
        || die "Failed to mount SystemOS DMG. Run 'sudo -v' in a terminal and retry."
    echo "  Mounting AppOS..."
    host_hdiutil attach -mountpoint "$mnt_appos" "$appos_dmg" -nobrowse -owners off \
        || die "Failed to mount AppOS DMG. Run 'sudo -v' in a terminal and retry."

    /bin/rm -rf $MNT1/System/Cryptexes/App $MNT1/System/Cryptexes/OS
    /bin/mkdir -p $MNT1/System/Cryptexes/App $MNT1/System/Cryptexes/OS
    /bin/chmod 0755 $MNT1/System/Cryptexes/App $MNT1/System/Cryptexes/OS

    echo "  Copying Cryptexes..."
    cp -R "$mnt_sysos/." "$MNT1/System/Cryptexes/OS"
    cp -R "$mnt_appos/." "$MNT1/System/Cryptexes/App"

    echo "  Creating dyld symlinks..."
    _link_dyld

    echo "  Unmounting Cryptex DMGs..."
    safe_detach "$mnt_sysos"
    safe_detach "$mnt_appos"

    echo "  [+] Cryptex installed"
}

_link_dyld() {
    /bin/ln -sf ../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld \
        $MNT1/System/Library/Caches/com.apple.dyld
    /bin/ln -sf ../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld \
        $MNT1/System/DriverKit/System/Library/dyld
}

# ── Version-gated display / boot fixes ──────────────────────────
# NOT optional extras. Without the matching one the guest either shows a black
# screen on the host VZ view or panics at pid 1. Keyed off the installed
# userland version, exactly as upstream does.
#
# $1 = "1" to also apply the lsd embedded-registration gate. That one is the
# only genuinely JB-only patch in this stage: upstream's own comment
# (cfw_install.sh:348-351) says it exists so the iOS-27 `vpregister` first-boot
# tool can register JB app bundles, because uicache's
# registerApplicationDictionary is a no-op stub on 27. With no such tool
# installed it opens a path nothing walks.
#
# Reads IOS_VERSION / DSC_DIR; detect_ios_version must have run.
stage_display_and_boot_fixes() {
    local want_lsd_reg="${1:-0}"
    : "${IOS_VERSION?detect_ios_version has not run}"
    : "${DSC_DIR:?detect_ios_version has not run}"

    case "$IOS_VERSION" in
        26.0*|18.*)
            echo "  [*] Patching IOMobileFramebuffer SwapEnd payload size (-> 0x560)..."
            [[ -d "$DSC_DIR" ]] || die "dyld cache dir missing: $DSC_DIR"
            cfw_cli patch-iomfb-swapend "$DSC_DIR" --target-size 0x560
            ;;
        27.*)
            echo "  [*] Forcing IOMobileFramebuffer present onto the kern (method-5) path..."
            [[ -d "$DSC_DIR" ]] || die "dyld cache dir missing: $DSC_DIR"
            cfw_cli patch-iomfb-force-kern "$DSC_DIR"
            ;;
    esac

    case "$IOS_VERSION" in
        27.*)
            if [[ -d "$DSC_DIR" ]]; then
                # 27's cache + 512 MiB maxSlide overflows the 6 GiB shared region
                # -> dyld cannot map libSystem -> launchd (pid 1) panics.
                echo "  [*] Checking dyld cache maxSlide vs kernel shared region..."
                cfw_cli patch-dsc-maxslide "$DSC_DIR"
                # libxpc LWCR self-check crash-loops every daemon that pins an
                # entitlement peer-requirement under our code-signing setup.
                echo "  [*] Patching libxpc LWCR self-check..."
                cfw_cli patch-xpc-lwcr "$DSC_DIR"
                # missing MAC sysctl -> launchd abort.
                echo "  [*] Patching os_lockdown_mode_enabled..."
                cfw_cli patch-lockdown-mode "$DSC_DIR"

                if [[ "$want_lsd_reg" == "1" ]]; then
                    echo "  [*] Patching lsd embedded-registration gate..."
                    cfw_cli patch-lsd-embedded-reg "$DSC_DIR"
                else
                    echo "  [*] skip lsd embedded-registration gate (no JB registration tool)"
                fi
            fi
            ;;
        *)
            if [[ "${FORCE_DSC_MAXSLIDE:-0}" == "1" && -d "$DSC_DIR" ]]; then
                echo "  [*] Forcing dyld cache maxSlide=0 (opt-in FORCE_DSC_MAXSLIDE=1)..."
                cfw_cli patch-dsc-maxslide "$DSC_DIR" --force
            fi
            ;;
    esac
}

# ── seputil + gigalocker ────────────────────────────────────────
stage_seputil() {
    echo ""
    echo "[base] Patching seputil..."
    patch_rootfs_binary "usr/libexec/seputil" patch-seputil "com.apple.seputil"

    # diskimagesiod DDI mount-gate. NOT an extra and NOT jailbreak-specific:
    # upstream applies it in the plain regular variant too (cfw_install.sh:407),
    # because on a 27 userland MobileStorageMounter's waitForDAMount otherwise
    # hangs forever on the 26.4 hybrid. Version-gated exactly as upstream: on a
    # version-matched userland the native wait completes and forcing it to
    # return early could race the real mount.
    #
    # Entitlements (embedded sandbox profile + private DA/apfs) must survive the
    # re-sign, so this cannot use patch_rootfs_binary.
    case "$IOS_VERSION" in
        27.*)
            echo "  Patching diskimagesiod (DDI auto-mount, iOS $IOS_VERSION)..."
            if ! [[ -e "$MNT1/usr/libexec/diskimagesiod.bak" ]]; then
                /bin/cp "$MNT1/usr/libexec/diskimagesiod" "$MNT1/usr/libexec/diskimagesiod.bak"
            fi
            ldid -e "$MNT1/usr/libexec/diskimagesiod.bak" > "$TEMP_DIR/diskimagesiod.ent.plist"
            cp "$MNT1/usr/libexec/diskimagesiod.bak" "$TEMP_DIR/diskimagesiod"
            cfw_cli patch-diskimagesiod "$TEMP_DIR/diskimagesiod"
            ldid_sign_ent "$TEMP_DIR/diskimagesiod" "$TEMP_DIR/diskimagesiod.ent.plist" "com.apple.diskimagesiod"
            cp -R "$TEMP_DIR/diskimagesiod" "$MNT1/usr/libexec/diskimagesiod"
            /bin/chmod 0755 "$MNT1/usr/libexec/diskimagesiod"
            ;;
    esac

    echo "  Renaming gigalocker..."
    mount_vol s3 "$MNT3"
    mv "$MNT3"/*.gl(N) "$MNT3/AA.gl" 2>/dev/null || true

    echo "  [+] seputil patched"
}

# ── Paravirtual GPU bundle ──────────────────────────────────────
# Without it: backboardd crash loop / black SpringBoard.
# Provenance of the two binaries in here: see ../paravirt-gpu-provenance-kit.
stage_gpu() {
    echo ""
    echo "[base] Installing AppleParavirtGPUMetalIOGPUFamily..."

    local gpu_tar="$INPUT_DIR/custom/AppleParavirtGPUMetalIOGPUFamily.tar"
    [[ -f "$gpu_tar" ]] || die "GPU bundle missing: $gpu_tar"

    cp -R "$gpu_tar" "$MNT1"
    "$TAR" --preserve-permissions --no-overwrite-dir --warning=no-unknown-keyword \
        -xf $MNT1/AppleParavirtGPUMetalIOGPUFamily.tar -C $MNT1

    local bundle="$MNT1/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle"
    find $bundle -name '._*' -delete 2>/dev/null || true
    /usr/sbin/chown -R 0:0 $bundle
    /bin/chmod 0755 $bundle
    /bin/chmod 0755 $bundle/libAppleParavirtCompilerPluginIOGPUFamily.dylib
    /bin/chmod 0755 $bundle/AppleParavirtGPUMetalIOGPUFamily
    /bin/chmod 0755 $bundle/_CodeSignature
    /bin/chmod 0644 $bundle/_CodeSignature/CodeResources
    /bin/chmod 0644 $bundle/Info.plist
    /bin/rm -f $MNT1/AppleParavirtGPUMetalIOGPUFamily.tar

    echo "  [+] GPU driver installed"
}

# ── Activation bypass ───────────────────────────────────────────
# Without it the guest sits on the activation screen forever.
stage_mobileactivationd() {
    echo ""
    echo "[base] Patching mobileactivationd..."
    patch_rootfs_binary "usr/libexec/mobileactivationd" patch-mobileactivationd
    echo "  [+] mobileactivationd patched"
}

# ── launchd cache validation ────────────────────────────────────
# NOPs the cache validation check in launchd_cache_loader. Its ONLY purpose is
# to let launchd accept a MODIFIED /System/Library/xpc/launchd.plist
# (research/0_binary_patch_comparison.md row 2: "Allow modified launchd.plist").
#
# So it is NOT part of the base set: neither vanilla nor jb-with-an-empty-slot
# touches launchd.plist, and on a stock plist the stock validation passes.
# A userland flavour that injects a daemon into launchd.plist — which is what
# upstream cfw_install_jb.sh:459-471 does — MUST declare
# USERLAND_MODIFIES_LAUNCHD_PLIST=1, or the guest will boot with a plist
# launchd refuses to load.
stage_launchd_cache_loader() {
    echo ""
    echo "[base] Patching launchd_cache_loader (modified launchd.plist allowed)..."
    patch_rootfs_binary "usr/libexec/launchd_cache_loader" \
        patch-launchd-cache-loader "com.apple.launchd_cache_loader"
    echo "  [+] launchd_cache_loader patched"
}

# ── Teardown ────────────────────────────────────────────────────
stage_unmount() {
    echo ""
    echo "[*] Unmounting image volumes..."
    # Deliberately NOT umount -f: if something still holds a file on the volume
    # we want to hear about it, not paper over it.
    umount "$MNT1" 2>/dev/null || warn "could not unmount $MNT1 (still busy?)"
    umount "$MNT3" 2>/dev/null || true
    /bin/rm -rf "$TEMP_DIR/mnt_sysos" "$TEMP_DIR/mnt_appos"
}
