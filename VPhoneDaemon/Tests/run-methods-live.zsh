#!/usr/bin/env zsh
# MANUAL live-guest check of the vphoned methods catalog and central force gate.
# NOT part of the guest-independent suite: it needs a VM, so run it by hand:
#   zsh VPhoneDaemon/Tests/run-methods-live.zsh
# Prerequisites (this script builds nothing and never runs sudo): the VPhone bundle is built
# (AGENTS.md Quick Reference: the xcodebuild line) and the operator has AMFI-allowlisted its vphone-vm.
# Configuration:
#   VPHONE_BUNDLE       path of VPhone.bundle; default <repo>/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle;
#                       a path without Contents/MacOS/vphone-cli -> UNAVAILABLE, exit 2
#   VPHONE_VM           VM name to launch; default the first free VM from `vm list`; a running VM -> exit 2,
#                       an unknown name -> `vm launch` exits -> UNAVAILABLE, exit 2
#   VPHONE_LIBRARY_ROOT VM library (default ~/.vphone/machines) read to accept `vm list` names
#   port                fixed 127.0.0.1:8765; something already listening -> UNAVAILABLE, exit 2
# A per-run token travels only in the environment (VPHONE_API_TOKEN) and a 0600 header file for the HTTP client.
# The EXIT trap (also run on INT/TERM) removes the header files and stops the VM this run launched (health
# answered, or its launch job still booting); a VM this run did not launch is never stopped.
# VM names must match ^[A-Za-z0-9._-]+$ (else UNAVAILABLE, exit 2).
# Output: `PASS <check>` or `FAIL <check>: expected <x> got <y>` per check, then the last two lines
#   live: <n> checks, <f> failures
#   TOTAL_FAILS=<f>
# Exit: 0 all checks pass, 1 a check failed (or an unforced destructive call was not refused), 2 guest
# unavailable (prints `UNAVAILABLE: <reason>`).
set -eu

root=${0:a:h:h:h}
cd "$root"
bundle=${VPHONE_BUNDLE:-$root/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle}
cli=$bundle/Contents/MacOS/vphone-cli
lib=${VPHONE_LIBRARY_ROOT:-$HOME/.vphone/machines}
addr=127.0.0.1:8765
mkdir -p .build; log=$root/.build/methods-vm.log
tests=$root/VPhoneDaemon/Tests/run-methods-tests.sh
n_specs=$(zsh "$tests" --specs | wc -l | tr -d ' ')
n_forces=$(zsh "$tests" --forces | wc -l | tr -d ' ')
# The daemon answers 200, or 400 for a handler error (APIWire.swift); 401/403 are refusals before the daemon.
daemon_status() { case $1 in 200|400) return 0 ;; *) return 1 ;; esac; }
[ -x "$cli" ] || { echo "UNAVAILABLE: no built bundle at $bundle; build the bundle (AGENTS.md Quick Reference) or set VPHONE_BUNDLE"; exit 2; }
"$cli" host preflight >/dev/null 2>&1 || { echo "UNAVAILABLE: preflight failed; operator must run: sudo $bundle/Contents/MacOS/vphone-escalator allow $bundle/Contents/MacOS/vphone-vm"; exit 2; }

is_running() { pgrep -fl vphone-vm | grep -qF "$lib/$1/"; }
valid_name() { print -r -- "$1" | grep -qE '^[A-Za-z0-9._-]+$'; }
vm=${VPHONE_VM:-}
if [ -z "$vm" ]; then
  for n in $("$cli" vm list 2>/dev/null | awk '{print $1}' || true); do
    valid_name "$n" || continue
    [ -f "$lib/$n/config.plist" ] || continue
    if ! is_running "$n"; then vm=$n; break; fi
  done
fi
[ -n "$vm" ] || { echo "UNAVAILABLE: no free VM; stop one or set VPHONE_VM"; exit 2; }
valid_name "$vm" || { echo "UNAVAILABLE: invalid VM name '$vm'; use only letters, digits, . _ - in VPHONE_VM"; exit 2; }
echo vm=$vm
# A running VM is never used or stopped, including one named by $VPHONE_VM.
if is_running "$vm"; then echo "UNAVAILABLE: $vm is running; stop it or set VPHONE_VM to another VM"; exit 2; fi
if nc -z 127.0.0.1 8765 >/dev/null 2>&1; then echo "UNAVAILABLE: port 8765 in use; stop the process holding it"; exit 2; fi

token=$(openssl rand -hex 16)
hdr=$(mktemp); started=0; lpid=
printf 'Authorization: Bearer %s\n' "$token" > "$hdr"
(umask 077; : > "$hdr.code")
# The VM is this run's own (checked free above): stop it once health answered, or while its launch job is still booting.
cleanup() {
  if [ -n "$lpid" ] && { [ $started = 1 ] || kill -0 $lpid 2>/dev/null; }; then "$cli" vm stop "$vm" || true; fi
  if [ -n "$lpid" ] && kill -0 $lpid 2>/dev/null; then kill $lpid 2>/dev/null || true; fi
  rm -f "$hdr" "$hdr.code"
}
# cu [curl-args]: silent curl with the shared timeouts and the token header file; noauth=1 omits the header.
cu() { local a=(); [ -n "${noauth-}" ] || a=(-H @"$hdr"); curl -s --connect-timeout 3 --max-time 30 $a "$@"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
VPHONE_API_TOKEN=$token "$cli" vm launch "$vm" --headless --api-listen $addr > "$log" 2>&1 &
lpid=$!

want=$(shasum -a 256 "$bundle/Contents/Resources/guest-resources/vphoned" | cut -d' ' -f1)
end=$((SECONDS+300)); ok=0
while [ $SECONDS -lt $end ]; do
  kill -0 $lpid 2>/dev/null || { echo "UNAVAILABLE: vm launch exited; see $log"; tail -20 "$log"; exit 2; }
  h=$(cu -f --max-time 20 http://$addr/v1/health || true)
  # An answer to this run's token means the VM is the one this run started.
  [ -n "$h" ] && started=1
  if [ -n "$h" ] && [ "$(print -r -- "$h" | jq -r '.. | .binary_hash? // empty' 2>/dev/null | head -1 || true)" = "$want" ]; then ok=1; break; fi
  sleep 5
done
[ $ok = 1 ] || { echo "UNAVAILABLE: hash not matched in 300s; see $log"; tail -20 "$log"; exit 2; }
echo "hash matched after ${SECONDS}s"

# rpc <method> <json>: POST /v1/rpc with the token; prints the body, leaves the HTTP status in "$hdr.code".
# A failed or timed-out request or jq yields an empty value, which fails its check; it never aborts the run.
rpc() { cu -H "Content-Type: application/json" -w '%{stderr}%{http_code}' -d "$1" http://$addr/v1/rpc 2> "$hdr.code" || true; }
# All string values of a reply, one per line (messages live in nested fields).
strs() { print -r -- "$1" | jq -r '.. | strings' 2>/dev/null || print -r -- "$1"; }
J() { jq "$@" 2>/dev/null || true; }
total=0; fails=0
chk() { total=$((total+1)); if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1: expected $3 got $4"; fails=$((fails+1)); fi }
finish() { echo "live: $total checks, $fails failures"; echo "TOTAL_FAILS=$fails"; [ $fails = 0 ]; }

# --- capability and catalog -------------------------------------------------
h=$(cu http://$addr/v1/health || true)
c=$(print -r -- "$h" | grep -o '"methods"' | wc -l | tr -d ' ')
[ "$c" = 1 ] && chk "1 health lists methods once" ok || chk "1 health lists methods once" bad 1 "$c"

r1=$(rpc '{"method":"methods.list"}')
L='[.. | objects | select(has("methods")) | .methods | select(type=="array")] | first'
n=$(print -r -- "$r1" | J "$L | length")
f=$(print -r -- "$r1" | J "$L | map(select(.force != \"never\")) | length")
k=$(print -r -- "$r1" | J -r "$L | map(select(.name==\"services.kickstart\")) | .[0].force")
[ "$n" = "$n_specs" ] && chk "2 $n_specs entries" ok || chk "2 $n_specs entries" bad "$n_specs" "$n"
[ "$f" = "$n_forces" ] && chk "2 $n_forces force methods" ok || chk "2 $n_forces force methods" bad "$n_forces" "$f"
[ "$k" = when:kill ] && chk "2 kickstart when:kill" ok || chk "2 kickstart when:kill" bad when:kill "$k"
r2=$(rpc '{"method":"methods.list","params":{"x":1}}')
[ -n "$r1" ] && [ "$r1" = "$r2" ] && chk "2 params ignored (byte-identical)" ok || chk "2 params ignored (byte-identical)" bad "identical non-empty replies" "differ or empty"
r3=$(rpc '{"method":"methods.list"}')
[ -n "$r1" ] && [ "$r1" = "$r3" ] && chk "2 twice byte-identical" ok || chk "2 twice byte-identical" bad "identical non-empty replies" "differ or empty"

r=$(rpc '{"method":"nope.nothing"}')
strs "$r" | grep -qxF 'Unknown method: nope.nothing' && chk "3 unknown method" ok || chk "3 unknown method" bad "Unknown method: nope.nothing" "$r"

# --- auth parity with processes.list ----------------------------------------
# st <method> [header-args]: HTTP status of one request; no header = no token. The only request that omits the token file.
st() { noauth=1 cu -o /dev/null -w '%{http_code}' "${@:2}" -H "Content-Type: application/json" -d "{\"method\":\"$1\"}" http://$addr/v1/rpc || true; }
a1=$(st methods.list); a2=$(st methods.list -H 'Authorization: Bearer wrong')
b1=$(st processes.list); b2=$(st processes.list -H 'Authorization: Bearer wrong')
echo "auth codes methods.list: none=$a1 wrong=$a2 ; processes.list: none=$b1 wrong=$b2"
pok=1; for x in $a1 $a2 $b1 $b2; do case $x in 401|403) ;; *) pok=0 ;; esac; done
if [ $pok = 1 ] && [ "$a1" = "$b1" ] && [ "$a2" = "$b2" ]; then chk "4 auth parity (4xx refusal equal to processes.list's)" ok
else chk "4 auth parity (4xx refusal equal to processes.list's)" bad "401/403 equal to processes.list's" "methods.list $a1 $a2 processes.list $b1 $b2"; fi

# --- the token is not in any process argv ----------------------------------
if ps -ww -axo args | VPHONE_API_TOKEN=$token awk 'index($0, ENVIRON["VPHONE_API_TOKEN"]) { f = 1 } END { exit f }'; then chk "5 token not in argv" ok
else chk "5 token not in argv" bad "token absent from ps args" "token found"; fi

# --- undeclared keys are dropped on a real method ---------------------------
pn() { print -r -- "$1" | J -c '[.. | objects | select(has("processes")) | .processes[] | .name?] | sort'; }
p1=$(pn "$(rpc '{"method":"processes.list","params":{"filter":"launchd"}}')")
p2=$(pn "$(rpc '{"method":"processes.list","params":{"filter":"launchd","extra":1}}')")
if [ -n "$p1" ] && [ "$p1" != "[]" ] && [ "$p1" = "$p2" ]; then chk "6 processes.list extra key dropped" ok
else chk "6 processes.list extra key dropped" bad "same non-empty names" "plain=$p1 extra=$p2"; fi

# --- the 20 force methods: refused unforced, a required param is validated before the force refusal
# A reply to an unforced destructive call without `Pass force` means it may have run: stop at once.
e() {
  r=$(rpc "{\"method\":\"$1\",\"params\":$2}"); s=$(strs "$r"); c=$(cat "$hdr.code" 2>/dev/null || true)
  if daemon_status "$c" && print -r -- "$s" | grep -qxF -- "$3"; then chk "$1 $2" ok; else chk "$1 $2" bad "'$3' with status 200/400" "status=$c '$s'"; fi
  case $3 in *'Pass force'*) if ! print -r -- "$s" | grep -qF 'Pass force'; then echo "LEAK: $1 was not refused unforced; stopping"; finish || true; exit 1; fi ;; esac
}
e processes.kill '{"pid":4242}' 'Pass force: true to send SIGTERM to 4242'
e processes.kill '{"pid":1}' 'pid 1 cannot be signalled'
e apps.uninstall '{}' 'bundle_id is required'
e apps.uninstall '{"bundle_id":"com.example.none"}' 'Pass force: true to uninstall com.example.none'
e bootstrap.uninstall '{}' 'Pass force: true to uninstall the bootstrap'
e apps.unregister '{"path":"/tmp/x.app"}' 'Pass force: true to unregister /tmp/x.app'
e apps.unregister_dir '{"directory":"/tmp"}' 'Pass force: true to unregister every app in /tmp'
e system.respring '{}' 'Pass force: true to restart SpringBoard'
e system.reboot '{}' 'Pass force: true to reboot the guest'
e system.reboot '{"userspace":true}' 'Pass force: true to restart userspace'
e system.shutdown '{}' 'Pass force: true to shut down the guest'
e setup.skip '{}' 'Pass force: true to skip Setup Assistant'
e services.profile.apply '{"profile":"x"}' 'Pass force: true to apply a service profile'
e services.kickstart '{"label":"x","kill":true}' 'Pass force: true to kill and restart x'
e services.stop '{"label":"x"}' 'Pass force: true to stop x'
e services.disable '{"label":"x"}' 'Pass force: true to disable x'
e services.remove '{"label":"x"}' 'Pass force: true to remove x'
e services.signal '{"label":"x","signal":"TERM"}' 'Pass force: true to send TERM to x'
e services.unload '{"paths":["/tmp/x.plist"]}' 'Pass force: true to unload services'
e services.unload '{}' 'paths must list plist files or directories'
e apfs.snapshot.delete '{}' 'Pass force: true to delete APFS snapshots on /'
e ota.apps.apply '{}' 'Pass force: true to update retained Apple app programs from the installed OTA'
e apps.remove_system '{"bundle_ids":["com.apple.news"]}' 'Pass force: true to remove com.apple.news'
e apps.restore_system '{"bundle_ids":["com.apple.news"]}' 'Pass force: true to restore removed system apps'
# invalid and unforced: today's handler validated first
e apps.unregister '{}' 'path is required'
e apps.unregister_dir '{}' 'directory is required'
e services.stop '{}' 'label is required'
e services.disable '{}' 'label is required'
e services.remove '{}' 'label is required'
e services.signal '{"label":"x"}' 'signal is required'
e services.kickstart '{"kill":true}' 'label is required'
e apps.remove_system '{}' 'bundle_ids must list the apps to remove'
e apps.restore_system '{"bundle_ids":[]}' 'bundle_ids must list bundle identifiers'
e apfs.snapshot.delete '{"name":"a","prefix":"b"}' 'Pass name or prefix, not both'
# invalid and unforced: today's handler checked force first
e services.profile.apply '{}' 'Pass force: true to apply a service profile'
e ota.apps.apply '{"removed_bundle_ids":"x"}' 'Pass force: true to update retained Apple app programs from the installed OTA'

# --- force:true passes the gate (nonexistent targets only; system.reboot, system.shutdown, bootstrap.uninstall,
# setup.skip, ota.apps.apply, apfs.snapshot.delete, services.profile.apply, apps.restore_system are not run forced)
# Fails if the reply is not valid JSON, the HTTP status is not the daemon's 200/400, or a decoded line starts with `Unknown method` or contains `Pass force`.
g() {
  r=$(rpc "{\"method\":\"$1\",\"params\":$2}"); s=$(strs "$r"); c=$(cat "$hdr.code" 2>/dev/null || true)
  if print -r -- "$r" | jq -e . >/dev/null 2>&1 && daemon_status "$c" \
     && ! print -r -- "$s" | grep -qE '^Unknown method|Pass force'; then chk "$1 $2" ok
  else chk "$1 $2" bad "a JSON daemon reply, status 200/400, no Unknown method or Pass force" "status=$c '$s'"; fi
}
g processes.kill '{"pid":999999,"force":true}'
g apps.uninstall '{"bundle_id":"com.example.none","force":true}'
g apps.unregister '{"path":"/tmp/none.app","force":true}'
g apps.unregister_dir '{"directory":"/tmp/none-dir","force":true}'
g services.kickstart '{"label":"com.example.none","kill":true,"force":true}'
g services.stop '{"label":"com.example.none","force":true}'
g services.disable '{"label":"com.example.none","force":true}'
g services.remove '{"label":"com.example.none","force":true}'
g services.signal '{"label":"com.example.none","signal":"TERM","force":true}'
g services.unload '{"paths":["/tmp/none.plist"],"force":true}'
g apps.remove_system '{"bundle_ids":["com.example.none"],"force":true}'
g system.respring '{"force":true}'

finish
