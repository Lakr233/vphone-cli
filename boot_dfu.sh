#!/bin/zsh
# boot_dfu.sh — Build vphone-cli and boot the VM into DFU mode.
#
# Builds from the project directory, runs with VM files from CWD.
#
# Usage:
#   cd VM && ../boot_dfu.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"${SCRIPT_DIR}/build_and_sign.sh"

"${SCRIPT_DIR}/.build/release/vphone-cli" \
    --rom ./AVPBooter.vresearch1.bin \
    --disk ./Disk.img \
    --nvram ./nvram.bin \
    --cpu 4 \
    --memory 4096 \
    --serial-log ./serial.log \
    --stop-on-panic \
    --stop-on-fatal-error \
    --sep-rom ./AVPSEPBooter.vresearch1.bin \
    --sep-storage ./SEPStorage \
    --no-graphics \
    --dfu
