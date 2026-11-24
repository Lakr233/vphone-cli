#!/bin/zsh
# vphone-tier: live
# Baseline-vs-branch comparison of Launchpad's start path.
# Usage: run-launchpad-baseline.sh <vm-name> <main-worktree-dir>
# <main-worktree-dir> is a checkout of origin/main. <vm-name> is an existing,
# stopped VM in the default library. The branch under test is the worktree this
# script lives in. For each build it builds the Launchpad and VPhone schemes,
# allows the VM binary through AMFI (sudo -n, per CDHash), then runs
# `vm start --wait`, `vm log`, `vm stop`, checks the responsible process of the
# spawned vphone-cli and runs the Launchpad Tests scripts that touch start.
# The responsible-pid check fails closed: a lookup that cannot answer is FAIL
# for both builds and no values are compared.
# Test hooks: BASELINE_RPID_SYMBOL (symbol name for the lookup) and
# BASELINE_RPID_PID (pid handed to the lookup instead of the real one).
set -euo pipefail

if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
    print -u2 "usage: ${0:t} <vm-name> <main-worktree-dir>"
    exit 2
fi
name="$1"

# ---- guard 1: validate the VM name before it reaches any path/pgrep pattern -
if [[ ! "$name" =~ '^[A-Za-z0-9][A-Za-z0-9_-]*$' ]]; then
    print -u2 "error: invalid VM name '$name' (allowed: letters, digits, '_' and '-'; must not start with '_' or '-')"
    exit 2
fi

main_dir="${2:A}"
head_dir="$(cd "${0:a:h}/../../.." && pwd)"
[[ -d "$main_dir/VPhoneLaunchpad" ]] || { print -u2 "not a checkout: $main_dir"; exit 2; }
library="${VPHONE_LIBRARY_ROOT:-$HOME/.vphone/machines}"
vmdir="$library/$name"
[[ -d "$vmdir" ]] || { print -u2 "no VM '$name' in $library"; exit 2; }
config="$vmdir/config.plist"

main_sha="$(git -C "$main_dir" rev-parse HEAD)"
head_sha="$(git -C "$head_dir" rev-parse HEAD)"
origin_sha="$(git -C "$head_dir" rev-parse origin/main 2>/dev/null)" || {
    print -u2 "cannot resolve origin/main in $head_dir"; exit 2;
}
products=".build/XcodeBundle/Build/Products/Debug"

vm_up() { pgrep -f "vphone-vm --config $config" >/dev/null 2>&1; }
vm_gone() { vm_up && print 0 || print 1; }

# ---- guard 2: destructive opt-in -------------------------------------------
if [[ "${VPHONE_LIVE_DESTRUCTIVE:-}" != "$name" ]]; then
    print -u2 "############################################################"
    print -u2 "# REFUSING to run: this is a DESTRUCTIVE live test on VM '$name'."
    print -u2 "# Against VM '$name' it will:"
    print -u2 "#   - start and stop the VM, and kill its processes (vphone-vm/vphone-cli)"
    print -u2 "#   - launch and quit the Launchpad apps it builds, and AMFI-allow the VM binary"
    print -u2 "#   - rebuild into each worktree's .build/XcodeBundle"
    if [[ -z "${VPHONE_LIVE_DESTRUCTIVE:-}" ]]; then
        print -u2 "# VPHONE_LIVE_DESTRUCTIVE is not set."
    else
        print -u2 "# VPHONE_LIVE_DESTRUCTIVE='${VPHONE_LIVE_DESTRUCTIVE}' does not match '$name'."
    fi
    print -u2 "# To proceed, re-run with:  VPHONE_LIVE_DESTRUCTIVE=$name ${0:t} $name $main_dir"
    print -u2 "############################################################"
    exit 2
fi

# ---- guard 3: refuse if the VM is already running (opt-in is for a stopped VM) -
if vm_up; then
    print -u2 "VM '$name' is already running; stop it first"
    exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/lp-baseline.XXXXXX")"

# ---- responsible-pid tool -----------------------------------------------------
cat > "$work/rpid.c" <<'C'
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
/* rpid <pid> [symbol]: prints the responsible pid of <pid>. Exits non-zero for
   a bad or nonexistent pid, an unresolved symbol, or an answer <= 0. */
int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) return 64;
    char *end;
    long pid = strtol(argv[1], &end, 10);
    if (*end || pid <= 0) { fprintf(stderr, "bad pid\n"); return 1; }
    const char *symbol = argc == 3 ? argv[2] : "responsibility_get_pid_responsible_for_pid";
    pid_t (*lookup)(pid_t) = dlsym(RTLD_DEFAULT, symbol);
    if (!lookup) { fprintf(stderr, "symbol not found: %s\n", symbol); return 1; }
    if (kill((pid_t)pid, 0) != 0 && errno != EPERM) { fprintf(stderr, "no such pid\n"); return 1; }
    pid_t responsible = lookup((pid_t)pid);
    if (responsible <= 0) { fprintf(stderr, "no responsible pid (%d)\n", responsible); return 1; }
    printf("%d\n", responsible);
    return 0;
}
C
rpid_tool="$work/rpid"
rpid_ok=1
/usr/bin/clang -o "$rpid_tool" "$work/rpid.c" 2>"$work/rpid-build.txt" || rpid_ok=0

# responsible <pid>: prints the responsible pid, or returns 1 (fail closed).
responsible() {
    (( rpid_ok )) || return 1
    local pid="${BASELINE_RPID_PID:-$1}"
    "$rpid_tool" "$pid" ${BASELINE_RPID_SYMBOL:+"$BASELINE_RPID_SYMBOL"} 2>>"$work/rpid-err.txt"
}

# ---- results ------------------------------------------------------------------
typeset -A res
launched_app_pids=()   # Launchpad app pids this run started (signal only these)
vm_started=0           # set once this run starts the VM; gates VM teardown
cleanup() {
    set +e
    # Stop only a VM that this run started and that is still up (a `vm stop`
    # would start the app again), then quit only the apps this run launched.
    if (( vm_started )) && vm_up; then
        for d in "$main_dir" "$head_dir"; do
            "$d/$products/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli" vm stop "$name" >/dev/null 2>&1 || true
        done
    fi
    for p in $launched_app_pids; do kill "$p" 2>/dev/null || true; done
    if (( vm_started )); then
        pkill -f "vphone-cli vm launch $name( |\$)" 2>/dev/null || true
        pkill -f "vphone-vm --config $config" 2>/dev/null || true
    fi
    /bin/rm -rf "$work" || true
}
# ---- guard 4: install cleanup only now that the guard has passed ------------
trap cleanup EXIT

# ---- guard 5: app scoping — refuse if a Launchpad app from a build path is
# already running (never signal an operator's already-running app). --------------
for d in "$main_dir" "$head_dir"; do
    gapp="$d/$products/vphone-launchpad.app/Contents/MacOS/vphone-launchpad"
    grun="$(pgrep -f -- "$gapp\$" 2>/dev/null)" || true
    if [[ -n "$grun" ]]; then
        print -u2 "refusing: a Launchpad app from the build path is already running (pid ${grun%%$'\n'*}): $gapp"
        print -u2 "quit it first; this run signals only the apps it launches itself."
        exit 2
    fi
done

# check <build> <label> <ok-flag> [detail]
check() {
    local build=$1 label=$2 ok=$3 detail=${4:-}
    res[$build.checks]+="${ok}|${label}|${detail}"$'\n'
    (( ok )) || res[$build.fail]=1
}

# ---- one build ----------------------------------------------------------------
run_build() {
    local build=$1 d=$2
    local cli="$d/$products/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli"
    local bundle="$d/$products/VPhone.bundle/Contents/MacOS"

    if vm_up; then check $build "VM stopped before run" 0 "a vphone-vm for $name is already running"; return; fi
    # The CLI drives whichever Launchpad owns the one control socket, so an app
    # from another build would be measured instead of this one.
    local app_exe="$d/$products/vphone-launchpad.app/Contents/MacOS/vphone-launchpad" other
    other="$(pgrep -fl 'vphone-launchpad.app/Contents/MacOS/vphone-launchpad$' | grep -v -F -- "$app_exe" || true)"
    if [[ -n "$other" ]]; then
        check $build "no other Launchpad app running" 0 "quit it first: ${other%%$'\n'*}"
        return
    fi

    local brc=0
    /usr/bin/xcodebuild -workspace "$d/VPhone.xcworkspace" -scheme VPhone -configuration Debug \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$d/.build/XcodeBundle" \
        -disableAutomaticPackageResolution -skipPackageUpdates build >"$work/$build-build-vphone.txt" 2>&1 || brc=$?
    check $build "build VPhone scheme" $(( brc == 0 )) "$work/$build-build-vphone.txt"
    brc=0
    /usr/bin/xcodebuild -project "$d/VPhoneLaunchpad/VPhoneLaunchpad.xcodeproj" -scheme VPhoneLaunchpad \
        -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$d/.build/XcodeBundle" \
        -disableAutomaticPackageResolution -skipPackageUpdates build >"$work/$build-build-lp.txt" 2>&1 || brc=$?
    check $build "build VPhoneLaunchpad scheme" $(( brc == 0 )) "$work/$build-build-lp.txt"
    [[ -x "$cli" && -x "$bundle/vphone-vm" ]] || { check $build "build products present" 0 "$cli"; return; }

    local arc=0
    sudo -n "$bundle/vphone-escalator" allow "$bundle/vphone-vm" >"$work/$build-allow.txt" 2>&1 || arc=$?
    check $build "AMFI allow" $(( arc == 0 )) "$work/$build-allow.txt"

    # vm start --wait, in the background so the cli's own responsible pid can be sampled.
    vm_started=1
    "$cli" vm start "$name" --wait >"$work/$build-start.out" 2>"$work/$build-start.err" &
    local cpid=$! child="" i=0 cli_resp=""
    while (( i < 120 )) && [[ -z "$child" ]]; do
        # The launcher's own command line also contains the pattern; take the
        # process whose executable is vphone-cli.
        child=""
        for p in $(pgrep -f "vphone-cli vm launch $name"); do
            [[ "$(ps -p $p -o comm= 2>/dev/null)" == */vphone-cli ]] && { child=$p; break; }
        done
        [[ -n "$child" ]] || { sleep 1; (( i += 1 )) }
    done
    if [[ -n "$child" && -n "$(ps -p $cpid -o pid= 2>/dev/null)" ]]; then
        cli_resp="$(responsible $cpid)" || cli_resp=""
    fi
    local child_resp="" lookup_ok=0
    child_resp="$(responsible "${child:-0}")" || lookup_ok=$?
    res[$build.start]=0
    wait $cpid || res[$build.start]=$?
    check $build "vm start --wait exits 0" $(( res[$build.start] == 0 )) "exit ${res[$build.start]}"

    # Record the Launchpad app this run started so only it (never an operator's
    # app) is ever signalled, here and in cleanup.
    local -a my_app_pids
    my_app_pids=(${(f)"$(pgrep -f -- "$app_exe\$" 2>/dev/null || true)"})
    launched_app_pids+=($my_app_pids)

    if [[ -z "$child" ]]; then
        check $build "spawned vphone-cli found" 0 "pgrep \"vphone-cli vm launch $name\" found nothing"
    elif (( lookup_ok != 0 )); then
        check $build "responsible-pid lookup" 0 "lookup failed: $(tail -1 "$work/rpid-err.txt" 2>/dev/null)"
        res[$build.lookup]=failed
    else
        local shell_resp=""
        shell_resp="$(responsible $$)" || shell_resp=""
        # Launchpad is the app (which spawns the launcher) and the cli driving it.
        local forbidden=" $$ $cpid ${cli_resp} ${shell_resp} $(pgrep -f -- "$app_exe\$" 2>/dev/null | tr '\n' ' ' || true)"
        local kind=other
        (( child_resp == child )) && kind=self
        res[$build.kind]=$kind
        if [[ "$forbidden" == *" $child_resp "* ]]; then
            check $build "responsible process is not Launchpad" 0 "child $child responsible $child_resp (Launchpad cli $cpid, its responsible ${cli_resp:-?}, shell responsible $shell_resp)"
        else
            check $build "responsible process is not Launchpad" 1 "child $child responsible $child_resp ($kind)"
        fi
    fi

    res[$build.log]=0
    "$cli" vm log "$name" >"$work/$build-log.out" 2>"$work/$build-log.err" || res[$build.log]=$?
    res[$build.logpath]="$(plutil -extract path raw -o - "$work/$build-log.out" 2>/dev/null)" || res[$build.logpath]=""
    check $build "vm log exits 0" $(( res[$build.log] == 0 )) "exit ${res[$build.log]} ${res[$build.logpath]}"
    local nonempty=0
    [[ -s "${res[$build.logpath]}" ]] && nonempty=1
    check $build "console log non-empty" $nonempty "${res[$build.logpath]}"

    res[$build.stop]=0
    "$cli" vm stop "$name" >"$work/$build-stop.out" 2>"$work/$build-stop.err" || res[$build.stop]=$?
    check $build "vm stop exits 0" $(( res[$build.stop] == 0 )) "exit ${res[$build.stop]}"
    i=0; while vm_up && (( i < 60 )); do sleep 1; (( i += 1 )); done
    check $build "no VM left after stop" $(vm_gone)

    # vm launch --detach (branch only): responsible process is the invoking shell's.
    if "$bundle/vphone-cli" vm launch --help 2>&1 | grep -q -- --detach; then
        local dx=0
        "$bundle/vphone-cli" vm launch "$name" --detach >"$work/$build-detach.out" 2>"$work/$build-detach.err" || dx=$?
        local dpid
        dpid="$(sed -n 's/^pid[: ]*\([0-9][0-9]*\).*/\1/p' "$work/$build-detach.out" | head -1)"
        local dresp="" dok=0 shell_resp2=""
        dresp="$(responsible "${dpid:-0}")" || dok=$?
        shell_resp2="$(responsible $$)" || shell_resp2=""
        if (( dx == 0 && dok == 0 )) && [[ "$dresp" == "$shell_resp2" ]]; then
            check $build "--detach responsible process is the invoking shell's" 1 "pid $dpid responsible $dresp"
        else
            check $build "--detach responsible process is the invoking shell's" 0 "exit $dx pid ${dpid:-?} responsible ${dresp:-?} shell's ${shell_resp2:-?}"
        fi
        "$bundle/vphone-cli" vm stop "$name" >/dev/null 2>&1 || true
        i=0; while vm_up && (( i < 60 )); do sleep 1; (( i += 1 )); done
        check $build "no VM left after --detach stop" $(vm_gone)
    fi

    # Quit only the Launchpad this run started so the next build's app owns the socket.
    for p in $my_app_pids; do kill "$p" 2>/dev/null || true; done
    sleep 2

    local t trc
    for t in ControlTests ConsoleOutputTests MachineSnapshotsTests TemplatesTests; do
        trc=0
        /bin/zsh "$d/VPhoneLaunchpad/Tests/$t.sh" >"$work/$build-$t.txt" 2>&1 || trc=$?
        check $build "Tests/$t.sh" $(( trc == 0 )) "$work/$build-$t.txt"
    done
}

run_build main "$main_dir"
run_build head "$head_dir"

# ---- compare and report -------------------------------------------------------
if [[ -n "${res[main.lookup]:-}${res[head.lookup]:-}" ]] || (( ! rpid_ok )); then
    res[main.fail]=1; res[head.fail]=1
    print "responsible-pid tool failed: no values compared (see $work/rpid-err.txt)"
else
    if [[ "${res[main.start]:-x}" == "${res[head.start]:-y}" && "${res[main.log]:-x}" == "${res[head.log]:-y}" && "${res[main.stop]:-x}" == "${res[head.stop]:-y}" ]]; then
        print "exit codes match: start ${res[main.start]} log ${res[main.log]} stop ${res[main.stop]}"
    else
        print "exit codes DIFFER: main start/log/stop ${res[main.start]:-?}/${res[main.log]:-?}/${res[main.stop]:-?} head ${res[head.start]:-?}/${res[head.log]:-?}/${res[head.stop]:-?}"
        res[main.fail]=1; res[head.fail]=1
    fi
    if [[ -n "${res[main.logpath]:-}" && "${res[main.logpath]:-x}" == "${res[head.logpath]:-y}" ]]; then
        print "log path matches: ${res[head.logpath]}"
    else
        print "log path DIFFERS: main '${res[main.logpath]:-}' head '${res[head.logpath]:-}'"
        res[main.fail]=1; res[head.fail]=1
    fi
    if [[ -n "${res[main.kind]:-}" && "${res[main.kind]:-x}" == "${res[head.kind]:-y}" ]]; then
        print "responsible process kind matches: ${res[head.kind]}"
    else
        print "responsible process kind DIFFERS: main '${res[main.kind]:-}' head '${res[head.kind]:-}'"
        res[main.fail]=1; res[head.fail]=1
    fi
fi

print "origin/main: $origin_sha"
rc=0
for pair in "main:$main_sha" "head:$head_sha"; do
    build=${pair%%:*}; sha=${pair#*:}
    print
    print "== $build $sha"
    print -r -- "${res[$build.checks]:-}" | while IFS='|' read -r ok label detail; do
        [[ -n "$label" ]] || continue
        print "  $( (( ok )) && print PASS || print FAIL ) $label ${detail:+- $detail}"
    done
    if [[ -n "${res[$build.fail]:-}" ]]; then
        print "FAIL $build $sha"; rc=1
    else
        print "PASS $build $sha"
    fi
done
exit $rc
