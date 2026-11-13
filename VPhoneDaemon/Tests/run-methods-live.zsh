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
#   display.external.diagnostics and display.external.status also pass on a well-formed error with code
#   invalid_operation and unavailable respectively (a guest with no external display).
#   `mutating` and `excluded:<reason>` rows are never called. Prints `PASS <method>` or `FAIL <method>: <reason>`;
#   only keys, types and escaped error codes are printed, never reply values, and no reply is written to a file.
#   Three consecutive timeout/transport/unparsable failures print `FAIL guest unresponsive` and stop the run.
# Test seam (no VM): VPHONE_LIVE_BASE_URL (e.g. http://127.0.0.1:9), VPHONE_LIVE_TOKEN and optionally
#   VPHONE_LIVE_CATALOG run only the schema comparison against that server (run-methods-live-stub-tests.sh);
#   with VPHONE_LIVE_UNFORCED_CHECK=1 they run one unforced system.reboot refusal check instead.
# Unforced calls to force methods: a guest-closed reply (HTTP 000, or the proxy's 502 `guest_closed`) is retried
#   once and prints `RETRY <method> <params>: guest closed without a reply`; a second one halts with LEAK.
# Input observe (checks numbered 9): unlocks the guest, launches Settings (apps.launch), taps its status bar in
#   Settings, presses a letter key and the home button.
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
        "ERR invalid_operation") if [ "$m" = display.external.diagnostics ]; then echo "PASS $m"; sp=$((sp+1)); consec=0
          else schema_fail "$m" "error invalid_operation" 0; fi ;;
        "ERR unavailable") if [ "$m" = display.external.status ]; then echo "PASS $m"; sp=$((sp+1)); consec=0
          else schema_fail "$m" "error unavailable" 0; fi ;;
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
{ print -r -- "$r2" | grep -qF '"invalid_param"' && strs "$r2" | grep -qxF 'Unknown param: x' && strs "$r2" | grep -qxF 'This method takes no params'; } \
  && chk "2 undeclared param rejected" ok || chk "2 undeclared param rejected" bad "invalid_param, Unknown param: x, This method takes no params" "$r2"
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

# --- an undeclared key fails a real method ----------------------------------
r=$(rpc '{"method":"processes.list","params":{"filter":"launchd","extra":1}}')
{ print -r -- "$r" | grep -qF '"invalid_param"' && strs "$r" | grep -qxF 'Unknown param: extra' && strs "$r" | grep -qF 'Valid params:'; } \
  && chk "6 processes.list extra key rejected" ok || chk "6 processes.list extra key rejected" bad "invalid_param, Unknown param: extra, Valid params" "$r"

# --- bounded replies: processes.list pages (sorted by pid), processes.spawn cuts its output ---------
pg1=$(rpc '{"method":"processes.list","params":{"limit":5}}')
cur=$(print -r -- "$pg1" | J -r '[.. | objects | select(has("next_cursor")) | .next_cursor][0] // empty')
pg2=$(rpc "{\"method\":\"processes.list\",\"params\":{\"limit\":5,\"cursor\":\"$cur\"}}")
first=$(print -r -- "$pg1" | J -c '[.. | objects | select(has("processes")) | {n: (.processes | length), t: .truncated, hi: ([.processes[].pid] | max)}][0]')
second=$(print -r -- "$pg2" | J -c '[.. | objects | select(has("processes")) | {n: (.processes | length), lo: ([.processes[].pid] | min)}][0]')
if [ -n "$cur" ] && [ "$(print -r -- "$first" | J '.n == 5 and .t == true')" = true ] && [ "$(print -r -- "$second" | J '.n == 5')" = true ] \
   && [ "$(jq -n --argjson a "${first:-null}" --argjson b "${second:-null}" '$b.lo > $a.hi' 2>/dev/null || true)" = true ]; then chk "7 processes.list pages by pid" ok
else chk "7 processes.list pages by pid" bad "two pages of 5, the second after the first" "cursor='$cur' first=$first second=$second"; fi
# rf <reply> <jq path in the result object>: one field of the first reply object holding stdout_total.
rf() { print -r -- "$1" | J -r "[.. | objects | select(has(\"stdout_total\"))][0] | $2"; }
# The guest has no launchctl or log binary; ps is the allowlisted command that runs there. Its 25 repeated
# command columns are about 100 KiB. bigspawn [extra params json] repeats the spawn up to 4 times while the
# guest's ps outruns the 10 s timeout.
pscols=$(printf 'command,%.0s' {1..24})command
bigspawn() {
  local r i
  for i in 1 2 3 4; do
    r=$(rpc "{\"method\":\"processes.spawn\",\"params\":{\"executable\":\"ps\",\"arguments\":[\"-axwwo\",\"$pscols\"],\"timeout_ms\":10000${1-}}}")
    [ "$(rf "$r" '.timed_out')" = true ] || break
  done
  print -r -- "$r"
}
sps=$(bigspawn ',"max_output_bytes":100')
spawned=$(print -r -- "$sps" | J -c '[.. | objects | select(has("stdout_truncated")) | {b: (.stdout | utf8bytelength), t: .stdout_truncated, n: .stdout_total, i: (.output_id | type), d: (.output_dir | type)}][0]')
if [ "$(print -r -- "$spawned" | J '.t == true and .b <= 100 and .b > 0 and .n > 100 and .i == "string" and .d == "string"')" = true ]; then chk "8 processes.spawn ps output cut at 100 bytes" ok
else chk "8 processes.spawn ps output cut at 100 bytes" bad "stdout_truncated true, 1 to 100 bytes, stdout_total above 100, output_id and output_dir" "$spawned"; fi
ap=$(rpc '{"method":"apps.list","params":{"limit":50}}')
if [ "$(print -r -- "$ap" | J '[.. | objects | select(has("apps")) | .apps][0] | (length > 1) and (. == sort_by([(.bundle_id // ""), (.path // "")]))')" = true ]; then chk "10 apps.list sorted by bundle_id then path" ok
else chk "10 apps.list sorted by bundle_id then path" bad "at least two apps in bundle_id, path order" "$(print -r -- "$ap" | head -c 300)"; fi
# pages <method> <key> <row id jq> <keep|strings> [params prefix]: a limit-2 page (truncated, with next_cursor) and the
# page its cursor names continue one limit-1000 listing in order, with no gap, repeat or overlap; `strings` is sorted.
pages() {
  local sel="[.. | objects | select(has(\"$2\"))][0]" full q1 q2 c
  full=$(rpc "{\"method\":\"$1\",\"params\":{${5-}\"limit\":1000}}" | J -c "$sel | {t: .truncated, ids: [.$2[] | $3]}")
  q1=$(rpc "{\"method\":\"$1\",\"params\":{${5-}\"limit\":2}}" | J -c "$sel | {t: .truncated, c: .next_cursor, ids: [.$2[] | $3]}")
  c=$(print -r -- "$q1" | J -r '.c // empty')
  q2=$(rpc "{\"method\":\"$1\",\"params\":{${5-}\"limit\":2,\"cursor\":\"$c\"}}" | J -c "$sel | {ids: [.$2[] | $3]}")
  if [ "$(jq -n --argjson f "${full:-null}" --argjson a "${q1:-null}" --argjson b "${q2:-null}" --arg o "$4" '
      ($a.ids | length) as $n | ($b.ids | length) as $m
      | $f.t == false and ($f.ids | length) > 4 and $a.t == true and ($a.c | type) == "string" and $n == 2 and $m >= 1 and $m <= 2
        and $a.ids + $b.ids == $f.ids[0:$n + $m] and ($a.ids + $b.ids | unique | length) == $n + $m
        and ($o == "keep" or $f.ids == ($f.ids | sort))' 2>/dev/null || true)" = true ]; then chk "14 $1 pages in $4 order" ok
  else chk "14 $1 pages in $4 order" bad "two limit-2 pages continuing one untruncated listing of 5+ in $4 order" "full=$(print -r -- "$full" | head -c 200) first=$q1 second=$q2"; fi
}
pages services.list services .label keep
pages files.find matches . strings '"root":"/System/Library/LaunchDaemons","pattern":"com.apple.mobile",'
for bad in 0 65537 100.7 18446744073709551621 true; do
  r=$(rpc "{\"method\":\"processes.spawn\",\"params\":{\"executable\":\"ps\",\"max_output_bytes\":$bad}}"); s=$(strs "$r"); c=$(cat "$hdr.code" 2>/dev/null || true)
  if daemon_status "$c" && print -r -- "$r" | grep -qF '"invalid_param"' && print -r -- "$s" | grep -qF 'max_output_bytes must be an integer from 1 to 65536'; then chk "9 processes.spawn max_output_bytes $bad rejected" ok
  else chk "9 processes.spawn max_output_bytes $bad rejected" bad "invalid_param naming max_output_bytes" "status=$c '$s'"; fi
done
for bad in 0 16777217 10.5 18446744073709551621 true; do
  r=$(rpc "{\"method\":\"processes.spawn\",\"params\":{\"executable\":\"ps\",\"max_capture_bytes\":$bad}}"); s=$(strs "$r"); c=$(cat "$hdr.code" 2>/dev/null || true)
  if daemon_status "$c" && print -r -- "$r" | grep -qF '"invalid_param"' && print -r -- "$s" | grep -qF 'max_capture_bytes must be an integer from 1 to 16777216'; then chk "9 processes.spawn max_capture_bytes $bad rejected" ok
  else chk "9 processes.spawn max_capture_bytes $bad rejected" bad "invalid_param naming max_capture_bytes" "status=$c '$s'"; fi
done
for bad in 9223372036854775808 1e300; do
  for call in "processes.output|\"output_id\":\"$(uuidgen)\",\"stream\":\"stdout\"" "files.read|\"path\":\"/etc/hosts\""; do
    r=$(rpc "{\"method\":\"${call%%|*}\",\"params\":{${call#*|},\"offset\":$bad}}"); s=$(strs "$r"); c=$(cat "$hdr.code" 2>/dev/null || true)
    if daemon_status "$c" && print -r -- "$r" | grep -qF '"invalid_param"' && print -r -- "$s" | grep -qF 'offset must be an integer from 0 to 1099511627776'; then chk "9 ${call%%|*} offset $bad rejected" ok
    else chk "9 ${call%%|*} offset $bad rejected" bad "invalid_param naming offset" "status=$c '$s'"; fi
  done
done

# --- spooled spawn output: ps with 25 repeated command columns is about 100 KiB, over one 64 KiB page ----
gone='is released, expired or evicted'
bs=$(bigspawn)
id=$(rf "$bs" '.output_id // empty'); dir=$(rf "$bs" '.output_dir // empty'); tot=$(rf "$bs" '.stdout_total')
if [ "$(rf "$bs" '.stdout_truncated')" = true ] && [ "$(rf "$bs" '.timed_out')" = false ] && [ "$(rf "$bs" '.exit_code')" = 0 ] && [ -n "$id" ] && [ -n "$dir" ] && [ "${tot:-0}" -gt 65536 ]; then chk "11 ps repeated-column spawn truncated with output_id" ok
else chk "11 ps repeated-column spawn truncated with output_id" bad "stdout_truncated true, timed_out false, exit_code 0, output_id, output_dir, stdout_total above 65536" "id=$id dir=$dir total=$tot $(rf "$bs" '[.timed_out, .exit_code] | @json')"; fi
# processes.output pages joined by next_offset
: > $sdir/po.bin; off=0; guard=0
while [ -n "$id" ] && [ $guard -lt 300 ]; do
  guard=$((guard+1))
  r=$(rpc "{\"method\":\"processes.output\",\"params\":{\"output_id\":\"$id\",\"stream\":\"stdout\",\"offset\":$off,\"binary\":true}}")
  print -r -- "$r" | J -r '[.. | objects | select(has("data"))][0].data // empty' | base64 -D >> $sdir/po.bin 2>/dev/null || true
  nx=$(print -r -- "$r" | J -r '[.. | objects | select(has("data"))][0].next_offset // empty')
  [ -n "$nx" ] || break
  off=$nx
done
po=$(wc -c < $sdir/po.bin | tr -d ' ')
[ -n "$id" ] && [ "$po" = "$tot" ] && chk "11 processes.output pages join to stdout_total bytes" ok || chk "11 processes.output pages join to stdout_total bytes" bad "$tot bytes" "$po"
# files.read offset pages on <output_dir>/stdout, joined by next_offset; each page reports total, the last no next_offset
: > $sdir/fr.bin; off=0; guard=0; frok=1; page=
while [ -n "$dir" ] && [ $guard -lt 300 ]; do
  guard=$((guard+1))
  r=$(rpc "{\"method\":\"files.read\",\"params\":{\"path\":\"$dir/stdout\",\"offset\":$off,\"limit\":65536,\"binary\":true}}")
  print -r -- "$r" | J -r '[.. | objects | select(has("content"))][0].content // empty' | base64 -D > $sdir/chunk.bin 2>/dev/null || true
  cat $sdir/chunk.bin >> $sdir/fr.bin
  got=$(wc -c < $sdir/chunk.bin | tr -d ' ')
  page=$(print -r -- "$r" | J -c '[.. | objects | select(has("content"))][0] | {t: .truncated, n: .next_offset, total}')
  nx=$(print -r -- "$page" | J -r '.n // empty')
  [ "$(print -r -- "$page" | J -r '.total')" = "$tot" ] || frok=0
  if [ "$(print -r -- "$page" | J -r '.t')" = true ]; then [ "$nx" = $((off+got)) ] || frok=0; else [ -z "$nx" ] || frok=0; fi
  [ -n "$nx" ] && [ "$got" -gt 0 ] || break
  off=$nx
done
fr=$(wc -c < $sdir/fr.bin | tr -d ' ')
if [ -n "$dir" ] && [ "$fr" = "$tot" ] && cmp -s $sdir/po.bin $sdir/fr.bin; then chk "11 files.read offset pages equal processes.output pages" ok
else chk "11 files.read offset pages equal processes.output pages" bad "$tot identical bytes" "po=$po fr=$fr"; fi
if [ -n "$dir" ] && [ $frok = 1 ]; then chk "11 files.read pages report total and next_offset" ok
else chk "11 files.read pages report total and next_offset" bad "total $tot on each page, next_offset = offset + bytes while truncated, none on the last" "page $page"; fi
# files.read offset without limit: at most 512 KiB from the offset, truncated exactly when more remains
r=$(rpc "{\"method\":\"files.read\",\"params\":{\"path\":\"$dir/stdout\",\"offset\":1000,\"binary\":true}}")
print -r -- "$r" | J -r '[.. | objects | select(has("content"))][0].content // empty' | base64 -D > $sdir/chunk.bin 2>/dev/null || true
got=$(wc -c < $sdir/chunk.bin | tr -d ' '); more=$(print -r -- "$r" | J -r '[.. | objects | select(has("content"))][0].truncated')
want=$((${tot:-0}-1000)); [ $want -gt 524288 ] && { want=524288; wantmore=true; } || wantmore=false
if [ -n "$dir" ] && [ "$got" = "$want" ] && [ "$more" = "$wantmore" ] && tail -c +1001 $sdir/po.bin | head -c $want | cmp -s - $sdir/chunk.bin; then chk "11 files.read offset without limit is capped at 512 KiB" ok
else chk "11 files.read offset without limit is capped at 512 KiB" bad "$want bytes from 1000, truncated=$wantmore" "got=$got truncated=$more"; fi
# files.read without offset or limit pages nothing: no total or next_offset
r=$(rpc '{"method":"files.read","params":{"path":"/etc/hosts"}}')
if [ "$(print -r -- "$r" | J '[.. | objects | select(has("content"))][0] | (has("total") or has("next_offset")) == false')" = true ]; then chk "11 files.read without offset or limit has no total or next_offset" ok
else chk "11 files.read without offset or limit has no total or next_offset" bad "no total, no next_offset" "$(print -r -- "$r" | J -c '[.. | objects | select(has("content"))][0] | keys')"; fi
# release
r=$(rpc "{\"method\":\"processes.output_release\",\"params\":{\"output_id\":\"$id\"}}")
rel=$(print -r -- "$r" | J -r '[.. | objects | select(has("released"))][0].released')
r=$(rpc "{\"method\":\"processes.output\",\"params\":{\"output_id\":\"$id\",\"stream\":\"stdout\"}}"); s=$(strs "$r"); c=$(cat "$hdr.code" 2>/dev/null || true)
if [ "$rel" = true ] && daemon_status "$c" && print -r -- "$r" | grep -qF '"not_found"' && print -r -- "$s" | grep -qF "$gone"; then chk "11 processes.output_release then processes.output fails" ok
else chk "11 processes.output_release then processes.output fails" bad "released true, then not_found $gone" "released=$rel status=$c '$s'"; fi
# capture ceiling: the child is drained and discarded, so it finishes before the timeout
cs=$(bigspawn ',"max_capture_bytes":1000')
if [ "$(rf "$cs" '.capture_truncated')" = true ] && [ "$(rf "$cs" '.stdout_total')" = 1000 ] && [ "$(rf "$cs" '.timed_out')" = false ] && [ "$(rf "$cs" '.exit_code')" = 0 ]; then chk "12 max_capture_bytes 1000 caps the capture before the timeout" ok
else chk "12 max_capture_bytes 1000 caps the capture before the timeout" bad "capture_truncated true, stdout_total 1000, timed_out false" "$(rf "$cs" '[.capture_truncated, .stdout_total, .timed_out] | @json')"; fi
# short output: nothing truncated, no spool handle
ss=$(rpc '{"method":"processes.spawn","params":{"executable":"ps","arguments":["-p","1","-o","pid="]}}')
sl=$(rf "$ss" '.stdout | utf8bytelength')
if [ "$(rf "$ss" '.stdout_truncated')" = false ] && [ "$(rf "$ss" '.stdout_total')" = "$sl" ] && [ "$(rf "$ss" '.capture_truncated')" = false ] \
   && [ "$(rf "$ss" '(.output_id // empty), (.output_dir // empty)')" = "" ]; then chk "13 short ps spawn: not truncated, no output_id or output_dir" ok
else chk "13 short ps spawn: not truncated, no output_id or output_dir" bad "flags false, stdout_total $sl, no output_id/output_dir" "$(rf "$ss" '@json')"; fi
# timed out: the spool is dropped, so no output_id or output_dir. `log stream` never ends by itself, so 100 ms always
# times it out; a full ps listing can finish inside 100 ms on a fast guest.
ts=$(rpc '{"method":"processes.spawn","params":{"executable":"log","arguments":["stream","--style","compact"],"timeout_ms":100}}')
if [ "$(rf "$ts" '.timed_out')" = true ] && [ "$(rf "$ts" '(.output_id // empty), (.output_dir // empty)')" = "" ]; then chk "13 timed-out spawn has no output_id or output_dir" ok
else chk "13 timed-out spawn has no output_id or output_dir" bad "timed_out true, no output_id/output_dir" "$(rf "$ts" '[.timed_out, .output_id, .output_dir] | @json')"; fi
# default capture with a small max_output_bytes: the cut is not a capture truncation
ds=$(bigspawn ',"max_output_bytes":100')
if [ "$(rf "$ds" '.capture_truncated')" = false ] && [ "$(rf "$ds" '.stdout_truncated')" = true ]; then chk "13 max_output_bytes 100 at default capture: capture_truncated false" ok
else chk "13 max_output_bytes 100 at default capture: capture_truncated false" bad "capture_truncated false, stdout_truncated true" "$(rf "$ds" '[.capture_truncated, .stdout_truncated] | @json')"; fi
# restart: spool dirs are removed when the daemon starts
rs=$(bigspawn); rid=$(rf "$rs" '.output_id // empty')
rpc '{"method":"services.kickstart","params":{"label":"com.vphone.vphoned","kill":true,"force":true}}' > /dev/null || true
back=0; end=$((SECONDS+30))
while [ $SECONDS -lt $end ]; do
  sleep 2
  [ "$(rpc '{"method":"time.clock"}' | J '[.. | objects | select(has("time") or has("unix") or has("epoch"))] | length > 0')" = true ] && { back=1; break; }
done
r=$(rpc "{\"method\":\"processes.output\",\"params\":{\"output_id\":\"$rid\",\"stream\":\"stdout\"}}"); s=$(strs "$r"); c=$(cat "$hdr.code" 2>/dev/null || true)
if [ -n "$rid" ] && [ $back = 1 ] && daemon_status "$c" && print -r -- "$r" | grep -qF '"not_found"' && print -r -- "$s" | grep -qF "$gone"; then chk "13 spool is gone after a vphoned restart" ok
else chk "13 spool is gone after a vphoned restart" bad "reconnect within 30 s, then not_found $gone" "id=$rid back=$back status=$c '$s'"; fi

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

# --- rpc-method-contracts: renamed method, ms timeouts, swipe/drag shapes, message beside error --------------------
# The handlers' clamps and mappings are private to the guest daemon, so they are checked here on the real dispatch.
# The names from before the renames still work (GuestLegacyNames): old params are translated, old result keys kept.
# q <method> <params> <jq filter>: the filter's output for the reply, e.g. `.result.count` or `.error.message`.
q() { rpc "{\"method\":\"$1\",\"params\":$2}" | J -r "$3"; }
# qc <label> <method> <params> <jq filter> <expected>
qc() { local g; g=$(q "$2" "$3" "$4"); [ "$g" = "$5" ] && chk "$1" ok || chk "$1" bad "$5" "$g"; }
# processes.spawn is dispatched, and so is its old name process.spawn.
qc "processes.spawn dispatched" processes.spawn '{"executable":"ps"}' '.result.executable' /bin/ps
qc "process.spawn still dispatched" process.spawn '{"executable":"ps"}' '.result.executable' /bin/ps
# timeout_ms is milliseconds, 100..10000 for processes.spawn. The old timeout_seconds is read as seconds and dropped when
# timeout_ms is sent too; names that were never the timeout are refused as unknown params.
for t in 100 10000; do qc "processes.spawn timeout_ms $t accepted" processes.spawn "{\"executable\":\"ps\",\"timeout_ms\":$t}" '.result.pid | type' number; done
for t in 99 10001; do qc "processes.spawn timeout_ms $t refused" processes.spawn "{\"executable\":\"ps\",\"timeout_ms\":$t}" '.error | [.code, .message, has("hint")] | tojson' '["invalid_param","timeout_ms must be 100–10000",false]'; done
qc "process.spawn timeout_seconds 10 is 10000 ms" process.spawn '{"executable":"ps","timeout_seconds":10}' '.result.pid | type' number
qc "processes.spawn timeout_seconds 11 is 11000 ms, refused" processes.spawn '{"executable":"ps","timeout_seconds":11}' '.error.message' 'timeout_ms must be 100–10000'
qc "processes.spawn timeout_ms wins over timeout_seconds" processes.spawn '{"executable":"ps","timeout_ms":1000,"timeout_seconds":99}' '.result.pid | type' number
for k in timeout timeout_s; do qc "processes.spawn $k refused as unknown" processes.spawn "{\"executable\":\"ps\",\"$k\":99999}" '.error.message' "Unknown param: $k"; done
# script.eval clamps to 1000..600000 ms: 1 ms becomes 1 s (the upper clamp would need a 10 minute script); the old
# timeout in seconds reaches the same clamp.
qc "script.eval timeout_ms 1 clamps to 1 s" script.eval '{"source":"while(true){}","timeout_ms":1}' '.error.message' 'The script did not finish within 1 seconds and was stopped'
qc "script.eval timeout 0.001 s clamps to 1 s" script.eval '{"source":"while(true){}","timeout":0.001}' '.error.message' 'The script did not finish within 1 seconds and was stopped'
# setup.settle clamps to 0..110000 ms and echoes timeout_ms, with timeout_s beside it (the upper clamp would need a 110 s wait).
qc "setup.settle timeout_ms 1000 echoes 1000 and timeout_s 1" setup.settle '{"timeout_ms":1000}' '.result | [.timeout_ms, .timeout_s] | tojson' '[1000,1]'
# poll_ms is milliseconds, 1000..30000 (fractions kept); the reply has elapsed_ms and poll_ms and the old _s keys.
# elapsed_ms is whole milliseconds. The loop sleeps only when the next poll fits the 2000 ms timeout, so a first
# sample slower than 500 ms answers after 1 poll; either way the bound below holds only in milliseconds.
qc "setup.settle poll_ms 1500 echoes 1500 with elapsed_ms" setup.settle '{"timeout_ms":2000,"poll_ms":1500}' '.result | (if .polls > 1 then 1500 else 500 end) as $b | [.poll_ms, (.elapsed_ms == (.elapsed_ms | floor)), (.elapsed_ms >= $b), .poll_s, (.elapsed_s * 1000 >= $b)] | tojson' '[1500,true,true,1.5,true]'
for p in '1|1000' '99999|30000'; do qc "setup.settle poll_ms ${p%|*} clamps to ${p#*|}" setup.settle "{\"timeout_ms\":0,\"poll_ms\":${p%|*}}" '.result.poll_ms' "${p#*|}"; done
qc "setup.settle poll_s 30 is 30000 ms" setup.settle '{"timeout_ms":0,"poll_s":30}' '.result | [.poll_ms, .poll_s] | tojson' '[30000,30]'
qc "setup.settle poll_ms wins over poll_s" setup.settle '{"timeout_ms":0,"poll_ms":2000,"poll_s":30}' '.result.poll_ms' 2000
qc "setup.settle poll_ms string refused" setup.settle '{"poll_ms":"5000"}' '.error | [.code, .message, .hint] | tojson' '["invalid_param","poll_ms must be a number","Pass poll_ms as a JSON number, not a string"]'
# the HTTP route follows the rename; the old route still answers.
for route in processes/spawn process/spawn; do
    [ "$(cu -o /dev/null -w '%{http_code}' -H "Content-Type: application/json" -d '{"executable":"ps"}' http://$addr/v1/$route)" = 200 ] && chk "POST /v1/$route answers" ok || chk "POST /v1/$route answers" bad 200 "not 200"
done
# input.swipe takes from/to, and x1..y2 as before; input.drag answers count, and points as before.
qc "input.swipe x1..y2 still accepted" input.swipe '{"x1":100,"y1":300,"x2":100,"y2":100}' '.result | [.from, .to] | tojson' '[[100,300],[100,100]]'
qc "input.swipe one-number from refused" input.swipe '{"from":[1],"to":[2,2]}' '.error.message' 'from and to must be [x, y] pairs'
qc "input.swipe from/to" input.swipe '{"from":[100,300],"to":[100,100]}' '.result | [.from, .to] | tojson' '[[100,300],[100,100]]'
qc "input.drag one point refused" input.drag '{"points":[[1,1]]}' '.error.message' 'points must be at least two [x, y] pairs'
qc "input.drag answers count and points" input.drag '{"points":[[100,300],[100,100]]}' '.result | [.count, .points] | tojson' '[2,2]'
# location.current honours timeout_ms (the 10 s default would outlast the 5 s bound). ui.wait is judged by its reply: one accessibility poll can take longer than any bound, and an unconverted 300 would be refused as over 60 s.
t0=$SECONDS; lr=$(rpc '{"method":"location.current","params":{"timeout_ms":300}}')
# An immediate location_services_off refusal never reaches the wait.
if print -r -- "$lr" | grep -q location_services_off; then echo "SKIP location.current timeout_ms: Location Services off"
else [ $((SECONDS - t0)) -lt 5 ] && chk "location.current timeout_ms honoured" ok || chk "location.current timeout_ms honoured" bad "under 5 s" "$((SECONDS - t0)) s"; fi
# screen.unlock checks timeout_ms (1000..60000) before it presses anything: 999 is refused, so the value is not read as
# seconds; the old timeout in seconds is converted first (0.5 s is 500 ms, refused the same way). Sent together, as
# the VM window and Launchpad do for an older vphoned, timeout_ms wins and timeout is not an unknown param.
qc "screen.unlock timeout_ms 999 refused" screen.unlock '{"timeout_ms":999}' '.error | [.code, .message] | tojson' '["invalid_param","timeout_ms must be 1000–60000"]'
qc "screen.unlock timeout 0.5 s is 500 ms, refused" screen.unlock '{"timeout":0.5}' '.error.message' 'timeout_ms must be 1000–60000'
qc "screen.unlock timeout_ms 999 wins over timeout 60" screen.unlock '{"timeout_ms":999,"timeout":60}' '.error.message' 'timeout_ms must be 1000–60000'
qc "ui.wait timeout_ms 300 is milliseconds" ui.wait '{"text":"__no_such_element__","timeout_ms":300}' '(.error.message // "") | contains("must be")' false
qc "ui.wait timeout 0.3 s is accepted" ui.wait '{"text":"__no_such_element__","timeout":0.3}' '(.error.message // "") | contains("must be")' false
# ui.wait and ui.wait_gone refuse timeout_ms outside 0..60000 in milliseconds; location.current refuses over 300000.
# Each refusal is a coded invalid_param whose message names the range, so it carries no hint.
for m in ui.wait ui.wait_gone; do for t in -1 60001; do qc "$m timeout_ms $t refused" $m "{\"text\":\"__no_such_element__\",\"timeout_ms\":$t}" '.error | [.code, .message, has("hint")] | tojson' '["invalid_param","timeout_ms must be 0–60000",false]'; done; done
qc "location.current timeout_ms 300001 refused" location.current '{"timeout_ms":300001}' '.error | [.code, .message, has("hint")] | tojson' '["invalid_param","timeout_ms must be more than 0 and at most 300000",false]'
# a failed status read carries `message`, and `error` with the same text for older clients.
# A DNS that answers every name (a fake-IP proxy) gives no failure to check.
r=$(q network.resolve '{"host":"no-such-host.invalid"}' '.result | if .status == "error" then ([has("message"), .error == .message] | tojson) else "answered: " + .status end')
case $r in
    answered:*) print "SKIP network.resolve failure message and error: the DNS $r no-such-host.invalid" ;;
    *) [ "$r" = '[true,true]' ] && chk "network.resolve failure message and error" ok || chk "network.resolve failure message and error" bad '[true,true]' "$r" ;;
esac
qc "script.eval failure message and error" script.eval '{"source":"("}' '.result | [has("message"), .error == .message] | tojson' '[true,true]'
# --- input observe --------------------
# Launches Settings (the Home Screen has no verifiable frontmost app, so ui.tree fails there). Mutating: taps the Settings status bar, presses
# keys and the home button. A failed step prints FAIL, never a silent skip.
# ob <jq-filter> <reply>: the filter applied to the reply's result object (empty when absent).
ob() { print -r -- "$2" | J -c "(.result // .) | $1"; }
OT='{"method":"ui.tree","params":{"visible_only":true,"max_elements":500}}'
rpc '{"method":"input.button","params":{"name":"home"}}' >/dev/null; sleep 2
# A freshly booted guest is locked and refuses to unlock for up to ~60 s; retry for up to 100 s.
for _ in $(seq 20); do [ "$(ob '.locked' "$(rpc '{"method":"screen.unlock"}')")" = false ] && break; sleep 5; done
rpc '{"method":"apps.launch","params":{"bundle_id":"com.apple.Preferences"}}' >/dev/null
tc0=
for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 2; tc0=$(ob '.count' "$(rpc "$OT")"); case $tc0 in ''|*[!0-9]*|0) ;; *) break ;; esac; done
sx=196; sy=60
case $tc0 in ''|*[!0-9]*|0) chk "9 Settings ui.tree has elements" bad "an integer > 0" "${tc0:-none}" ;; *) chk "9 Settings ui.tree has elements" ok ;; esac
# The tap is a harmless status-bar tap in Settings.
# without observe a tap returns exactly {x, y}.
r=$(rpc "{\"method\":\"input.tap\",\"params\":{\"x\":$sx,\"y\":$sy}}")
z=$(ob 'keys | sort' "$r")
[ "$z" = '["x","y"]' ] && chk "9 input.tap without observe returns exactly x,y" ok || chk "9 input.tap without observe returns exactly x,y" bad '["x","y"]' "${z:-no reply}"
sleep 1
# observed tap on Settings keeps x,y and adds observed.
r=$(rpc "{\"method\":\"input.tap\",\"params\":{\"x\":$sx,\"y\":$sy,\"observe\":true}}")
[ "$(ob 'keys | sort' "$r")" = '["observed","x","y"]' ] && chk "9 input.tap observe keeps x,y and adds observed" ok || chk "9 input.tap observe keeps x,y and adds observed" bad '["observed","x","y"]' "$(ob 'keys | sort' "$r")"
z=$(ob '.observed.frontmost_bundle_id' "$r")
[ "$z" = '"com.apple.Preferences"' ] && chk "9 observed.frontmost_bundle_id is com.apple.Preferences" ok || chk "9 observed.frontmost_bundle_id is com.apple.Preferences" bad '"com.apple.Preferences"' "${z:-none}"
z=$(ob '.observed.frontmost_verified' "$r")
[ "$z" = true ] && chk "9 observed.frontmost_verified is true" ok || chk "9 observed.frontmost_verified is true" bad true "${z:-none}"
oc=$(ob '.observed.ui_element_count' "$r")
case $oc in ''|*[!0-9]*|0) chk "9 observed.ui_element_count > 0" bad "an integer > 0" "${oc:-none}" ;; *) chk "9 observed.ui_element_count > 0" ok ;; esac
# a ui.tree call just after reports the same count.
tc=$(ob '.count' "$(rpc "$OT")")
[ -n "$oc" ] && [ "$oc" = "$tc" ] && chk "9 observed.ui_element_count equals ui.tree count" ok || chk "9 observed.ui_element_count equals ui.tree count" bad "$oc" "${tc:-none}"
# input.key with and without observe (a letter key: harmless on any screen).
r=$(rpc '{"method":"input.key","params":{"name":"a"}}')
z=$(ob 'keys | sort' "$r")
[ "$z" = '["dispatched","key"]' ] && chk "9 input.key without observe has no observed" ok || chk "9 input.key without observe has no observed" bad '["dispatched","key"]' "${z:-no reply}"
r=$(rpc '{"method":"input.key","params":{"name":"a","observe":true}}')
z=$(ob 'keys | sort' "$r")
[ "$z" = '["dispatched","key","observed"]' ] && chk "9 input.key observe adds observed" ok || chk "9 input.key observe adds observed" bad '["dispatched","key","observed"]' "${z:-no reply}"
z=$(ob '.observed | (.frontmost_bundle_id | type) + " " + (.frontmost_verified | type) + " " + (.ui_element_count | type)' "$r")
[ "$z" = '"string boolean number"' ] && chk "9 input.key observed field types" ok || chk "9 input.key observed field types" bad '"string boolean number"' "${z:-none}"
# a failed action returns its own error and no observed.
r=$(rpc '{"method":"input.key","params":{"name":"no-such-key"}}'); e1=$(strs "$r")
r=$(rpc '{"method":"input.key","params":{"name":"no-such-key","observe":true}}'); e2=$(strs "$r")
z=$(print -r -- "$r" | J '[.. | objects | select(has("observed"))] | length')
if [ -n "$e2" ] && [ "$e1" = "$e2" ] && [ "$z" = 0 ]; then chk "9 input.key invalid name with observe: same error, no observed" ok
else chk "9 input.key invalid name with observe: same error, no observed" bad "the unobserved error and no observed" "plain='$e1' observe='$e2' observed=${z:-?}"; fi
# delay 5001 is refused before the action runs: the home button must not run, so the screen is unchanged.
b=$(ob '.count' "$(rpc "$OT")")
r=$(rpc '{"method":"input.button","params":{"name":"home","observe":true,"observe_delay_ms":5001}}')
strs "$r" | grep -qxF 'observe_delay_ms must be an integer from 0 to 5000' && chk "9 observe_delay_ms 5001 is invalid-request" ok || chk "9 observe_delay_ms 5001 is invalid-request" bad "observe_delay_ms must be an integer from 0 to 5000" "$(strs "$r")"
sleep 1; a=$(ob '.count' "$(rpc "$OT")")
[ -n "$b" ] && [ "$b" = "$a" ] && chk "9 delay 5001 leaves the screen unchanged" ok || chk "9 delay 5001 leaves the screen unchanged" bad "$b" "${a:-none}"
# observe passes the unknown-param check; any other undeclared param is still refused before the action.
r=$(rpc '{"method":"input.button","params":{"name":"home","observe":true,"bogus":1}}')
z=$(print -r -- "$r" | J -r '[.error.code, .error.message] | join(" ")')
[ "$z" = 'invalid_param Unknown param: bogus' ] && chk "9 input.button observe with a bogus param is Unknown param: bogus" ok || chk "9 input.button observe with a bogus param is Unknown param: bogus" bad 'invalid_param Unknown param: bogus' "${z:-none}"
rpc '{"method":"input.button","params":{"name":"home"}}' >/dev/null
# Catalog: exactly the 15 input.* methods, each declaring observe, observe_delay_ms and the observed result key.
rc=$(rpc '{"method":"methods.list"}')
n=$(print -r -- "$rc" | J -r "$L"' | [.[] | select(.name | startswith("input."))] | length')
z=$(print -r -- "$rc" | J -r "$L"' | [.[] | select(.name | startswith("input.")) | select(([.params[].name] | index("observe")) != null and ([.params[].name] | index("observe_delay_ms")) != null and ([.result[].name] | index("observed")) != null) | .name | ltrimstr("input.")] | sort | join(",")')
want=button,double_tap,drag,hid,key,long_press,paste,pointer,scroll,swipe,tap,touch,touch2,touch_sequence,type
[ "$n" = 15 ] && [ "$z" = "$want" ] && chk "9 methods.list has 15 input.* methods with observe, observe_delay_ms, observed" ok || chk "9 methods.list has 15 input.* methods with observe, observe_delay_ms, observed" bad "15 input.* methods: $want" "n=${n:-none} with=${z:-none}"

# --- schema comparison of every read-class method ---------------------------
schema_section
[ $stop_unresponsive = 0 ] || { finish || true; exit 1; }
finish
