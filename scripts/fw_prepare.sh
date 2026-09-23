#!/bin/bash
# fw_prepare.sh — Download/copy, merge, and generate hybrid restore firmware.
# Combines cloudOS boot chain with iPhone OS images for vresearch101.
#
# Accepts:
#   - direct iPhone IPSW URLs or local file paths
#   - version/build selectors for the target device
#   - listing of all downloadable IPSWs for the target device
#   - The "VARIANT" environment variable to download apfs_sealvolume for the patchless mode
#
# Listing and selection are resolved through the `ipsw` CLI already used
# elsewhere in this repo, so the script can work with the full downloadable
# restore history instead of only Apple's current PMV asset set.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DEFAULT_IPHONE_DEVICE="iPhone17,3"
DEFAULT_IPHONE_SOURCE="https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipsw"
DEFAULT_CLOUDOS_SOURCE="https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349"
README_PATH="${SCRIPT_DIR}/../README.md"

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [iphone_source_or_selector] [cloudos_source]
  $(basename "$0") --list [--device iPhone17,3]
  $(basename "$0") --version 26.3.1 [--device iPhone17,3] [--cloudos-source URL_OR_PATH]
  $(basename "$0") --build 23D9133 [--device iPhone17,3] [--cloudos-source URL_OR_PATH]

Examples:
  $(basename "$0") --list
  $(basename "$0") 26.3.1
  $(basename "$0") --build 23D9133
  $(basename "$0") /path/to/iPhone17,3_26.1_23B85_Restore.ipsw

Environment variables:
  LIST_FIRMWARES  Set to 1 to list downloadable IPSWs and exit
  IPHONE_DEVICE   Device identifier for IPSW lookup (default: ${DEFAULT_IPHONE_DEVICE})
  IPHONE_VERSION  iOS version shorthand to resolve to a downloadable IPSW URL
  IPHONE_BUILD    Build shorthand to resolve to a downloadable IPSW URL
  IPHONE_SOURCE   Direct iPhone IPSW URL or local path
  CLOUDOS_SOURCE  Direct cloudOS IPSW URL or local path
  IPSW_DIR        Directory used to cache downloaded/copied IPSWs
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

is_local() {
    [[ "$1" != http://* && "$1" != https://* ]]
}

looks_like_source() {
    local value="$1"
    [[ "$value" == http://* || "$value" == https://* || "$value" == *.ipsw || "$value" == */* || -f "$value" ]]
}

looks_like_build() {
    [[ "$1" =~ ^[0-9]{2}[A-Z][0-9A-Z]+$ ]]
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found"
}

# Locate one of this project's own binaries (vphone-cli, vphone-archive).
# Same resolution order as scripts/cfw_install_host.sh and cfw-kit/run.sh:
# VPHONE_CLI_BIN when a vphone-cli subcommand invoked us — the wanted binary is
# its sibling — otherwise a dev tree or the .app, where scripts/ sits in
# Contents/Resources and the binaries are one level up in MacOS. Deliberately
# not `command -v`: these have to be the binaries we built, not another copy
# that happens to be on PATH. Prints the path; returns non-zero when it finds
# nothing, so the caller can `die` with something a user can act on.
resolve_vphone_binary() {
    local name="$1" proj_root candidate
    proj_root="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [[ -n "${VPHONE_CLI_BIN:-}" ]]; then
        candidate="$(dirname "$VPHONE_CLI_BIN")/$name"
        [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    fi
    for candidate in "$proj_root/.build/release/$name" "$(dirname "$proj_root")/MacOS/$name"; do
        [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

# Only ever used to name a cache file, so a short hash is enough. There used to
# be a Python third branch here for hosts with neither tool; shasum ships with
# macOS system Perl and this project is macOS-only, so it could not run.
source_hash_suffix() {
    local src="$1"
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$src" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$src" | sha256sum | awk '{print substr($1, 1, 12)}'
    else
        die "neither 'shasum' nor 'sha256sum' found — cannot derive a cache name"
    fi
}

derive_cache_ipsw_name() {
    local src="$1" fallback_stem="$2"
    local base stem suffix
    base="${src##*/}"
    base="${base%%\?*}"
    base="${base%%\#*}"

    if [[ "$base" == *.ipsw ]]; then
        printf '%s\n' "$base"
        return
    fi

    stem="${base%.*}"
    [[ -n "$stem" ]] || stem="$fallback_stem"
    stem="$(printf '%s' "$stem" | tr -cs '[:alnum:]_.-' '_')"
    [[ -n "$stem" ]] || stem="$fallback_stem"
    if [[ ${#stem} -gt 48 ]]; then
        stem="${stem:0:48}"
    fi

    suffix="$(source_hash_suffix "$src")"
    printf '%s-%s.ipsw\n' "$stem" "$suffix"
}

downloadable_ipsw_urls() {
    local device="$1"
    require_command ipsw
    ipsw download ipsw --device "$device" --urls
}

supports_color() {
    [[ -z "${NO_COLOR:-}" ]] && { [[ -t 1 ]] || [[ "${CLICOLOR_FORCE:-0}" == "1" ]]; }
}

style_status() {
    local status="$1"
    if ! supports_color; then
        printf '%s' "$status"
        return
    fi
    case "$status" in
        Supported)
            printf '\033[32m%s\033[0m' "$status"
            ;;
        "Not Tested")
            printf '\033[33m%s\033[0m' "$status"
            ;;
        Unsupported)
            printf '\033[31m%s\033[0m' "$status"
            ;;
        *)
            printf '%s' "$status"
            ;;
    esac
}

# The firmware support matrix — the README's "Tested Environments" table joined
# against what Apple still serves — lives in VPhoneCore/VPhoneFirmwareMatrix.swift
# now. The shell keeps the half it is good at: running `ipsw` and handing the
# output over in DOWNLOADABLE_IPSW_URLS, the same variable the Python read, so
# the contract between the two halves did not change.
#
# Colour is decided per stream inside the callee, from NO_COLOR, CLICOLOR_FORCE
# and isatty: `fw list` styles stdout, `fw resolve` styles stderr (its stdout is
# the $( ) capture below). That only stays right because the binary inherits
# this script's descriptors — do not add a pipe or a tee.
firmware_matrix_cli() {
    resolve_vphone_binary vphone-cli \
        || die "cannot find vphone-cli for the firmware matrix — run 'make build'"
}

list_firmwares() {
    local device="$1" readme_path="$2" cli downloadable_urls
    # Separate from `local`, which would swallow the substitution's status.
    cli="$(firmware_matrix_cli)"
    downloadable_urls="$(downloadable_ipsw_urls "$device")"
    DOWNLOADABLE_IPSW_URLS="$downloadable_urls" \
        "$cli" fw list --device "$device" --readme "$readme_path"
}

resolve_selector_from_downloads() {
    local device="$1" version="$2" build="$3" readme_path="$4" cli downloadable_urls
    cli="$(firmware_matrix_cli)"
    downloadable_urls="$(downloadable_ipsw_urls "$device")"
    DOWNLOADABLE_IPSW_URLS="$downloadable_urls" \
        "$cli" fw resolve --device "$device" --version "$version" \
        --build "$build" --readme "$readme_path"
}

download_file() {
    local src="$1" out="$2"
    if command -v aria2c >/dev/null 2>&1; then
        # aria2c: fast multi-connection downloader
        # -x16: max 16 connections per server
        # -s16: split into 16 parts
        # -k1M: min split size 1MB
        # -c: continue/resume download
        # --allow-overwrite=true: overwrite existing file
        # --auto-file-renaming=false: don't rename automatically
        local dir="${out%/*}"
        local file="${out##*/}"
        [[ -n "$dir" && "$dir" != "$out" ]] || dir="."
        aria2c \
            --allow-overwrite=true \
            --auto-file-renaming=false \
            -x 16 \
            -s 16 \
            -k 1M \
            -c \
            -d "$dir" \
            -o "$file" \
            "$src"
    elif command -v curl >/dev/null 2>&1; then
        local rc=0
        curl --fail --location --progress-bar -C - -o "$out" "$src" || rc=$?
        # 33 = HTTP range error — typically means file is already fully downloaded
        [[ $rc -eq 33 ]] && return 0
        return $rc
    elif command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate --show-progress -c -O "$out" "$src"
    else
        die "Need 'aria2c', 'curl' or 'wget' to download $src"
    fi
}

fetch() {
    local src="$1" out="$2"
    if [[ -f "$out" ]]; then
        if is_local "$src"; then
            echo "==> Skipping: '$out' already exists."
            return
        fi
        # File exists — could be partial (interrupted) or complete.
        # Attempt to resume; curl -C - is a no-op on a fully-downloaded file.
        local local_size
        local_size=$(wc -c < "$out" | tr -d ' ')
        echo "==> Found existing ${out##*/} (${local_size} bytes), resuming ..."
        local rc=0
        download_file "$src" "$out" || rc=$?
        if [[ $rc -eq 0 ]]; then
            return
        fi
        # curl exit 22 = HTTP error; with -C - on a complete file the server
        # returns 416 which --fail maps to exit 22.  Verify via content-length.
        if [[ $rc -eq 22 ]]; then
            local remote_size
            remote_size=$(curl -sI --location "$src" | awk 'tolower($1)=="content-length:"{v=$2} END{print v}' | tr -d '\r')
            if [[ -n "$remote_size" && "$local_size" -ge "$remote_size" ]]; then
                echo "==> Already fully downloaded (${local_size} bytes)."
                return
            fi
        fi
        echo "==> Resume failed; retrying full download ..."
        rm -f "$out"
    fi
    if is_local "$src"; then
        [[ -f "$src" ]] || die "Local IPSW not found: $src"
        echo "==> Copying ${src##*/} ..."
        cp "$src" "$out"
    else
        echo "==> Downloading ${out##*/} ..."
        if ! download_file "$src" "$out"; then
            # Keep partial file on disk so the next run can resume
            die "Failed to download '$src'"
        fi
    fi
}

extract() {
    local zip="$1" cache="$2" out="$3" archive_bin
    if [[ -d "$cache" && -n "$(ls -A "$cache" 2>/dev/null)" ]]; then
        echo "==> Cached: ${cache##*/}"
    else
        rm -rf "$cache"
        echo "==> Extracting ${zip##*/} ..."
        mkdir -p "$cache"
        # vphone-archive instead of unzip: libarchive in-process, measured at
        # 0.75s against unzip's 4.97s on a real 1.2 GB IPSW, with identical
        # output — 88 files, 10 dirs, every content digest and mode matching.
        # The extractor's host preset applies the umask and never restores
        # setuid, which is what `unzip` did here, and the cache directory is
        # freshly removed above so there is nothing to overwrite (`unzip -o`).
        archive_bin="$(resolve_vphone_binary vphone-archive)" \
            || die "vphone-archive not found — run 'make build'"
        "$archive_bin" extract -f "$zip" -C "$cache"
        chmod -R u+w "$cache"
    fi
    rm -rf "$out"
    echo "==> Cloning ${cache##*/} → ${out##*/} ..."
    # -c makes this an APFS clone, which is what the line above already claims
    # it is. Without it a full second copy of the extracted IPSW is written —
    # ~11.5 GB for an iPhone restore — on top of the .ipsw and the cache, and
    # the patchers then rewrite only a handful of files out of it. Cloning is
    # copy-on-write, so the bytes are shared until something changes them.
    # Falls back to copyfile(2) where the target cannot be cloned, so this is
    # safe off APFS too.
    cp -Rc "$cache" "$out"
}

download_apfs_sealvolume() {
    local src="$1"
    local base ios_version filename PROJECT_DIR TOOLS_PREFIX TMP_DIR bn ver BUILD BUILD_MANIFEST RAMDISK_PATH RAMDISK_IM4P RAMDISK MOUNT

    base="$(basename "$src")"
    ios_version="$(awk -F_ 'NF >= 2 { print $2 }' <<<"$base")"

    if [[ -z "$ios_version" ]]; then
        echo "Error: could not determine iOS version from filename: $base" >&2
        return 1
    fi

    filename="apfs_sealvolume_${ios_version}"
    
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    TOOLS_PREFIX="${VPHONE_SEAL_DIR:-$PROJECT_DIR/.tools}"
    mkdir -p "$TOOLS_PREFIX"

    if [[ -f "$TOOLS_PREFIX/$filename" ]]; then
        echo "$filename already present"
    else
        echo "Downloading $filename"
        (
            TMP_DIR="$(mktemp -d)"
            trap 'rm -rf "$TMP_DIR"' EXIT
            
            # List matching macOS version to the iOS version
            while IFS= read -r url; do
                bn="$(basename "$url")"
                ver="${bn#*_}"
                ver="${ver%%_*}"

                [[ "$ver" == "$ios_version" ]] || continue

                BUILD="$(awk -F_ '{print $3}' <<<"$bn")"
                break
            done < <(
              ipsw download appledb \
              --os macOS \
              --version $ios_version \
              --urls
            )
            
            if [[ -z "${BUILD:-}" ]]; then
                echo "Error: failed to determine macOS build from available URLs" >&2
                          exit 1
            fi
            
            # Download BuildManifest first
            ipsw download appledb \
              --os macOS \
              --build $BUILD \
              --pattern "^BuildManifest.plist\$" \
              --output "$TMP_DIR"
            
            BUILD_MANIFEST="$(find "$TMP_DIR" -name BuildManifest.plist -print -quit)"
            if [ -z "$BUILD_MANIFEST" ]; then
              echo "Failed to locate BuildManifest.plist"
              exit 1
            fi
            
            RAMDISK_PATH="$(/usr/bin/plutil -extract 'BuildIdentities.0.Manifest.RestoreRamDisk.Info.Path' raw -o - "$BUILD_MANIFEST")"
            if [ -z "$RAMDISK_PATH" ]; then
              echo "Failed to read RestoreRamDisk path from BuildManifest"
              exit 1
            fi
            
            # Download the ramdisk referenced by BuildManifest
            ipsw download appledb \
              --os macOS \
              --build $BUILD \
              --pattern "$RAMDISK_PATH" \
              --output "$TMP_DIR"

            RAMDISK_IM4P="$(find "$TMP_DIR" -path "*${RAMDISK_PATH}" -print -quit)"
            if [ -z "$RAMDISK_IM4P" ]; then
              echo "Failed to locate downloaded ramdisk: $RAMDISK_PATH"
              exit 1
            fi

            RAMDISK="$TMP_DIR/ramdisk.dmg"
            ipsw img4 im4p extract --output "$RAMDISK" "$RAMDISK_IM4P"

            MOUNT=$(hdiutil attach -readonly -nobrowse "$RAMDISK" | awk 'END{ print$NF}')
            cp "$MOUNT/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_sealvolume" \
            "$TOOLS_PREFIX/$filename"
            hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
        )
        echo "  Downloaded: $TOOLS_PREFIX/$filename"
        echo "  Resigning $filename"
        codesign --force --sign - "$TOOLS_PREFIX/$filename"
    fi
}

LIST_FIRMWARES="${LIST_FIRMWARES:-0}"
IPHONE_DEVICE="${IPHONE_DEVICE:-$DEFAULT_IPHONE_DEVICE}"
IPHONE_VERSION="${IPHONE_VERSION:-}"
IPHONE_BUILD="${IPHONE_BUILD:-}"
IPHONE_SOURCE="${IPHONE_SOURCE:-}"
CLOUDOS_SOURCE="${CLOUDOS_SOURCE:-}"
IPSW_DIR="${IPSW_DIR:-${SCRIPT_DIR}/../ipsws}"

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            LIST_FIRMWARES=1
            shift
            ;;
        --device)
            [[ $# -ge 2 ]] || die "--device requires a value"
            IPHONE_DEVICE="$2"
            shift 2
            ;;
        --version)
            [[ $# -ge 2 ]] || die "--version requires a value"
            IPHONE_VERSION="$2"
            shift 2
            ;;
        --build)
            [[ $# -ge 2 ]] || die "--build requires a value"
            IPHONE_BUILD="$2"
            shift 2
            ;;
        --iphone-source)
            [[ $# -ge 2 ]] || die "--iphone-source requires a value"
            IPHONE_SOURCE="$2"
            shift 2
            ;;
        --cloudos-source)
            [[ $# -ge 2 ]] || die "--cloudos-source requires a value"
            CLOUDOS_SOURCE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                POSITIONAL+=("$1")
                shift
            done
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [[ ${#POSITIONAL[@]} -gt 2 ]]; then
    die "Too many positional arguments"
fi

if [[ -z "$IPHONE_SOURCE" && -z "$IPHONE_VERSION" && -z "$IPHONE_BUILD" && ${#POSITIONAL[@]} -ge 1 ]]; then
    if looks_like_source "${POSITIONAL[0]}"; then
        IPHONE_SOURCE="${POSITIONAL[0]}"
    elif looks_like_build "${POSITIONAL[0]}"; then
        IPHONE_BUILD="${POSITIONAL[0]}"
    else
        IPHONE_VERSION="${POSITIONAL[0]}"
    fi
fi

if [[ -z "$CLOUDOS_SOURCE" && ${#POSITIONAL[@]} -ge 2 ]]; then
    CLOUDOS_SOURCE="${POSITIONAL[1]}"
fi

if [[ "$LIST_FIRMWARES" == "1" ]]; then
    list_firmwares "$IPHONE_DEVICE" "$README_PATH"
    exit 0
fi

if [[ -n "$IPHONE_SOURCE" && ( -n "$IPHONE_VERSION" || -n "$IPHONE_BUILD" ) ]]; then
    die "Use either IPHONE_SOURCE or version/build selection, not both"
fi

if [[ -n "$IPHONE_VERSION" || -n "$IPHONE_BUILD" ]]; then
    selection="$(resolve_selector_from_downloads "$IPHONE_DEVICE" "$IPHONE_VERSION" "$IPHONE_BUILD" "$README_PATH")" || {
        status=$?
        [[ $status -eq 2 ]] && exit 2
        exit "$status"
    }
    IFS=$'\t' read -r selected_version selected_build selected_url selected_status <<<"$selection"
    IPHONE_SOURCE="$selected_url"
    echo "==> Selected downloadable firmware:"
    echo "    Device:  $IPHONE_DEVICE"
    echo "    Version: $selected_version"
    echo "    Build:   $selected_build"
    echo "    URL:     $selected_url"
    echo "    Status:  $(style_status "$selected_status")"
fi

IPHONE_SOURCE="${IPHONE_SOURCE:-$DEFAULT_IPHONE_SOURCE}"
CLOUDOS_SOURCE="${CLOUDOS_SOURCE:-$DEFAULT_CLOUDOS_SOURCE}"

mkdir -p "$IPSW_DIR"

IPHONE_IPSW="${IPHONE_SOURCE##*/}"
IPHONE_DIR="${IPHONE_IPSW%.ipsw}"
CLOUDOS_IPSW="$(derive_cache_ipsw_name "$CLOUDOS_SOURCE" "pcc-base")"
CLOUDOS_DIR="${CLOUDOS_IPSW%.ipsw}"
IPHONE_IPSW_PATH="${IPSW_DIR}/${IPHONE_IPSW}"
CLOUDOS_IPSW_PATH="${IPSW_DIR}/${CLOUDOS_IPSW}"

echo "=== prepare_firmware ==="
echo "  Device:   $IPHONE_DEVICE"
echo "  iPhone:   $IPHONE_SOURCE"
echo "  CloudOS:  $CLOUDOS_SOURCE"
echo "  IPSWs:    $IPSW_DIR"
echo "  Output:   $(pwd)/$IPHONE_DIR/"
echo ""

fetch "$IPHONE_SOURCE" "$IPHONE_IPSW_PATH"
fetch "$CLOUDOS_SOURCE" "$CLOUDOS_IPSW_PATH"

VARIANT="${VARIANT:-}"
if [[ "$VARIANT" == "less" ]]; then
    download_apfs_sealvolume "$IPHONE_SOURCE"
else
    echo "==> Downloading apfs sealvolume (skipped — patchless variant only)"
fi

IPHONE_CACHE="${IPSW_DIR}/${IPHONE_DIR}"
CLOUDOS_CACHE="${IPSW_DIR}/${CLOUDOS_DIR}"

extract "$IPHONE_IPSW_PATH" "$IPHONE_CACHE" "$IPHONE_DIR"
extract "$CLOUDOS_IPSW_PATH" "$CLOUDOS_CACHE" "$CLOUDOS_DIR"

# Keep exactly one active restore tree in the working directory so fw_patch
# cannot accidentally pick a stale older firmware directory.
cleanup_old_restore_dirs() {
    local keep="$1"
    local found=0
    shopt -s nullglob
    for dir in *Restore*; do
        [[ -d "$dir" ]] || continue
        [[ "$dir" == "$keep" ]] && continue
        if [[ $found -eq 0 ]]; then
            echo "==> Removing stale restore directories ..."
            found=1
        fi
        echo "    rm -rf $dir"
        rm -rf "$dir"
    done
    shopt -u nullglob
}
cleanup_old_restore_dirs "$IPHONE_DIR"

echo "==> Importing cloudOS firmware components ..."

cp "${CLOUDOS_DIR}"/kernelcache.* "$IPHONE_DIR"/

for sub in agx all_flash ane dfu pmp; do
    cp "${CLOUDOS_DIR}/Firmware/${sub}"/* "$IPHONE_DIR/Firmware/${sub}"/
done

cp "${CLOUDOS_DIR}"/Firmware/*.im4p "$IPHONE_DIR/Firmware"/

cp -n "${CLOUDOS_DIR}"/*.dmg "$IPHONE_DIR"/ 2>/dev/null || true
cp -n "${CLOUDOS_DIR}"/Firmware/*.dmg.trustcache "$IPHONE_DIR/Firmware"/ 2>/dev/null || true

cp "$IPHONE_DIR/BuildManifest.plist" "$IPHONE_DIR/iPhone-BuildManifest.plist"

echo "==> Generating hybrid plists ..."
VPHONE_CLI="$(resolve_vphone_binary vphone-cli)" \
    || die "cannot find vphone-cli to generate the hybrid plists — run 'make build'"
"$VPHONE_CLI" fw manifest "$IPHONE_DIR" "$CLOUDOS_DIR"

echo "==> Cleaning up ..."
rm -rf "$CLOUDOS_DIR"

# Drop the extracted base-IPSW caches (kept .ipsw re-extracts). VPHONE_KEEP_ARTIFACTS opts out.
if [[ -z "${VPHONE_KEEP_ARTIFACTS:-}" ]]; then
    hybrid="$(cd "$IPHONE_DIR" && pwd -P)"
    for cache in "$IPHONE_CACHE" "$CLOUDOS_CACHE"; do
        [[ -d "$cache" && "$(cd "$cache" && pwd -P)" != "$hybrid" ]] && rm -rf "$cache"
    done
fi

echo "==> Done. Restore directory ready: $IPHONE_DIR/"
echo "    Run 'make fw_patch' to patch boot-chain components."
