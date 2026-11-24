#!/bin/zsh
# vphone-tier: live
# Real-VM test of `vphone-cli vm launch --detach`.
# Usage: run-detach-launch-live.sh <vm-name>
# The VM must exist in the default library ($VPHONE_LIBRARY_ROOT, else
# ~/.vphone/machines) and be stopped. Set VPHONE_CLI to
# the vphone-cli under test; the default is the workspace VPhone build.
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    print -u2 "usage: ${0:t} <vm-name>"
    exit 2
fi
name="$1"

# ---- guard 1: validate the VM name before it reaches any path/pgrep pattern -
if [[ ! "$name" =~ '^[A-Za-z0-9][A-Za-z0-9_-]*$' ]]; then
    print -u2 "error: invalid VM name '$name' (allowed: letters, digits, '_' and '-'; must not start with '_' or '-')"
    exit 2
fi

root="$(cd "${0:a:h}/../../.." && pwd)"
cli="${VPHONE_CLI:-$root/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli}"
[[ -x "$cli" ]] || { print -u2 "vphone-cli not found: $cli"; exit 2; }

library="${VPHONE_LIBRARY_ROOT:-$HOME/.vphone/machines}"
vmdir="$library/$name"
[[ -d "$vmdir" ]] || { print -u2 "no VM '$name' in $library"; exit 2; }
logs="$HOME/Library/Logs/vphone-launchpad"
log="$logs/$name.log"
config="$vmdir/config.plist"
bgpids=()
started=0
probe_tool=""

# ---- helpers ---------------------------------------------------------------

vm_pids() { pgrep -f "vphone-vm --config $config" 2>/dev/null || true; }

# ping_ok: 0 = vphoned answered, 1 = no answer. A missing probe helper is a
# hard error (exit 2), never read as "no answer".
ping_ok() {
    [[ -x "$probe_tool" ]] || { print -u2 "probe helper missing at $probe_tool"; exit 2; }
    "$probe_tool" ping "$vmdir/vphone.sock"
}

sid_of() { "$probe_tool" sid "$1"; }
size_of() { stat -f %z "$1" 2>/dev/null || echo 0; }

# wait_for <seconds> <command...>: poll once a second until the command succeeds.
wait_for() {
    local limit=$1; shift
    local i=0
    while (( i < limit )); do
        "$@" && return 0
        sleep 1; (( i += 1 ))
    done
    return 1
}

disk_holders() { lsof -t -- "$vmdir/Disk.img" 2>/dev/null | head -1; }
vm_gone() { [[ -z "$(vm_pids)" && -z "$(disk_holders)" ]]; }

stop_vm() {
    "$cli" vm stop "$name" >/dev/null 2>&1
    wait_for 60 vm_gone
}

# launch <tag> [args...]: foreground detach launch, files $work/<tag>.{out,err,rc}.
launch() {
    local tag=$1; shift
    started=1
    local rc=0
    "$cli" vm launch "$name" --detach "$@" >"$work/$tag.out" 2>"$work/$tag.err" || rc=$?
    print -r -- $rc >"$work/$tag.rc"
}
# launch_bg <tag> [args...]: the same, in the background.
launch_bg() {
    local tag=$1; shift
    started=1
    ( launch "$tag" "$@" ) &
    bgpids+=($!)
    lastbg=$!
}
rc_of() { cat "$work/$1.rc" 2>/dev/null || echo "?"; }

cleanup() {
    set +e
    for p in $bgpids; do kill $p 2>/dev/null; done
    if (( started )); then
        "$cli" vm stop "$name" >/dev/null 2>&1 || true
        wait_for 30 vm_gone
    fi
    chmod -R u+w "$work" 2>/dev/null
    rm -rf "$work"
}

typeset -A result
order=()
failed=0
cur=""
curfail=()
case_begin() { cur="$1"; curfail=(); order+=("$1"); print -- "--- $1"; }
check() { # check <description> <command...>
    local d=$1; shift
    if ! "$@"; then curfail+=("$d"); print "    FAIL: $d"; fi
}
case_end() {
    if (( ${#curfail} == 0 )); then result[$cur]=PASS; else result[$cur]=FAIL; failed=1; fi
    print "$result[$cur] $cur"
}
has() { grep -qF -- "$2" "$1"; }          # has <file> <text>
hasre() { grep -qE -- "$2" "$1"; }         # hasre <file> <regex>
eq() { [[ "$1" == "$2" ]]; }
ne() { [[ "$1" != "$2" ]]; }
ge() { (( $1 >= $2 )); }
gt() { (( $1 > $2 )); }

print "commit: $(git -C "$root" rev-parse HEAD)"
print "cli: $cli"
print "vm: $name"

# ---- guard 2: destructive opt-in -------------------------------------------
if [[ "${VPHONE_LIVE_DESTRUCTIVE:-}" != "$name" ]]; then
    print -u2 "############################################################"
    print -u2 "# REFUSING to run: this is a DESTRUCTIVE live test on VM '$name'."
    print -u2 "# Against VM '$name' it will:"
    print -u2 "#   - kill this VM's processes (vphone-vm/vphone-cli for '$name')"
    print -u2 "#   - truncate this VM's console log: $log"
    if [[ -z "${VPHONE_LIVE_DESTRUCTIVE:-}" ]]; then
        print -u2 "# VPHONE_LIVE_DESTRUCTIVE is not set."
    else
        print -u2 "# VPHONE_LIVE_DESTRUCTIVE='${VPHONE_LIVE_DESTRUCTIVE}' does not match '$name'."
    fi
    print -u2 "# To proceed, re-run with:  VPHONE_LIVE_DESTRUCTIVE=$name ${0:t} $name"
    print -u2 "############################################################"
    exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/detach-live.XXXXXX")"
probe_tool="$work/probe"

# ---- probe helper (ping + getsid), compiled once into $work -----------------
# Replaces the former scripted ping heredoc and os.getsid lookup: deterministic,
# interpreter-free, and getsid via `ps` is not portable on macOS.
cat > "$work/probe.c" <<'C'
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>

/* probe ping <sockpath>: connect the unix socket, send {"t":"ping","screen":false}\n,
   read the reply's first line; exit 0 only when that line (whitespace stripped)
   begins {"ok":true, or equals {"ok":true} (top-level ok == JSON true). A single
   2 s deadline (SO_SNDTIMEO/SO_RCVTIMEO) covers connect, send and read; the reply
   read is capped at 4096 bytes. Timeout, EOF before a newline, an oversize reply,
   or any socket error exits 1.
   probe sid <pid>: print getsid(pid) and a newline; exit 1 on error. */

static int do_ping(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 1;
    struct timeval tv;
    tv.tv_sec = 2; tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr.sun_path) { close(fd); return 1; }
    strncpy(addr.sun_path, path, sizeof addr.sun_path - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) { close(fd); return 1; }
    const char *msg = "{\"t\":\"ping\",\"screen\":false}\n";
    size_t off = 0, mlen = strlen(msg);
    while (off < mlen) {
        ssize_t w = write(fd, msg + off, mlen - off);
        if (w <= 0) { close(fd); return 1; }
        off += (size_t)w;
    }
    char buf[4096];
    size_t len = 0;
    int have_nl = 0;
    while (len < sizeof buf) {
        ssize_t r = read(fd, buf + len, sizeof buf - len);
        if (r <= 0) { close(fd); return 1; }   /* timeout or EOF before newline */
        size_t start = len;
        len += (size_t)r;
        for (size_t i = start; i < len; i++) {
            if (buf[i] == '\n') { len = i; have_nl = 1; break; }
        }
        if (have_nl) break;
    }
    close(fd);
    if (!have_nl) return 1;                      /* oversize reply, no newline in 4 KiB */
    size_t s = 0, e = len;                        /* strip surrounding whitespace */
    while (s < e && isspace((unsigned char)buf[s])) s++;
    while (e > s && isspace((unsigned char)buf[e - 1])) e--;
    size_t n = e - s;
    const char *line = buf + s;
    const char *full = "{\"ok\":true}";
    const char *pref = "{\"ok\":true,";
    if (n == strlen(full) && memcmp(line, full, n) == 0) return 0;
    if (n >= strlen(pref) && memcmp(line, pref, strlen(pref)) == 0) return 0;
    return 1;
}

static int do_sid(const char *s) {
    char *end;
    long pid = strtol(s, &end, 10);
    if (end == s || *end) return 1;
    pid_t sid = getsid((pid_t)pid);
    if (sid < 0) return 1;
    printf("%d\n", (int)sid);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "ping") == 0) return do_ping(argv[2]);
    if (argc == 3 && strcmp(argv[1], "sid") == 0) return do_sid(argv[2]);
    fprintf(stderr, "usage: probe ping <sockpath> | probe sid <pid>\n");
    return 64;
}
C
/usr/bin/clang -o "$probe_tool" "$work/probe.c" 2>"$work/probe-build.txt" || {
    print -u2 "probe helper failed to compile:"
    cat "$work/probe-build.txt" >&2
    rm -rf "$work"
    exit 2
}

# ---- guard 3: refuse if the VM is already running (opt-in is for a stopped VM) -
if [[ -n "$(vm_pids)" ]] || ping_ok; then
    print -u2 "VM '$name' is already running; stop it first"
    rm -rf "$work"
    exit 2
fi

# ---- guard 4: install cleanup only now that the guard has passed ------------
trap cleanup EXIT

# ---- case 1: launch --------------------------------------------------------
case_begin "1 launch"
launch c1
pid="$(sed -n 's/^pid //p' "$work/c1.out" | head -1)"
check "exit 0" eq "$(rc_of c1)" 0
check "stdout line 1 is 'pid <n>'" hasre "$work/c1.out" '^pid [0-9]+$'
check "stdout line 2 is 'log <path>'" eq "$(sed -n 2p "$work/c1.out")" "log $log"
check "stdout is pid, log, vphoned answered only" eq "$(grep -cvE '^(pid [0-9]+|log /.*|vphoned answered after [0-9]+s)$' "$work/c1.out")" 0
check "vphoned answered line" hasre "$work/c1.out" '^vphoned answered after [0-9]+s$'
check "stderr empty" eq "$(size_of "$work/c1.err")" 0
check "ping answers" wait_for 10 ping_ok
check "pid session differs from the shell's" ne "$(sid_of "${pid:-0}")" "$(sid_of $$)"
check "pid session found" test -n "$(sid_of "${pid:-0}")"
check "log non-empty" gt "$(size_of "$log")" 0
case_end

# ---- case 2: stop ----------------------------------------------------------
case_begin "2 stop"
check "vm stop" stop_vm
check "no VM process left" vm_gone
case_end

# ---- case 3: --timeout 1 ---------------------------------------------------
case_begin "3 timeout"
launch c3 --timeout 1
check "exit 1" eq "$(rc_of c3)" 1
check "stderr: did not answer within 1s" has "$work/c3.err" "vphoned did not answer within 1s; \`$name\` is still running (pid "
check "stderr: names the log" has "$work/c3.err" "$log"
check "stderr: stop hint" has "$work/c3.err" "vphone-cli vm stop $name"
check "stdout has no vphoned answered" eq "$(grep -c 'vphoned answered' "$work/c3.out")" 0
check "VM is alive" test -n "$(vm_pids)"
check "stop" stop_vm
case_end

# ---- case 4: second launch of an answering VM ------------------------------
case_begin "4 in use (answering)"
launch c4a
check "first launch exit 0" eq "$(rc_of c4a)" 0
before="$(size_of "$log")"
launch c4b
check "second launch exit 1" eq "$(rc_of c4b)" 1
check "stderr: is running" has "$work/c4b.err" "VM '$name' is running"
check "no pid line" eq "$(grep -c '^pid ' "$work/c4b.out")" 0
check "VM still answers" wait_for 10 ping_ok
check "log did not shrink" ge "$(size_of "$log")" "$before"
check "stop" stop_vm
case_end

# ---- case 5: second launch while the VM is up but vphoned is not -----------
up_with_log() { [[ -n "$(vm_pids)" ]] && (( $(size_of "$log") > 0 )); }
case_begin "5 in use (held, not answering)"
launch_bg c5a
first=$lastbg
if wait_for 120 up_with_log && ! ping_ok; then
    before="$(size_of "$log")"
    launch c5b
    check "second launch exit 1" eq "$(rc_of c5b)" 1
    check "stderr: refused as running or in use" hasre "$work/c5b.err" "VM '$name' is (running|in use)"
    check "no pid line" eq "$(grep -c '^pid ' "$work/c5b.out")" 0
    check "log did not shrink" ge "$(size_of "$log")" "$before"
else
    curfail+=("VM process did not come up unanswering (or vphoned answered first)")
    print "    FAIL: ${curfail[-1]}"
fi
wait $first 2>/dev/null || true
check "first launch exit 0" eq "$(rc_of c5a)" 0
check "VM answers" wait_for 10 ping_ok
check "stop" stop_vm
case_end

# ---- case 6: VM killed before vphoned answers ------------------------------
case_begin "6 VM exits"
launch_bg c6
first=$lastbg
vm_pids_up() { [[ -n "$(vm_pids)" ]]; }
if wait_for 120 vm_pids_up && ! ping_ok; then
    # The spawned pid is the vphone-cli that runs vphone-vm (it relays the VM's
    # exit status), so kill both to make the spawned pid die by the signal.
    vmpid="$(vm_pids | head -1)"
    kill -9 "$(ps -o ppid= -p "$vmpid" | tr -d ' ')" "$vmpid" 2>/dev/null || true
else
    curfail+=("VM process did not come up unanswering")
    print "    FAIL: ${curfail[-1]}"
fi
wait $first 2>/dev/null || true
check "exit 1" eq "$(rc_of c6)" 1
check "stderr: stopped before vphoned answered" has "$work/c6.err" "stopped before vphoned answered"
check "stderr: names the log" has "$work/c6.err" "$log"
check "stderr: signal 9" has "$work/c6.err" "signal 9"
check "stderr: log tail lines follow the log path" gt "$(sed -n '/^log: /,$p' "$work/c6.err" | tail -n +2 | grep -c .)" 0
check "no VM left running" wait_for 60 vm_gone
case_end

# ---- case 6b: kernel panic in the log while vphoned is not answering -------
case_begin "6b kernel panic"
launch_bg c6b
first=$lastbg
if wait_for 120 up_with_log && ! ping_ok; then
    print -r -- "kernel panic: injected by run-detach-launch-live.sh" >>"$log"
else
    curfail+=("VM process did not come up unanswering")
    print "    FAIL: ${curfail[-1]}"
fi
wait $first 2>/dev/null || true
check "exit 1" eq "$(rc_of c6b)" 1
check "stderr: had a kernel panic" has "$work/c6b.err" "\`$name\` had a kernel panic; it is still running (pid "
check "stderr: names the log" has "$work/c6b.err" "log: $log"
check "stderr: stop hint" has "$work/c6b.err" "vphone-cli vm stop $name"
check "stdout has no vphoned answered" eq "$(grep -c 'vphoned answered' "$work/c6b.out")" 0
check "VM is alive" test -n "$(vm_pids)"
check "stop" stop_vm
case_end

# ---- case 7: could not start, invalid names --------------------------------
# The log directory is fixed at ~/Library/Logs/vphone-launchpad, so it is made
# read-only for a moment (the VM's log moved aside) and restored afterwards.
case_begin "7 could not start"
logmode="$(stat -f %Lp "$logs")"
restore_logs() {
    set +e
    chmod 755 "$logs" 2>/dev/null
    [[ -f "$work/log.bak" ]] && mv -f "$work/log.bak" "$log"
    chmod 644 "$log" 2>/dev/null
    chmod "$logmode" "$logs" 2>/dev/null
    return 0
}
trap 'restore_logs; cleanup' EXIT
[[ -f "$log" ]] && mv "$log" "$work/log.bak"
chmod 555 "$logs"
rc=0; "$cli" vm launch "$name" --detach >"$work/c7a.out" 2>"$work/c7a.err" || rc=$?
print -r -- $rc >"$work/c7a.rc"
restore_logs
check "unwritable log dir: exit 1" eq "$(rc_of c7a)" 1
check "unwritable log dir: could not start" has "$work/c7a.err" "could not start \`$name\`"
check "unwritable log dir: no pid line" eq "$(grep -c '^pid ' "$work/c7a.out")" 0
check "unwritable log dir: no log line" eq "$(grep -c '^log ' "$work/c7a.out")" 0
check "unwritable log dir: no VM" test -z "$(vm_pids)"
[[ -f "$log" ]] || : >"$log"
chmod 444 "$log"
rc=0; "$cli" vm launch "$name" --detach >"$work/c7b.out" 2>"$work/c7b.err" || rc=$?
print -r -- $rc >"$work/c7b.rc"
chmod 644 "$log"
check "read-only log: exit 1" eq "$(rc_of c7b)" 1
check "read-only log: could not start" has "$work/c7b.err" "could not start \`$name\`"
check "read-only log: no pid line" eq "$(grep -c '^pid ' "$work/c7b.out")" 0
check "read-only log: no VM" test -z "$(vm_pids)"

logsnap() { find "$logs" -type f ! -name 'vphone-cli.log' -exec stat -f '%N %z %m' {} + 2>/dev/null | sort; }
for bad in "../x" "a/b" "" ".hidden"; do
    snap="$(logsnap)"
    irc=0; "$cli" vm info "$bad" >"$work/info.out" 2>"$work/info.err" || irc=$?
    lrc=0; "$cli" vm launch "$bad" --detach >"$work/inv.out" 2>"$work/inv.err" || lrc=$?
    check "invalid name '$bad': exit code matches vm info ($irc)" eq "$lrc" "$irc"
    check "invalid name '$bad': exit 1" eq "$lrc" 1
    check "invalid name '$bad': stderr matches vm info" cmp -s "$work/info.err" "$work/inv.err"
    check "invalid name '$bad': stderr not empty" test -s "$work/inv.err"
    check "invalid name '$bad': nothing under ~/Library/Logs changed" eq "$(logsnap)" "$snap"
done
check "no VM started" test -z "$(vm_pids)"
case_end

# ---- case 8: --timeout validation ------------------------------------------
case_begin "8 timeout validation"
for t in 0 -1 x; do
    trc=0; "$cli" vm launch "$name" --detach --timeout "$t" >"$work/t.out" 2>"$work/t.err" || trc=$?
    check "--timeout $t: exit 64" eq "$trc" 64
    if [[ "$t" != x ]]; then
        check "--timeout $t: message" has "$work/t.err" "\`--timeout\` must be a whole number of seconds, 1 or more"
    fi
done
trc=0; "$cli" vm launch "$name" --timeout 5 >"$work/t.out" 2>"$work/t.err" || trc=$?
check "--timeout without --detach: exit 64" eq "$trc" 64
check "--timeout without --detach: message" has "$work/t.err" "\`--timeout\` needs \`--detach\`"
trc=0; "$cli" vm launch "$name" --detach --dfu >"$work/t.out" 2>"$work/t.err" || trc=$?
check "--detach --dfu: exit 64" eq "$trc" 64
check "--detach --dfu: message" has "$work/t.err" "\`--detach\` is unavailable with \`--dfu\`"
check "no VM started" test -z "$(vm_pids)"
case_end

# ---- case 9: repeat launch (stop, launch, stop, launch) --------------------
case_begin "9 repeat launch"
launch r1
check "launch 1 exit 0" eq "$(rc_of r1)" 0
marker="launch-1-marker-$$"
print -r -- "$marker" >>"$log"
check "stop 1" stop_vm
launch r2
check "launch 2 exit 0" eq "$(rc_of r2)" 0
check "ping answers" wait_for 10 ping_ok
check "log non-empty" gt "$(size_of "$log")" 0
check "log truncated: launch 1's marker line is gone" eq "$(grep -cF -- "$marker" "$log")" 0
check "stop 2" stop_vm
case_end

# ---- case 10: a short-lived reader of the disk is waited out ---------------
case_begin "10 reader wait"
( exec 3<"$vmdir/Disk.img"; sleep 1 ) &
holder=$!
sleep 0.2
launch r10a
check "reader released within 2 s: launch exit 0" eq "$(rc_of r10a)" 0
check "stop after the reader case" stop_vm
wait $holder
( exec 3<"$vmdir/Disk.img"; sleep 8 ) &
holder=$!
sleep 0.2
t0=$SECONDS
launch r10b
elapsed=$(( SECONDS - t0 ))
check "reader kept past 2 s: exit 1" eq "$(rc_of r10b)" 1
check "reader kept past 2 s: refused within 4 s" test "$elapsed" -le 4
check "reader kept past 2 s: message names the VM" has "$work/r10b.err" "'$name' is in use"
check "reader kept past 2 s: no VM started" test -z "$(vm_pids)"
kill $holder 2>/dev/null
wait $holder 2>/dev/null || true
case_end

# ---- summary ---------------------------------------------------------------
print
print "=== summary ($(git -C "$root" rev-parse HEAD)) ==="
for c in $order; do print "$result[$c] $c"; done
if (( failed )); then print "FAIL"; exit 1; fi
print "PASS"
