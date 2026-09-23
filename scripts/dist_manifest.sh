#!/bin/zsh
# vphone-tier: build
# dist_manifest.sh — what goes into the .app, and nothing else.
#
# Three environments run code in this project, and they have different rules:
#
#   build   the machine that builds the .app. Xcode, `xcrun`, clang, swift, git
#           and the system are all fair game — CI installs them. Homebrew is
#           allowed here and nowhere else.
#   dist    the shipped .app, on a stranger's clean macOS. Only the system and
#           what is inside the bundle. No PATH lookups, no Homebrew, no Xcode.
#   guest   inside the VM. Not part of host self-containment at all; these files
#           ship as payload to be copied in, never run here.
#
# Every script declares which it is, on line 2:  `# vphone-tier: <tier>`
#
# This prints the dist payload — paths relative to scripts/, one per line, for
# `rsync -a --files-from=-`. It is an ALLOWLIST derived from those declarations,
# which is the point: the bundler used to work from a list of exclusions, so
# anything new shipped by default and `setup_tools.sh` (which runs `brew
# install`), `build.sh` and `check_aux.sh` all ended up inside the .app. An
# undeclared script now ships nowhere, and says so.
#
# Usage: dist_manifest.sh            # the payload, for rsync --files-from
#        dist_manifest.sh --tiers    # every script and its tier, for check_aux
set -euo pipefail

SCRIPT_DIR="${0:a:h}"
cd "$SCRIPT_DIR"

tier_of() {
    # Line 2 only. A tier declared further down would be a tier nobody reads
    # when they open the file.
    local declared rest
    declared=$(sed -n '2p' "$1")
    if [[ "$declared" == '# vphone-tier: '* ]]; then
        # First word only — a line may carry a trailing note, and cfw-kit's do.
        rest="${declared#\# vphone-tier: }"
        print -r -- "${rest%%[[:space:]]*}"
    else
        print -r -- "undeclared"
    fi
}

if [[ "${1:-}" == "--tiers" ]]; then
    for f in *.sh; do print -r -- "$f	$(tier_of "$f")"; done
    exit 0
fi

# Scripts: dist runs on the host, guest ships as payload for the VM.
for f in *.sh; do
    case "$(tier_of "$f")" in
        dist|guest) print -r -- "$f" ;;
    esac
done

# Payload that is not a script. Each line is here because a dist-tier script or
# vphone-cli itself opens it by name; the greppable proof is in the comment.
#
# What is deliberately ABSENT is as important:
#   repos/            toolchain submodules — build tier, sources only
#   tweakloader/ vpregister/ vcamcaptured/ camfix/   .m sources; the compiled
#                     artifacts ship in Contents/Resources/guest instead, so the
#                     install needs no iPhoneOS SDK
#   vphoned/*.m *.h vendor/ Makefile   same, and it is the bulk of scripts/
print -r -- "payloads/AppleParavirtGPUMetalIOGPUFamily.tar" # guest GPU driver
print -r -- "vphoned/vphoned.plist"         # LaunchDaemon plist, injectLaunchDaemons
print -r -- "vphoned/entitlements.plist"    # guest_sign_ent for vphoned
