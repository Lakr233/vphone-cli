#!/bin/zsh
# fetch_debs.sh — Download debs from a URL manifest into a cache dir.
# Skips files already cached; leaves manually-added debs alone. A failed
# download is reported and skipped, never fatal (always exits 0).
#
# Usage: fetch_debs.sh [cache_dir] [manifest_file]
#   defaults: <repo>/debs and <repo>/debs.list

set -uo pipefail

[[ -n "${_VPHONE_PATH:-}" ]] && export PATH="$_VPHONE_PATH"

SCRIPT_DIR="${0:a:h}"
REPO_ROOT="${SCRIPT_DIR:h}"

CACHE_DIR="${1:-$REPO_ROOT/debs}"
MANIFEST="${2:-$REPO_ROOT/debs.list}"

mkdir -p "$CACHE_DIR"

deb_filename_from_url() {
    local url="$1"
    url="${url%%\#*}"
    url="${url%%\?*}"
    print -r -- "${url##*/}"
}

downloaded=0
cached=0
failed=0

if [[ -f "$MANIFEST" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        name="$(deb_filename_from_url "$line")"
        if [[ "$name" != *.deb ]]; then
            echo "  [!] ERROR: URL does not resolve to a .deb filename, skipping: $line" >&2
            failed=$((failed + 1))
            continue
        fi

        dest="$CACHE_DIR/$name"
        if [[ -s "$dest" ]]; then
            echo "  [=] Cached: $name"
            cached=$((cached + 1))
            continue
        fi

        echo "  [>] Downloading: $line"
        tmp="$dest.download"
        if curl -fL --retry 2 --connect-timeout 20 \
                --speed-limit 1024 --speed-time 30 -o "$tmp" "$line"; then
            mv -f "$tmp" "$dest"
            echo "  [+] Downloaded: $name"
            downloaded=$((downloaded + 1))
        else
            rc=$?
            rm -f "$tmp"
            echo "  [!] ERROR: download failed (curl exit $rc), skipping: $line" >&2
            failed=$((failed + 1))
        fi
    done < "$MANIFEST"
else
    echo "  [=] No manifest at $MANIFEST (skipping downloads)"
fi

total=0
for f in "$CACHE_DIR"/*.deb(N); do
    total=$((total + 1))
done

echo "  [i] debs: $total in cache ($downloaded downloaded, $cached already cached, $failed failed)"

# Return the cache to the invoking user when run under sudo.
if [[ "$(id -u)" == "0" && -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER" "$CACHE_DIR" 2>/dev/null || true
fi

exit 0
