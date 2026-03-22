#!/bin/bash
# fw_prepare.sh — Download/copy, merge, and generate hybrid restore firmware.
# Combines cloudOS boot chain with iPhone OS images for vresearch101.
#
# Accepts:
#   - direct iPhone IPSW URLs or local file paths
#   - version/build selectors for the target device
#   - listing of all downloadable IPSWs for the target device
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

source_hash_suffix() {
    local src="$1"
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$src" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$src" | sha256sum | awk '{print substr($1, 1, 12)}'
    else
        python3 - "$src" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest()[:12])
PY
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

list_firmwares() {
    local device="$1" readme_path="$2"
    local downloadable_urls
    downloadable_urls="$(downloadable_ipsw_urls "$device")"
    DOWNLOADABLE_IPSW_URLS="$downloadable_urls" python3 - "$device" "$readme_path" <<'PY'
import os
import re
import sys

device = sys.argv[1]
readme_path = sys.argv[2]

def supports_color(stream):
    return not os.environ.get("NO_COLOR") and (stream.isatty() or os.environ.get("CLICOLOR_FORCE") == "1")

def styled_status(status, stream):
    text = f"{status:<11}"
    if not supports_color(stream):
        return text
    colors = {
        "Supported": "\033[32m",
        "Not Tested": "\033[33m",
        "Unsupported": "\033[31m",
    }
    color = colors.get(status)
    return f"{color}{text}\033[0m" if color else text

def load_supported_pairs(readme_path, device):
    supported = set()
    device_suffix = device.removeprefix("iPhone")
    in_section = False
    try:
        with open(readme_path, "r", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("## Tested Environments"):
                    in_section = True
                    continue
                if in_section and line.startswith("## "):
                    break
                if not in_section:
                    continue
                for match in re.finditer(r"`(?P<device>\d+,\d+)_(?P<version>[^_`]+)_(?P<build>[A-Za-z0-9]+)`", line):
                    if match.group("device") == device_suffix:
                        supported.add((match.group("version"), match.group("build")))
    except FileNotFoundError:
        return supported
    return supported

supported_pairs = load_supported_pairs(readme_path, device)
rows = []
for line in os.environ.get("DOWNLOADABLE_IPSW_URLS", "").splitlines():
    match = re.search(
        rf"/({re.escape(device)}_(?P<version>[^_]+)_(?P<build>[A-Za-z0-9]+)_Restore\.ipsw)$",
        line.strip(),
    )
    if match:
        rows.append((match.group("version"), match.group("build"), line.strip()))

if not rows:
    print(f"No downloadable IPSWs found for {device}", file=sys.stderr)
    sys.exit(1)

def version_key(version):
    parts = []
    for item in version.split("."):
        try:
            parts.append(int(item))
        except ValueError:
            parts.append(item)
    return tuple(parts)

rows = sorted(set(rows), key=lambda row: (version_key(row[0]), row[1]), reverse=True)
print(f"Available downloadable IPSWs for {device}:")
print("")
print(
    "Status:",
    styled_status("Supported", sys.stdout),
    styled_status("Not Tested", sys.stdout),
    styled_status("Unsupported", sys.stdout),
)
print("")
print(f"{'VERSION':<12} {'BUILD':<10} STATUS")
for version, build, url in rows:
    status = "Supported" if (version, build) in supported_pairs else "Not Tested"
    print(f"{version:<12} {build:<10} {styled_status(status, sys.stdout)}")
PY
}

resolve_selector_from_downloads() {
    local device="$1" version="$2" build="$3" readme_path="$4"
    local downloadable_urls
    downloadable_urls="$(downloadable_ipsw_urls "$device")"
    DOWNLOADABLE_IPSW_URLS="$downloadable_urls" python3 - "$device" "$version" "$build" "$readme_path" <<'PY'
import os
import re
import sys

device, version, build, readme_path = sys.argv[1:5]

def supports_color(stream):
    return not os.environ.get("NO_COLOR") and (stream.isatty() or os.environ.get("CLICOLOR_FORCE") == "1")

def styled_status(status, stream):
    text = status
    if not supports_color(stream):
        return text
    colors = {
        "Supported": "\033[32m",
        "Not Tested": "\033[33m",
        "Unsupported": "\033[31m",
    }
    color = colors.get(status)
    return f"{color}{text}\033[0m" if color else text

def load_supported_pairs(readme_path, device):
    supported = set()
    device_suffix = device.removeprefix("iPhone")
    in_section = False
    try:
        with open(readme_path, "r", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("## Tested Environments"):
                    in_section = True
                    continue
                if in_section and line.startswith("## "):
                    break
                if not in_section:
                    continue
                for match in re.finditer(r"`(?P<device>\d+,\d+)_(?P<version>[^_`]+)_(?P<build>[A-Za-z0-9]+)`", line):
                    if match.group("device") == device_suffix:
                        supported.add((match.group("version"), match.group("build")))
    except FileNotFoundError:
        return supported
    return supported

supported_pairs = load_supported_pairs(readme_path, device)
matches = []
for line in os.environ.get("DOWNLOADABLE_IPSW_URLS", "").splitlines():
    match = re.search(
        rf"/({re.escape(device)}_(?P<version>[^_]+)_(?P<build>[A-Za-z0-9]+)_Restore\.ipsw)$",
        line.strip(),
    )
    if not match:
        continue
    entry_version = match.group("version")
    entry_build = match.group("build")
    if version and entry_version != version:
        continue
    if build and entry_build != build:
        continue
    matches.append((entry_version, entry_build, line.strip()))

if not matches:
    prefix = styled_status("Unsupported", sys.stderr)
    if version and build:
        print(f"{prefix}: no downloadable IPSW matched device={device} version={version} build={build}", file=sys.stderr)
    elif build:
        print(f"{prefix}: no downloadable IPSW matched device={device} build={build}", file=sys.stderr)
    else:
        print(f"{prefix}: no downloadable IPSW matched device={device} version={version}", file=sys.stderr)
    sys.exit(1)

if version and not build:
    builds = sorted({item[1] for item in matches})
    if len(builds) > 1:
        print(f"Version {version} is ambiguous for {device}; specify one of these builds:", file=sys.stderr)
        print(f"{'BUILD':<10} STATUS", file=sys.stderr)
        for item in sorted(set(matches), key=lambda row: row[1], reverse=True):
            status = "Supported" if (item[0], item[1]) in supported_pairs else "Not Tested"
            print(f"{item[1]:<10} {styled_status(status, sys.stderr)}", file=sys.stderr)
        sys.exit(2)

selected = sorted(set(matches), key=lambda row: row[1], reverse=True)[0]
status = "Supported" if (selected[0], selected[1]) in supported_pairs else "Not Tested"
print("\t".join(selected + (status,)))
PY
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
    local zip="$1" cache="$2" out="$3"
    if [[ -d "$cache" && -n "$(ls -A "$cache" 2>/dev/null)" ]]; then
        echo "==> Cached: ${cache##*/}"
    else
        rm -rf "$cache"
        echo "==> Extracting ${zip##*/} ..."
        mkdir -p "$cache"
        unzip -oq "$zip" -d "$cache"
        chmod -R u+w "$cache"
    fi
    rm -rf "$out"
    echo "==> Cloning ${cache##*/} → ${out##*/} ..."
    cp -R "$cache" "$out"
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
python3 "$SCRIPT_DIR/fw_manifest.py" "$IPHONE_DIR" "$CLOUDOS_DIR"

echo "==> Cleaning up ..."
rm -rf "$CLOUDOS_DIR"

echo "==> Done. Restore directory ready: $IPHONE_DIR/"
echo "    Run 'make fw_patch' to patch boot-chain components."
