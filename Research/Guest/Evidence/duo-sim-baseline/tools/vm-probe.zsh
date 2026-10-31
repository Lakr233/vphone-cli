#!/bin/zsh
# vm-probe.zsh <vm> <process|pid> <cmdfile|-> [out.txt]
#
# The vphone counterpart of probe.zsh: run the same lldb command files against a process
# in a vphone guest. A one-shot launchd job starts the guest's /usr/libexec/debugserver
# (CFW gives it task_for_pid-allow) attached to the target; host lldb connects to it over
# the VM's network, sources prelude.lldb and <cmdfile>, detaches and quits. The job is
# unloaded afterwards. Symbols come from ~/Library/Developer/Xcode/iOS DeviceSupport.
#
# Environment:
#   PROBE_TIMEOUT=180       seconds before the watchdog interrupts lldb
#   PROBE_NO_PRELUDE=1      skip prelude.lldb
#   VM_PROBE_HOST=<ip>      guest address, instead of asking device.network
#   VM_PROBE_PORT=<port>    debugserver port (default: random 24000-24999)
#
# Exit status: lldb's status, 124 if the watchdog fired, 3 if debugserver never listened.
set -euo pipefail
here=${0:a:h}

(( $# >= 3 )) || { sed -n '2,16p' ${0:a} | sed 's/^# \{0,1\}//'; exit 2 }
vm=$1 proc=$2 cmd=$3 out=${4:-}

rpc() { vphone-launchpad-cli guest rpc $vm $1 ${2:-'{}'} }

if [[ $proc == <-> ]]; then
  pid=$proc
else
  pid=$(rpc processes.list "{\"filter\":\"$proc\"}" | jq -r --arg n $proc '
    [(.result.processes // .result // .processes // [])[]
     | select((.name // .command // "") as $c | $c == $n or ($c | endswith("/" + $n)))
     | .pid] | first // empty')
  [[ -n $pid ]] || { print -u2 "vm-probe.zsh: no process named $proc in $vm"; exit 2 }
fi

host=${VM_PROBE_HOST:-}
if [[ -z $host ]]; then
  host=$(rpc device.network | jq -r '
    [.result.addresses[]? | capture("^en0 (?<ip>[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)$")? | .ip] | first // empty')
  [[ -n $host ]] || { print -u2 "vm-probe.zsh: could not find the guest address; set VM_PROBE_HOST"; exit 2 }
fi
port=${VM_PROBE_PORT:-$(( 24000 + RANDOM % 1000 ))}
label=com.vphone.baseline.debugserver.$port
plist=/var/tmp/$label.plist

work=$(mktemp -d -t vmprobe)
cleanup() {
  rpc services.unload "{\"paths\":[\"$plist\"],\"force\":true}" >/dev/null 2>&1 || true
  rpc files.remove "{\"path\":\"$plist\"}" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

if [[ $cmd == - ]]; then cat > $work/cmd.lldb; cmd=$work/cmd.lldb; fi
[[ -r $cmd ]] || { print -u2 "vm-probe.zsh: cannot read $cmd"; exit 2 }
cmd=${cmd:a}
raw=$work/raw.txt

# One line of JSON: files.write takes a single line.
content="<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>Label</key><string>$label</string><key>ProgramArguments</key><array><string>/usr/libexec/debugserver</string><string>0.0.0.0:$port</string><string>--attach=$pid</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><false/></dict></plist>"
rpc files.write "$(jq -cn --arg p $plist --arg c $content '{path: $p, content: $c}')" >/dev/null
rpc services.load "{\"paths\":[\"$plist\"]}" >/dev/null

# debugserver accepts exactly one connection, so a port check would use it up: wait for the
# process instead, then give it a moment to attach and listen.
for i in {1..40}; do
  rpc processes.list '{"filter":"debugserver"}' | jq -e '.result.count > 0' >/dev/null 2>&1 && break
  (( i == 40 )) && { print -u2 "vm-probe.zsh: debugserver did not start"; exit 3 }
  sleep 0.5
done
sleep 1.5

args=(--batch --no-lldbinit -O "settings set symbols.load-on-demand true" -O "settings set auto-confirm true"
      -o "platform select remote-ios" -o "process connect connect://$host:$port")
[[ ${PROBE_NO_PRELUDE:-0} == 1 ]] || args+=(-o "command source -e false -s 0 $here/prelude.lldb")
args+=(-o "command source -e false -s 0 $cmd" -o "process detach" -o "quit")

lldb "${args[@]}" > $raw 2>&1 &
lpid=$!
timeout=${PROBE_TIMEOUT:-180}
(
  sleep $timeout; print -- "vm-probe.zsh: timeout after ${timeout}s, interrupting lldb" > $work/timedout
  kill -INT $lpid 2>/dev/null; sleep 10
  kill -INT $lpid 2>/dev/null; sleep 10
  kill -TERM $lpid 2>/dev/null
) &
wpid=$!
rc=0
wait $lpid || rc=$?
pkill -P $wpid 2>/dev/null || true
kill $wpid 2>/dev/null || true
wait $wpid 2>/dev/null || true
if [[ -e $work/timedout ]]; then rc=124; cat $work/timedout >> $raw; print -u2 -- "$(cat $work/timedout)"; fi

clean() {
  awk -v marker="command source -e false -s 0 $cmd" '
    !on { if (index($0, marker)) on = 1; next }
    /^Executing commands in / { next }
    /^Enter expressions, then terminate with an empty line to evaluate:/ { next }
    /^note: Expression evaluation in pure Objective-C not supported/ { next }
    /^warning: warning: got name from symbols:/ { next }
    /^\(lldb\) process detach$/ || /^Process [0-9]+ detached$/ || /^\(lldb\) quit$/ { next }
    { print }
  ' $raw
}

if [[ -n $out ]]; then
  mkdir -p ${out:h}
  cp $raw ${out:r}.raw.txt
  clean > $out
  print -u2 "vm-probe.zsh: $vm pid $pid rc $rc -> $out"
else
  clean
fi
exit $rc
