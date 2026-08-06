#!/bin/zsh
# Regression checks for the end-to-end `vm create --frida` install contract.

set -euo pipefail

HERE=${0:a:h}
ROOT=${HERE:h}

fail() {
    print -u2 -- "[-] $*"
    exit 1
}

require_text() {
    local file="$1"
    local text="$2"
    /usr/bin/grep -Fq -- "$text" "$file" || fail "$file is missing: $text"
}

reject_text() {
    local file="$1"
    local text="$2"
    if /usr/bin/grep -Fq -- "$text" "$file"; then
        fail "$file still contains obsolete logic: $text"
    fi
}

/bin/bash -n "$ROOT/scripts/vphone_jb_setup.sh"
/bin/zsh -n \
    "$ROOT/scripts/cfw_install_jb.sh" \
    "$ROOT/scripts/cfw_install_exp.sh"

require_text "$ROOT/sources/vphone-cli/VPhoneCreateOrchestrator.swift" \
    'if options.enableFrida { scriptEnv["VPHONE_FRIDA"] = "1" }'

for host_script in \
    "$ROOT/scripts/cfw_install_jb.sh" \
    "$ROOT/scripts/cfw_install_exp.sh"; do
    require_text "$host_script" 'URIs: https://build.frida.re/'
    require_text "$host_script" '.vphone_frida_enabled'
    reject_text "$host_script" 'fetch_frida_deb'
done

setup="$ROOT/scripts/vphone_jb_setup.sh"
require_text "$setup" "apt_source_contains 'build\\.frida\\.re'"
require_text "$setup" '[ -f /var/jb/.vphone_frida_enabled ]'
require_text "$setup" "dpkg-query -W -f='\${Status}' re.frida.server"
require_text "$setup" '[ "$TROLLSTORE_READY" = "1" ] && [ "$FRIDA_READY" = "1" ]'
require_text "$setup" 'required Frida package still pending, marker not written'
reject_text "$setup" "grep -rIl 'build.frida.re' /etc/apt /var/jb/etc/apt"
reject_text "$setup" 'Frida package setup done'

print -- '[+] Frida install-flow regression checks passed'
