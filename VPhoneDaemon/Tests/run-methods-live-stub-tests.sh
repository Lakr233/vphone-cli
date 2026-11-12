#!/bin/zsh
set -u

# Drives the schema-comparison section of run-methods-live.zsh against a local stub HTTP server (python3 -I)
# and a fixture catalog. No VM, no guest: the script's VPHONE_LIVE_BASE_URL seam replaces the VM launch.
# Each case mutates the stub's replies and asserts the exact output lines, exit code and call log.

here=${0:a:h}
live=$here/run-methods-live.zsh
work=$(mktemp -d)
stubdir=$work/stub; tmpd=$work/tmp; mkdir -p "$stubdir" "$tmpd"
spid=
trap 'kill -9 $spid 2>/dev/null; rm -rf "$work"' EXIT
token=tok-$RANDOM$RANDOM
sentinel=SENTINEL-$RANDOM-$RANDOM-zq

cat > "$stubdir/stub.py" <<'PY'
# argv: scenario.json calllog portfile token
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
scn = json.load(open(sys.argv[1])); logp, portp, token = sys.argv[2], sys.argv[3], sys.argv[4]
seen = {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, status, body):
        self.send_response(status); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); req = json.loads(self.rfile.read(n) or b"{}")
        if self.headers.get("Authorization") != "Bearer " + token:
            return self.send(401, b"{}")
        m = req.get("method", "")
        with open(logp, "a") as f: f.write(m + "\n")
        s = scn.get(m)
        if s is None: return self.send(400, json.dumps({"type": "response", "error": {"code": "unknown_method", "message": "Unknown method"}}).encode())
        if isinstance(s, list):
            n = seen.get(m, 0); seen[m] = n + 1; s = s[min(n, len(s) - 1)]
        if "drop" in s:
            self.close_connection = True; return
        if "stall" in s:
            time.sleep(s["stall"]); return
        if "raw" in s: return self.send(200, s["raw"].encode())
        if "json" in s: return self.send(s.get("status", 200), json.dumps(s["json"]).encode())
        if "error" in s: return self.send(400, json.dumps({"type": "response", "error": s["error"]}).encode())
        if "pad" in s:
            base = '{"type":"response","result":{"a":"%s"}}'
            return self.send(200, (base % ("x" * (s["pad"] - len(base % "")))).encode())
        self.send(200, json.dumps({"type": "response", "id": "1", "result": s["result"]}).encode())
srv = ThreadingHTTPServer(("127.0.0.1", 0), H); srv.daemon_threads = True
open(portp, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY

pass=0; fail=0; case_name=
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL [$case_name] $1"; }
has() { grep -qxF -- "$1" "$work/out" && ok || { bad "missing line: $1"; sed 's/^/    out: /' "$work/out"; }; }
hasnt() { grep -qF -- "$1" "$work/out" && bad "unexpected: $1" || ok; }
rc_is() { [ "$rc" = "$1" ] && ok || bad "exit $rc, wanted $1"; }
last_is() { [ "$(tail -n 1 "$work/out")" = "$1" ] && ok || bad "last line '$(tail -n 1 "$work/out")', wanted '$1'"; }
calls_are() { [ "$(tr '\n' ' ' < "$work/calls")" = "$1" ] && ok || bad "calls '$(tr '\n' ' ' < "$work/calls")', wanted '$1'"; }

# stub_start '<scenario json>'; sets base.
stub_start() {
  print -r -- "$1" > "$stubdir/scn.json"; : > "$work/calls"; rm -f "$stubdir/port"
  python3 -I "$stubdir/stub.py" "$stubdir/scn.json" "$work/calls" "$stubdir/port" "$token" &
  spid=$!
  local i=0; while [ ! -s "$stubdir/port" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  base=http://127.0.0.1:$(cat "$stubdir/port")
}
stub_stop() { kill -9 $spid 2>/dev/null; wait $spid 2>/dev/null; spid=; }
# run_live [VAR=value ...]: runs the script against the stub; fills out, err, rc.
run_live() {
  env VPHONE_LIVE_BASE_URL=$base VPHONE_LIVE_TOKEN=$token VPHONE_LIVE_CATALOG=$work/cat.tsv TMPDIR=$tmpd "$@" \
    zsh "$live" > "$work/out" 2> "$work/err"; rc=$?
}
# case_run <name> <scenario json> <env...>: starts the stub, runs, stops the stub.
case_run() { case_name=$1; stub_start "$2"; shift 2; run_live "$@"; stub_stop; }

# --- single-reply mutations ---------------------------------------------------
catalog_one() { printf '%s\tnever\t-\t-\t%s\tread\n' "$1" "$2" > "$work/cat.tsv"; }

catalog_one m 'a:string,b:integer?'
case_run conforming '{"m":{"result":{"a":"x","b":3}}}'
has 'PASS m'; has '1 passed, 0 failed'; last_is '1 passed, 0 failed'; rc_is 0
case_run optional-absent '{"m":{"result":{"a":"x"}}}'; has 'PASS m'; rc_is 0
case_run undeclared '{"m":{"result":{"a":"x","z":1}}}'; has 'FAIL m: z undeclared'; last_is '0 passed, 1 failed'; rc_is 1
case_run missing '{"m":{"result":{"b":1}}}'; has 'FAIL m: a missing'; rc_is 1
catalog_one m 'a:integer'
case_run wrong-type '{"m":{"result":{"a":"x"}}}'; has 'FAIL m: a expected integer got string'
case_run integer-fraction '{"m":{"result":{"a":1.5}}}'; has 'FAIL m: a expected integer got number'
case_run array-vs-int '{"m":{"result":{"a":[]}}}'; has 'FAIL m: a expected integer got array'
catalog_one m 'a:number'
case_run number-key-1 '{"m":{"result":{"a":1}}}'; has 'PASS m'; rc_is 0
catalog_one m 'a:string'
case_run string-null '{"m":{"result":{"a":null}}}'; has 'FAIL m: a expected string got null'
catalog_one m 'a:any'
case_run any-null '{"m":{"result":{"a":null}}}'; has 'PASS m'
catalog_one m '-'
case_run empty-schema '{"m":{"result":{}}}'; has 'PASS m'
case_run empty-schema-extra '{"m":{"result":{"q":1}}}'; has 'FAIL m: q undeclared'
catalog_one m 'a:string,h:string~'
case_run hidden-absent '{"m":{"result":{"a":"x"}}}'; has 'PASS m'
case_run hidden-present '{"m":{"result":{"a":"x","h":"y"}}}'; has 'FAIL m: h undeclared'
catalog_one m 'a:object*'
case_run open-object '{"m":{"result":{"a":{"deep":1}}}}'; has 'PASS m'

catalog_one m 'a:string'
case_run non-json '{"m":{"raw":"not json"}}'; has 'FAIL m: unparsable reply'
case_run top-array '{"m":{"raw":"[1,2]"}}'; has 'FAIL m: unparsable reply'
case_run no-result '{"m":{"raw":"{\"type\":\"response\"}"}}'; has 'FAIL m: unparsable reply'
case_run unknown-method '{}'; has 'FAIL m: error unknown_method'; rc_is 1
case_run error-code '{"m":{"error":{"code":"a\nPASS x","message":"boom"}}}'
has 'FAIL m: error a\x0aPASS x'; { grep -qx 'PASS x' "$work/out" && bad 'PASS x line' || ok; }; [ "$(grep -c '^FAIL m' "$work/out")" = 1 ] && ok || bad 'not one FAIL line'
case_run escaped-key '{"m":{"result":{"a":"x","a\nPASS x":1}}}'
has 'FAIL m: a\x0aPASS x undeclared'; [ "$(grep -c '^PASS' "$work/out")" = 0 ] && ok || bad 'PASS line printed'
longkey=$(printf 'k%.0s' {1..80}); k64=$(printf 'k%.0s' {1..64})
case_run long-key "{\"m\":{\"result\":{\"a\":\"x\",\"$longkey\":1}}}"; has "FAIL m: $k64 undeclared"
case_run unicode-key '{"m":{"result":{"a":"x","é":1}}}'; has 'FAIL m: \xc3\xa9 undeclared'

case_run size-ok '{"m":{"pad":1048576}}'; has 'PASS m'; rc_is 0
case_run size-over '{"m":{"pad":1048577}}'; has 'FAIL m: reply too large'; rc_is 1

# --- sentinel never reaches stdout, stderr or the script's temp dir -------------
catalog_one m 'a:integer'
case_run sentinel "{\"m\":{\"result\":{\"a\":\"$sentinel\"}}}"
has 'FAIL m: a expected integer got string'
if grep -rqF -- "$sentinel" "$work/out" "$work/err" "$tmpd"; then bad 'sentinel found'; else ok; fi
[ -z "$(ls -A "$tmpd")" ] && ok || bad "temp dir not cleaned: $(ls -A "$tmpd")"
case_run sentinel-error "{\"m\":{\"error\":{\"code\":\"E1\",\"message\":\"$sentinel\"}}}"
has 'FAIL m: error E1'; if grep -rqF -- "$sentinel" "$work/out" "$work/err" "$tmpd"; then bad 'sentinel found (error)'; else ok; fi

# --- transport failures ---------------------------------------------------------
rows() { : > "$work/cat.tsv"; local x; for x in "$@"; do printf '%s\tnever\t-\t-\ta:string\t%s\n' "${x%%=*}" "${x#*=}" >> "$work/cat.tsv"; done; }

rows m1=read m2=read m3=read m4=read
case_name=closed-port; stub_start '{}'; stub_stop
run_live
has 'FAIL m1: transport connect'; has 'FAIL guest unresponsive'; last_is '0 passed, 3 failed'; rc_is 1
grep -qE '^[0-9]+ passed, [0-9]+ failed$' "$work/out" && ok || bad 'summary format'; hasnt 'm4'
case_run wrong-token '{"m1":{"result":{"a":"x"}}}' VPHONE_LIVE_TOKEN=nope
has 'FAIL m1: transport HTTP 401'; has 'FAIL guest unresponsive'; last_is '0 passed, 3 failed'; rc_is 1

# --- stalls and the consecutive-failure rule ------------------------------------
S='{"stall":20}'; G='{"result":{"a":"x"}}'; B='{"result":{"a":1}}'
rows m1=read m2=read
case_run stall-continues "{\"m1\":$S,\"m2\":$G}" VPHONE_LIVE_TIMEOUT=1
has 'FAIL m1: timeout'; has 'PASS m2'; last_is '1 passed, 1 failed'; rc_is 1; hasnt unresponsive
rows m1=read m2=read m3=read m4=read
case_run three-stalls "{\"m1\":$S,\"m2\":$S,\"m3\":$S,\"m4\":$G}" VPHONE_LIVE_TIMEOUT=1
has 'FAIL m3: timeout'; has 'FAIL guest unresponsive'; last_is '0 passed, 3 failed'; rc_is 1; calls_are 'm1 m2 m3 '
case_run three-mismatch-then-pass "{\"m1\":$B,\"m2\":$B,\"m3\":$B,\"m4\":$G}"
has 'FAIL m1: a expected string got integer'; has 'FAIL m3: a expected string got integer'; has 'PASS m4'
hasnt unresponsive; [ "$(wc -l < "$work/out" | tr -d ' ')" = 5 ] && ok || bad 'want 3 FAIL + PASS + summary'; last_is '1 passed, 3 failed'; rc_is 1
rows m1=read m2=read m3=read m4=read m5=read
case_run fail-fail-pass-fail-fail "{\"m1\":$S,\"m2\":$S,\"m3\":$G,\"m4\":$S,\"m5\":$S}" VPHONE_LIVE_TIMEOUT=1
hasnt unresponsive; calls_are 'm1 m2 m3 m4 m5 '; last_is '1 passed, 4 failed'; rc_is 1
case_run error-resets "{\"m1\":$S,\"m2\":$S,\"m3\":{\"error\":{\"code\":\"E\"}},\"m4\":$S,\"m5\":$S}" VPHONE_LIVE_TIMEOUT=1
hasnt unresponsive; calls_are 'm1 m2 m3 m4 m5 '
case_run toolarge-resets "{\"m1\":$S,\"m2\":$S,\"m3\":{\"pad\":1048577},\"m4\":$S,\"m5\":$S}" VPHONE_LIVE_TIMEOUT=1
hasnt unresponsive; calls_are 'm1 m2 m3 m4 m5 '

# --- only read rows are called ----------------------------------------------------
rows m1=read m2=mutating m3=excluded:needs-network m4=read
case_run call-log "{\"m1\":$G,\"m4\":$G}"
calls_are 'm1 m4 '; has 'PASS m1'; has 'PASS m4'; last_is '2 passed, 0 failed'; rc_is 0

# --- unforced force-gated call: a guest-closed reply is retried once -------------
U=VPHONE_LIVE_UNFORCED_CHECK=1
REF='{"error":{"code":"force_required","message":"Pass force: true to reboot the guest"}}'
DROP='{"drop":true}'
GC='{"status":502,"json":{"type":"response","id":null,"error":{"code":"guest_closed","message":"Guest closed the connection without a reply"}}}'
RT='RETRY system.reboot {}: guest closed without a reply'; LK='LEAK: system.reboot was not refused unforced; stopping'
case_run refusal-first "{\"system.reboot\":$REF}" $U
has 'PASS system.reboot {}'; hasnt RETRY; hasnt LEAK; rc_is 0; calls_are 'system.reboot '
case_run drop-then-refusal "{\"system.reboot\":[$DROP,$REF]}" $U
has "$RT"; has 'PASS system.reboot {}'; hasnt LEAK; rc_is 0; calls_are 'system.reboot system.reboot '
case_run 502-then-refusal "{\"system.reboot\":[$GC,$REF]}" $U
has "$RT"; has 'PASS system.reboot {}'; hasnt LEAK; rc_is 0; calls_are 'system.reboot system.reboot '
case_run drop-twice "{\"system.reboot\":[$DROP,$DROP,$REF]}" $U
has "$RT"; has "$LK"; rc_is 1; calls_are 'system.reboot system.reboot '
case_run result-first "{\"system.reboot\":{\"result\":{}}}" $U
hasnt RETRY; has "$LK"; rc_is 1; calls_are 'system.reboot '
case_run 502-other "{\"system.reboot\":{\"status\":502,\"json\":{\"type\":\"response\",\"error\":{\"code\":\"internal\",\"message\":\"x\"}}}}" $U
hasnt RETRY; has "$LK"; rc_is 1; calls_are 'system.reboot '

# --- usage -------------------------------------------------------------------------
rows m1=read
for v in abc 0 -1 1.5 ''; do
  case_run "timeout-$v" "{\"m1\":$G}" "VPHONE_LIVE_TIMEOUT=$v"
  [ "$(cat "$work/err")" = "invalid VPHONE_LIVE_TIMEOUT $v; set a positive integer number of seconds" ] && ok || bad "message for '$v': $(cat "$work/err")"
  rc_is 2; calls_are ''
done
case_name=help; zsh "$live" --help > "$work/out" 2> "$work/err"; rc=$?; rc_is 0; grep -q VPHONE_LIVE_TIMEOUT "$work/out" && ok || bad 'help text'

echo "stub tests: $pass passed, $fail failed"
[ $fail = 0 ]
