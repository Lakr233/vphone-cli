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
#   VPHONE_LIVE_TIMEOUT positive integer seconds per schema-comparison call (default 30); anything else -> exit 2
# Schema comparison: every catalog row classed `read` is called serially with no params (no retry, 1048576-byte
#   reply cap) and its reply's top-level keys and JSON types are compared to the row's result column.
#   `mutating` and `excluded:<reason>` rows are never called. Prints `PASS <method>` or `FAIL <method>: <reason>`;
#   only keys, types and escaped error codes are printed, never reply values, and no reply is written to a file.
#   Three consecutive timeout/transport/unparsable failures print `FAIL guest unresponsive` and stop the run.
# Test seam (no VM): VPHONE_LIVE_BASE_URL (e.g. http://127.0.0.1:9), VPHONE_LIVE_TOKEN and optionally
#   VPHONE_LIVE_CATALOG run only the schema comparison against that server (run-methods-live-stub-tests.sh);
#   with VPHONE_LIVE_UNFORCED_CHECK=1 they run one unforced system.reboot refusal check instead.
# Unforced calls to force methods: a guest-closed reply (HTTP 000, or the proxy's 502 `guest_closed`) is retried
#   once and prints `RETRY <method> <params>: guest closed without a reply`; a second one halts with LEAK.
# Output: `PASS <check>` or `FAIL <check>: expected <x> got <y>` per check, then
#   live: <n> checks, <f> failures
#   TOTAL_FAILS=<f>
#   <p> passed, <q> failed        (the schema comparison; always the last line)
# Exit: 0 all checks pass, 1 a check or schema comparison failed (or an unforced destructive call was not refused),
# 2 guest unavailable (prints `UNAVAILABLE: <reason>`) or bad usage.
set -eu

case ${1-} in
  --help|-h) sed -n '2,/^set -eu/p' "$0" | sed '$d'; exit 0 ;;
  '') ;;
  *) echo "usage: run-methods-live.zsh [--help]" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "usage: run-methods-live.zsh [--help]" >&2; exit 2; }
live_timeout=${VPHONE_LIVE_TIMEOUT-30}
case $live_timeout in
  ''|*[!0-9]*|0|0[0-9]*) echo "invalid VPHONE_LIVE_TIMEOUT $live_timeout; set a positive integer number of seconds" >&2; exit 2 ;;
esac

# --- schema comparison ----------------------------------------
# jq program: stdin is one reply, $schema the catalog result cell. Prints `PASS`, `UNP` (unparsable), `ERR <code>`
# or `FAIL <reason>`; never a reply value other than escaped key names and error codes.
read -r -d '' schema_jq <<'JQ' || true
def u8: if . < 128 then [.] elif . < 2048 then [192 + (. / 64 | floor), 128 + (. % 64)]
  elif . < 65536 then [224 + (. / 4096 | floor), 128 + ((. / 64 | floor) % 64), 128 + (. % 64)]
  else [240 + (. / 262144 | floor), 128 + ((. / 4096 | floor) % 64), 128 + ((. / 64 | floor) % 64), 128 + (. % 64)] end;
def hx: . as $d | "0123456789abcdef"[($d / 16 | floor):($d / 16 | floor) + 1] + "0123456789abcdef"[($d % 16):($d % 16) + 1];
def esc: tostring | explode | map(if . >= 32 and . <= 126 then ([.] | implode) else (u8 | map("\\x" + hx) | join("")) end) | join("") | .[0:64];
def actual: if type == "number" then (if . == floor then "integer" else "number" end) else type end;
def okType($t; $nl): if $t == "any" then true
  elif type == "null" then ($nl or $t == "null")
  elif $t == "null" then false
  elif $t == "number" then type == "number"
  elif $t == "integer" then (type == "number" and . == floor)
  else type == $t end;
def decl: ($schema | if . == "-" then [] else split(",") end)
  | map(capture("^(?<n>.+?):(?<t>[a-z]+)(?<nl>:null)?(?<f>[?~*]*)$") | {n, t, nl: (.nl != null), opt: (.f | contains("?")), hid: (.f | contains("~"))});
if type != "object" then "UNP"
elif has("error") or has("guest_error") then
  "ERR " + ((.error.code? // .guest_error.code? // "unknown") | if type == "string" or type == "number" then esc else "unknown" end)
elif (.result | type) != "object" then "UNP"
else
  .result as $res | decl as $d
  | ([$res | keys[] | . as $k | ($d | map(select(.n == $k and (.hid | not))) | first) as $x
      | if $x == null then ($k | esc) + " undeclared"
        elif ($res[$k] | okType($x.t; $x.nl)) then empty
        else ($k | esc) + " expected " + $x.t + " got " + ($res[$k] | actual) end]
     + [$d[] | select((.opt or .hid) | not) | select(. as $x | $res | has($x.n) | not) | .n + " missing"])
  | if length == 0 then "PASS" else "FAIL " + .[0] end
end
JQ

sp=0; sf=0; schema_ran=0; stop_unresponsive=0; consec=0
# live_call <method>: prints the raw reply (capped, sentinel-terminated), leaves curl's exit code in $sdir/rc
# and the HTTP status in $sdir/code. Neither file ever holds reply data.
live_call() {
  local crc=0
  { curl -s --connect-timeout 3 --max-time "$live_timeout" -H @"$hdr" -H "Content-Type: application/json" \
      -w "%{stderr}%{http_code}" -d "{\"method\":\"$1\"}" "$schema_base/v1/rpc" 2> "$sdir/code" || crc=$?
    print -r -- $crc > "$sdir/rc"; } | head -c 1048577
  printf x
}
# schema_fail <method> <reason> <counted>: prints one FAIL line and tracks the consecutive-failure count.
schema_fail() {
  print -r -- "FAIL $1: $2"; sf=$((sf+1))
  if [ "$3" = 1 ]; then consec=$((consec+1)); else consec=0; fi
}
schema_section() {
  local catalog=${VPHONE_LIVE_CATALOG:-$root/VPhoneDaemon/Tests/methods-catalog.tsv}
  local m f p fa res live r rc code n out c
  schema_ran=1
  while IFS=$'\t' read -r m f p fa res live; do
    [ "$live" = read ] || continue
    r=$(live_call "$m"); r=${r%x}
    rc=$(cat "$sdir/rc"); code=$(cat "$sdir/code" 2>/dev/null || true)
    n=$(print -rn -- "$r" | wc -c | tr -d ' ')
    if [ "$rc" = 28 ]; then schema_fail "$m" timeout 1
    elif [ "$n" -gt 1048576 ]; then schema_fail "$m" "reply too large" 0
    elif [ "$rc" != 0 ]; then
      case $rc in 7) c=connect ;; 52) c=empty ;; 56) c=reset ;; 6) c=dns ;; *) c="curl $rc" ;; esac
      schema_fail "$m" "transport $c" 1
    elif [ "$code" != 200 ] && [ "$code" != 400 ]; then schema_fail "$m" "transport HTTP ${code:-none}" 1
    else
      out=$(print -rn -- "$r" | jq -r --arg schema "$res" "$schema_jq" 2>/dev/null) || out=UNP
      case $out in
        PASS) echo "PASS $m"; sp=$((sp+1)); consec=0 ;;
        FAIL\ *) schema_fail "$m" "${out#FAIL }" 0 ;;
        ERR\ *) schema_fail "$m" "error ${out#ERR }" 0 ;;
        *) schema_fail "$m" "unparsable reply" 1 ;;
      esac
    fi
    if [ $consec -ge 3 ]; then echo "FAIL guest unresponsive"; stop_unresponsive=1; break; fi
  done < "$catalog"
}
schema_summary() { [ $schema_ran = 0 ] || echo "$sp passed, $sf failed"; }

# --- shared helpers (VM run and test seam) -----------------------------------
# The daemon answers 200, or 400 for a handler error (APIWire.swift); 401/403 are refusals before the daemon.
daemon_status() { case $1 in 200|400) return 0 ;; *) return 1 ;; esac; }
# cu [curl-args]: silent curl with the shared timeouts and the token header file; noauth=1 omits the header.
cu() { local a=(); [ -n "${noauth-}" ] || a=(-H @"$hdr"); curl -s --connect-timeout 3 --max-time 30 $a "$@"; }
# rpc <method> <json>: POST /v1/rpc with the token; prints the body, leaves the HTTP status in "$hdr.code".
# A failed or timed-out request or jq yields an empty value, which fails its check; it never aborts the run.
rpc() { cu -H "Content-Type: application/json" -w '%{stderr}%{http_code}' -d "$1" "$schema_base/v1/rpc" 2> "$hdr.code" || true; }
# All string values of a reply, one per line (messages live in nested fields).
strs() { print -r -- "$1" | jq -r '.. | strings' 2>/dev/null || print -r -- "$1"; }
J() { jq "$@" 2>/dev/null || true; }
chk() { total=$((total+1)); if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1: expected $3 got $4"; fails=$((fails+1)); fi }
finish() { echo "live: $total checks, $fails failures"; echo "TOTAL_FAILS=$fails"; schema_summary; [ $fails = 0 ] && [ $sf = 0 ]; }
# guest_closed <reply> <status>: true for no HTTP reply (000 or empty) or the proxy's 502 guest_closed.
guest_closed() { case $2 in 000|'') return 0 ;; 502) print -r -- "$1" | jq -e '.error.code == "guest_closed"' >/dev/null 2>&1 ;; *) return 1 ;; esac; }
# unforced <method> <params>: one rpc, retried once when the guest closed without a reply (seen after a vphoned
# restart; not a leak); sets r and c.
unforced() {
  r=$(rpc "{\"method\":\"$1\",\"params\":$2}"); c=$(cat "$hdr.code" 2>/dev/null || true)
  if guest_closed "$r" "$c"; then
    echo "RETRY $1 $2: guest closed without a reply"
    r=$(rpc "{\"method\":\"$1\",\"params\":$2}"); c=$(cat "$hdr.code" 2>/dev/null || true)
  fi
}
# e <method> <params> <message>: an unforced call must answer <message> with status 200/400.
# A reply to an unforced destructive call without `Pass force` means it may have run: stop at once.
e() {
  unforced "$1" "$2"; s=$(strs "$r")
  if daemon_status "$c" && print -r -- "$s" | grep -qxF -- "$3"; then chk "$1 $2" ok; else chk "$1 $2" bad "'$3' with status 200/400" "status=$c '$s'"; fi
  case $3 in *'Pass force'*) if ! print -r -- "$s" | grep -qF 'Pass force'; then echo "LEAK: $1 was not refused unforced; stopping"; finish || true; exit 1; fi ;; esac
}

# Test seam: a stub server stands in for the guest and only the schema comparison runs
# (or, with VPHONE_LIVE_UNFORCED_CHECK=1, one unforced system.reboot check).
if [ -n "${VPHONE_LIVE_BASE_URL-}" ]; then
  root=${0:a:h:h:h}
  schema_base=$VPHONE_LIVE_BASE_URL
  sdir=$(mktemp -d); hdr=$sdir/hdr
  trap 'rm -rf "$sdir"' EXIT
  (umask 077; printf 'Authorization: Bearer %s\n' "${VPHONE_LIVE_TOKEN-}" > "$hdr")
  if [ "${VPHONE_LIVE_UNFORCED_CHECK-}" = 1 ]; then
    total=0; fails=0
    e system.reboot '{}' 'Pass force: true to reboot the guest'
    finish; exit
  fi
  schema_section
  schema_summary
  [ $sf = 0 ]; exit
fi

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
sdir=$(mktemp -d); schema_base=http://$addr
printf 'Authorization: Bearer %s\n' "$token" > "$hdr"
(umask 077; : > "$hdr.code")
# The VM is this run's own (checked free above): stop it once health answered, or while its launch job is still booting.
cleanup() {
  if [ -n "$lpid" ] && { [ $started = 1 ] || kill -0 $lpid 2>/dev/null; }; then "$cli" vm stop "$vm" || true; fi
  if [ -n "$lpid" ] && kill -0 $lpid 2>/dev/null; then kill $lpid 2>/dev/null || true; fi
  rm -rf "$hdr" "$hdr.code" "$sdir"
}
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

total=0; fails=0

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
# The filter is a substring match, so transient launchd-named helpers come and go between the two calls; compare launchd itself.
pn() { print -r -- "$1" | J -c '[.. | objects | select(has("processes")) | .processes[] | .name? | select(. == "launchd")] | sort'; }
p1=$(pn "$(rpc '{"method":"processes.list","params":{"filter":"launchd"}}')")
p2=$(pn "$(rpc '{"method":"processes.list","params":{"filter":"launchd","extra":1}}')")
if [ -n "$p1" ] && [ "$p1" != "[]" ] && [ "$p1" = "$p2" ]; then chk "6 processes.list extra key dropped" ok
else chk "6 processes.list extra key dropped" bad "same non-empty names" "plain=$p1 extra=$p2"; fi

# --- the 20 force methods: refused unforced (e, above), a required param is validated before the force refusal
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

# --- self-describing methods.list (methods-list-descriptions) ----------------
# Descriptions: every method and param has a non-empty one-line description of at most 120 characters; force_action
# is present exactly when force is not "never".
bad=$(print -r -- "$r1" | J -r "$L"' | map(
    (select((.description | type) != "string" or (.description | length) == 0 or (.description | length) > 120 or (.description | test("\n"))) | .name),
    (.name as $m | .params[] | select((.description | type) != "string" or (.description | length) == 0 or (.description | length) > 120 or (.description | test("\n"))) | $m + "." + .name),
    (select((.force != "never") != has("force_action")) | .name + " force_action"),
    (select(.force != "never" and has("force_action") and (((.force_action | type) != "string") or (.force_action | length) == 0 or (.force_action | length) > 120)) | .name + " force_action")
  ) | flatten | join(" ")')
[ -z "$bad" ] && [ -n "$r1" ] && chk "7 descriptions and force_action well formed" ok || chk "7 descriptions and force_action well formed" bad "none" "${bad:-no reply}"
# Optional keys: never null; a falsy default (0 or false) is emitted; a named param without default omits it.
bad=$(print -r -- "$r1" | J -r "$L"' | [.[].params[] | to_entries[] | select(.value == null) | .key] | join(" ")')
[ -z "$bad" ] && chk "7 no null param keys" ok || chk "7 no null param keys" bad "no null" "$bad"
z=$(print -r -- "$r1" | J -r "$L"' | [.[].params[] | select(has("default") and (.default == 0 or .default == false))] | length')
[ "${z:-0}" -gt 0 ] && chk "7 falsy default emitted" ok || chk "7 falsy default emitted" bad "a param with default 0 or false" "${z:-none}"
# A named param declared without a default must not emit one (time.clock.time).
z=$(print -r -- "$r1" | J -r "$L"' | [.[] | select(.name == "time.clock") | .params[] | select(.name == "time") | has("default")] | if length == 1 then .[0] else "missing" end')
[ "$z" = false ] && chk "7 time.clock.time default omitted" ok || chk "7 time.clock.time default omitted" bad "time.clock param time without default" "${z:-no reply}"
# enum, minimum and maximum are emitted with the declared values (GuestAPI+Input.swift).
z=$(print -r -- "$r1" | J -c "$L"' | [(.[] | select(.name == "input.button") | .params[] | select(.name == "name") | .enum), (.[] | select(.name == "accessibility.tree") | .params[] | select(.name == "max_elements") | [.minimum, .maximum])]')
[ "$z" = '[["home","power","volume-up","volume-down","mute","wake"],[1,2000]]' ] && chk "7 enum minimum maximum emitted" ok || chk "7 enum minimum maximum emitted" bad "input.button name enum and accessibility.tree max_elements [1,2000]" "${z:-no reply}"
# Force text: for each forced method, call it without force (refused before any side effect) with dummy required
# params (first enum value for enums, the `when` key true) and require the error to match
# "Pass force: true to " + force_action, a `<...>` placeholder matching any text. A reply that is not a force
# refusal (the closure rejected the dummy params first) is skipped.
fa=$(print -r -- "$r1" | J -r "$L"'
  | def esc: gsub("(?<c>[\\\\.^$*+?()\\[\\]{}|])"; "\\\(.c)");
  .[] | select(.force != "never")
  | (if (.force | startswith("when:")) then (.force | sub("^when:"; "")) else "" end) as $key
  | ([.params[] | select(.required or .name == $key) | {key: .name, value:
      (if .name == $key then true
       elif .enum then .enum[0]
       elif .type == "integer" or .type == "number" then 1
       elif .type == "boolean" then true
       elif .type == "array" then ["x"]
       elif .type == "object" then {}
       else "x" end)}] | from_entries) as $p
  | [.name, ($p | tojson), ("^Pass force: true to " + (.force_action | gsub("`?<[^>]*>`?"; "\u0001") | esc | gsub("\u0001"; ".+")) + "$")] | join("\t")')
verified=0
while IFS=$'\t' read -r fm fp fpat; do
  [ -n "$fm" ] || continue
  unforced "$fm" "$fp"; s=$(strs "$r")
  if print -r -- "$s" | grep -qE -- "$fpat"; then chk "8 $fm force text" ok; verified=$((verified+1))
  elif print -r -- "$s" | grep -qF 'Pass force: true to'; then chk "8 $fm force text" bad "$fpat" "$s"
  elif print -r -- "$r" | jq -e '.. | objects | select(has("error"))' >/dev/null 2>&1; then echo "SKIP 8 $fm force text: params rejected first"
  else echo "LEAK: $fm was not refused unforced; stopping"; finish || true; exit 1; fi
done <<< "$fa"
floor=$((n_forces-4))
[ $verified -ge $floor ] && chk "8 force text verified >= $floor" ok || chk "8 force text verified >= $floor" bad ">= $floor of $n_forces" "$verified"

# --- schema comparison of every read-class method ---------------------------
schema_section
[ $stop_unresponsive = 0 ] || { finish || true; exit 1; }
finish
