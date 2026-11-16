#!/bin/zsh
# MANUAL live check of vphone-mcp against a real guest. It is not part of the guest-independent suite
# (MCPTests.sh): it needs a built bundle, a built vphone-mcp, a booted VM and, for the bash checks, guest internet.
#   zsh VPhoneMCP/Tests/run-mcp-live.zsh
# Prerequisites (this script builds nothing and never runs sudo): VPhone.bundle is built and AMFI-allowlisted
# (`host preflight` passes), and vphone-mcp is built (AGENTS.md, MCP Server).
# Environment:
#   VPHONE_BUNDLE   VPhone.bundle to use; default <repo>/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle
#   VPHONE_MCP      vphone-mcp binary; default <repo>/build/mcp/Build/Products/Debug/vphone-mcp
#   VPHONE_VM       a VM that is already running; it is used as is and never stopped or deleted. Without it the
#                   script clones two throw-away VMs from the newest current template (`vm create --template`), boots
#                   them headless, and stops and deletes them at the end. With it, the two-VM checks are skipped.
#   VPHONE_TEMPLATE a template id to clone (default: the newest non-stale iOS 27.0.1 template from `vm template list`)
#   VPHONE_LIBRARY_ROOT  VM library (default ~/.vphone/machines)
#   VPHONE_KEEP_VM=1     keep the throw-away VM (its name is printed)
# The guest is changed: it is rebooted once, a roothide bootstrap with bash is installed, and Safari is opened.
# Use a throw-away VM; a VM that already has a bootstrap makes the bootstrap checks fail by design.
# Checks: the generated tools, profiles, unknown-argument rejection, a real tap and swipe effect (frontmost app, OCR), real guest programs
# by absolute path (output, nonzero exit, timeout, output cap), bash after a bootstrap install, push/pull round trip,
# coded errors, an rpc `timeout_ms` expiry after which the same server session keeps working, and two VMs driven at
# once by the per-call `vm` argument.
# Output: `PASS <check>` or `FAIL <check>: <detail>` per check, then `mcp live: <n> checks, <f> failures`.
# Exit: 0 all checks pass, 1 a check failed, 2 unavailable (prints `UNAVAILABLE: <reason>`).
set -u

root=${0:a:h:h:h}
bundle=${VPHONE_BUNDLE:-$root/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle}
mcp=${VPHONE_MCP:-$root/build/mcp/Build/Products/Debug/vphone-mcp}
lib=${VPHONE_LIBRARY_ROOT:-$HOME/.vphone/machines}
export VPHONE_LIBRARY_ROOT=$lib
cli=$bundle/Contents/MacOS/vphone-cli
unavailable() { print -u2 "UNAVAILABLE: $1"; exit 2 }
[ -x "$cli" ] || unavailable "no built bundle at $bundle"
[ -x "$mcp" ] || unavailable "no built vphone-mcp at $mcp"
command -v jq > /dev/null || unavailable "jq is required"
"$cli" host preflight > /dev/null 2>&1 || unavailable "host preflight failed; run vphone-escalator allow for this bundle"

tmp=$(mktemp -d)
vm=${VPHONE_VM-}
vm2=
own=0
launch_pids=()
cleanup() {
  if [ $own = 1 ]; then
    local name
    for name in $vm $vm2; do
      if [ -z "${VPHONE_KEEP_VM-}" ]; then
        "$cli" vm stop "$name" > /dev/null 2>&1
        "$cli" vm delete "$name" --force > /dev/null 2>&1 || { sleep 4; "$cli" vm delete "$name" --force > /dev/null 2>&1; } \
          || print -u2 "could not delete $name; remove it with: $cli vm delete $name --force"
      else
        print -r -- "kept vm $name"
      fi
    done
    [ -n "${launch_pids[*]}" ] && kill "${launch_pids[@]}" > /dev/null 2>&1
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -z "$vm" ]; then
  tpl=${VPHONE_TEMPLATE-}
  [ -n "$tpl" ] || tpl=$("$cli" vm template list --json 2> /dev/null | jq -r --arg v "${VPHONE_IPHONE_VERSION:-27.0.1}" '[.templates[] | select(.stale == false and .key.IOSVersion == $v and (.key.Device | startswith("iPhone")))] | sort_by(.frozenAt) | last | .id // empty')
  [ -n "$tpl" ] || unavailable "no current template for iOS ${VPHONE_IPHONE_VERSION:-27.0.1}; set VPHONE_TEMPLATE"
  vm=mcplive-$$
  vm2=mcplive2-$$
  own=1
  for name in $vm $vm2; do
    "$cli" vm create "$name" --template "$tpl" --skip-first-boot > "$tmp/create-$name.log" 2>&1 || unavailable "vm create failed: $(tail -n 3 "$tmp/create-$name.log")"
  done
  "$cli" vm launch "$vm" --headless < /dev/null > "$tmp/launch-$vm.log" 2>&1 &
  launch_pids+=($!)
fi
sock=$lib/$vm/vphone.sock

pass=0
fail=0
check() { # name, ok (0/1), detail
  if [ "$2" = 1 ]; then pass=$((pass + 1)); print -r -- "PASS $1"
  else fail=$((fail + 1)); print -r -- "FAIL $1: ${3-}"; fi
}

# callvm <vm> <tool> <arguments json>: the vm argument names the machine.
callvm() {
  local args
  args=$(jq -c --arg v "$1" '. + {vm: $v}' <<< "$3")
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$args}}" | "$mcp"
}
# call <tool> <arguments json>: callvm on the main VM.
call() { callvm "$vm" "$1" "$2" }
# shellcall <arguments json>: the shell tool.
shellcall() { call shell "$1" }
# tap x y, swipe x1 y1 x2 y2, button name: the generated input tool, in points.
tap() { call input "{\"action\":\"input.tap\",\"x\":$1,\"y\":$2}" }
swipe() { call input "{\"action\":\"input.swipe\",\"from\":[$1,$2],\"to\":[$3,$4],\"seconds\":0.25}" }
button() { call input "{\"action\":\"input.button\",\"name\":\"$1\"}" }
# wake: the guest screen sleeps after 60 s without input, and a sleeping screen swallows taps and swipes.
# A woken screen can stay black for a few seconds, so wake0 waits until OCR reads text on it. wake also dismisses the
# "Trust This Computer?" dialog (see below), which a new guest shows after a delay that varies.
wake0() {
  local i
  rpc screen.unlock > /dev/null
  for i in {1..10}; do
    sleep 1
    screentext=$(inner '[.blocks[].text] | join(" ")' "$(rpc ui.ocr)")
    [ -n "$screentext" ] && return
  done
}
wake() { wake0; if has "$screentext" "Trust This Computer"; then tap 123 505 > /dev/null; sleep 2; fi }
# rpc <method> [params json] [timeout_ms]: the rpc tool.
rpc() {
  local args
  args=$(jq -cn --arg m "$1" --argjson p "${2:-null}" --argjson t "${3:-null}" '{method: $m} + (if $p == null then {} else {params: $p} end) + (if $t == null then {} else {timeout_ms: $t} end)')
  call rpc "$args"
}
text() { jq -r '.result.content[0].text // .error.message // empty'; }
iserr() { jq -r '.result.isError // false'; }
inner() { jq -r "$1" <<< "$(text <<< "$2")"; }
has() { print -r -- "$1" | grep -qF -- "$2"; }

# Waits until the guest answers; $1 = seconds.
wait_guest() {
  local i=0 r
  while [ $i -lt $(($1 / 5)) ]; do
    r=$(rpc device.screen 2> /dev/null)
    [ "$(jq -r '.result.isError // false' <<< "$r" 2> /dev/null)" = false ] && has "$r" width && return 0
    sleep 5; i=$((i + 1))
  done
  return 1
}
wait_guest 300 || unavailable "guest did not answer on $sock"
# The second VM boots after the first answers; two cold boots at once exceed the wait.
if [ -n "$vm2" ]; then
  "$cli" vm launch "$vm2" --headless < /dev/null > "$tmp/launch-$vm2.log" 2>&1 &
  launch_pids+=($!)
fi

# --- protocol ---------------------------------------------------------------
init=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"live","version":"1"}}}' | "$mcp")
check initialize-server-info "$([ "$(jq -r '.result.serverInfo.name' <<< "$init")" = vphone-mcp ] && echo 1 || echo 0)" "$init"
guestmethods=$(text <<< "$(call methods '{}')")
areas=$(jq -r '[.methods[] | select(.name != "screen.screenshot" and .name != "methods.list") | .area] | unique | join(",")' <<< "$guestmethods")
want=$(print -r -- "screenshot,push,pull,shell,methods,rpc,$areas" | tr ',' '\n' | sort | paste -sd, -)
tools=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | "$mcp" | jq -r '[.result.tools[].name] | sort | join(",")')
check tools-list "$([ "$tools" = "$want" ] && echo 1 || echo 0)" "$tools != $want"
emptylib=$(mktemp -d)
static_list=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | VPHONE_LIBRARY_ROOT=$emptylib "$mcp")
running_list=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | "$mcp")
rmdir "$emptylib"
check tools-list-static "$([ -n "$static_list" ] && [ "$static_list" = "$running_list" ] && echo 1 || echo 0)" "tools/list with a VM running differs from the list with no VM"
check catalog-has-area-and-access "$(jq -e '[.methods[] | select(.name == "input.tap")][0] | .area == "input" and .access == "mutating"' <<< "$guestmethods" > /dev/null && jq -e '[.methods[] | select(.name == "system.reboot")][0].access == "destructive"' <<< "$guestmethods" > /dev/null && echo 1 || echo 0)" "$(call methods '{"method":"input.tap"}' | head -c 300)"
inputschema=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | "$mcp" | jq -c '.result.tools[] | select(.name == "input")')
check input-schema-typed "$(jq -e '.inputSchema.oneOf | length > 5' <<< "$inputschema" > /dev/null && jq -e '[.inputSchema.oneOf[] | select(.properties.action.const == "input.tap")][0] | .required == ["action","x","y"] and .properties.x.type == "number"' <<< "$inputschema" > /dev/null && echo 1 || echo 0)" "$(head -c 300 <<< "$inputschema")"

# --- profiles ---------------------------------------------------------------
listnames() { printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | "$mcp" "$@" | jq -r '[.result.tools[].name] | join(",")'; }
standard=$(listnames --profile standard)
check profile-standard-list "$([ "$standard" = "${standard/shell/}" ] && ! has ",$standard," ",rpc," && ! has ",$standard," ",push," && has ",$standard," ",screenshot," && has ",$standard," ",input," && echo 1 || echo 0)" "$standard"
readonly_list=$(listnames --profile readonly)
check profile-readonly-list "$([ "$readonly_list" != "${readonly_list/screenshot/}" ] && ! has ",$readonly_list," ",input," && has ",$readonly_list," ",ui," && echo 1 || echo 0)" "$readonly_list"
r=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"shell","arguments":{"vm":"'"$vm"'","input":"a"}}}' | "$mcp" --profile readonly)
check profile-readonly-refuses-shell "$([ "$(jq -r '.error.code' <<< "$r")" = -32602 ] && has "$r" "not available in profile readonly" && echo 1 || echo 0)" "$r"
r=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"input","arguments":{"vm":"'"$vm"'","action":"input.tap","x":1,"y":1}}}' | "$mcp" --profile readonly)
check profile-readonly-refuses-input "$([ "$(jq -r '.error.code' <<< "$r")" = -32602 ] && has "$r" "not available in profile readonly" && echo 1 || echo 0)" "$r"
r=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"system","arguments":{"vm":"'"$vm"'","action":"system.reboot","force":true}}}' | "$mcp" --profile standard)
check profile-standard-refuses-destructive-action "$([ "$(jq -r '.error.code' <<< "$r")" = -32602 ] && has "$r" "invalid argument action" && echo 1 || echo 0)" "$r"

# --- unknown arguments and bad arguments ------------------------------------
for spec in 'screenshot|{"x":1}' 'input|{"action":"input.tap","x":1,"y":1,"z":1}' 'input|{"action":"input.swipe","from":[1,1],"to":[2,2],"q":1}' \
  'input|{"action":"input.key","name":"home","q":1}' 'input|{"action":"input.type","text":"a","q":1}' \
  'push|{"local":"/tmp/x","path":"/tmp/x","q":1}' 'pull|{"local":"/tmp/x","path":"/tmp/x","q":1}' \
  'methods|{"prefx":"a"}' 'rpc|{"method":"device.screen","param":{}}' 'shell|{"input":"a","q":1}'; do
  r=$(call "${spec%%|*}" "${spec#*|}")
  check "unknown-argument-${spec%%|*}-${${${spec#*|}%%[,\}]*}//[^a-z0-9]/}" "$([ "$(jq -r '.error.code' <<< "$r")" = -32602 ] && has "$r" unknown && echo 1 || echo 0)" "$r"
done
r=$(call input '{"action":"input.tap","x":"1","y":1}')
check bad-argument-type "$([ "$(jq -r '.error.code' <<< "$r")" = -32602 ] && has "$r" "must be a number" && echo 1 || echo 0)" "$r"
r=$(call input '{"action":"input.tap","x":1}')
check missing-argument "$([ "$(jq -r '.error.code' <<< "$r")" = -32602 ] && has "$r" "missing for input.tap" && echo 1 || echo 0)" "$r"
r=$(call input '{"action":"input.nope"}')
check unknown-action "$([ "$(jq -r '.error.code' <<< "$r")" = -32602 ] && has "$r" "must be one of" && echo 1 || echo 0)" "$r"
r=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nosuch","arguments":{"vm":"'"$vm"'"}}}' | "$mcp")
check unknown-tool "$([ "$(jq -r '.error.code' <<< "$r")" = -32602 ] && echo 1 || echo 0)" "$r"
r=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"input","arguments":{"vm":"'"$vm"'","action":"input.tap","x":1,"y":1}}}' | "$mcp" --tools screenshot)
check tools-restriction "$([ "$(jq -r '.error.code' <<< "$r")" = -32602 ] && echo 1 || echo 0)" "$r"

r=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"device","arguments":{"action":"device.screen"}}}' | "$mcp")
check vm-required "$([ "$(jq -r '.error.code' <<< "$r")" = -32602 ] && has "$r" "invalid argument vm: missing" && echo 1 || echo 0)" "$r"

# --- methods and rpc --------------------------------------------------------
r=$(call methods '{"prefix":"bootstrap."}')
check methods-prefix "$([ "$(inner '[.methods[].name]|length>0 and all(startswith("bootstrap."))' "$r")" = true ] && echo 1 || echo 0)" "$r"
r=$(call methods '{"method":"input.tap"}')
check methods-method "$([ "$(inner '.methods|length' "$r")" = 1 ] && echo 1 || echo 0)" "$r"
r=$(rpc device.screen)
check rpc-success "$([ "$(iserr <<< "$r")" = false ] && [ "$(inner .width "$r")" = 393 ] && echo 1 || echo 0)" "$r"
r=$(call system '{"action":"system.reboot","userspace":false}')
check group-coded-error "$([ "$(iserr <<< "$r")" = true ] && has "$(text <<< "$r")" force_required && echo 1 || echo 0)" "$r"
r=$(rpc system.reboot '{"userspace":false}')
check rpc-coded-error "$([ "$(iserr <<< "$r")" = true ] && has "$(text <<< "$r")" force_required && has "$(text <<< "$r")" "hint:" && echo 1 || echo 0)" "$r"
r=$(rpc no.such.method)
check rpc-unknown-method "$([ "$(iserr <<< "$r")" = true ] && echo 1 || echo 0)" "$r"

# --- wake, screenshot -------------------------------------------------------
rpc screen.unlock > /dev/null
rpc display.auto_lock.set '{"seconds":0}' > /dev/null
button home > /dev/null
sleep 2
shot=$(call screenshot '{}')
jq -r '.result.content[] | select(.type=="image") | .data' <<< "$shot" | base64 -D > "$tmp/shot.png" 2> /dev/null
check screenshot-png "$([ "$(head -c 8 "$tmp/shot.png" | xxd -p)" = 89504e470d0a1a0a ] && [ "$(jq -r '[.result.content[]|select(.type=="image")|.mimeType][0]' <<< "$shot")" = image/png ] && echo 1 || echo 0)" "$(wc -c < "$tmp/shot.png") bytes"

# --- tap and swipe effects --------------------------------------------------
ocr0() { wake0; print -r -- "$screentext"; }
ocr() { wake; inner '[.blocks[].text] | join(" ")' "$(rpc ui.ocr)"; }
frontmost() { inner .bundle_id "$(rpc apps.foreground)"; }
# A new guest asks "Trust This Computer?" a few seconds after the first unlock; the dialog blocks taps and swipes
# behind it. When it shows up, dismissing it is the first tap check.
for i in {1..10}; do
  has "$(ocr0)" "Trust This Computer" && break
  sleep 3
done
if has "$(ocr0)" "Trust This Computer"; then
  gone=0
  for i in {1..3}; do
    wake0
    tap 123 505 > /dev/null
    sleep 2
    has "$(ocr0)" "Trust This Computer" || { gone=1; break; }
  done
  check tap-dismisses-dialog "$gone" "dialog still shown after 3 taps"
fi
check home-before-tap "$([ "$(frontmost)" = com.apple.springboard ] && echo 1 || echo 0)" "$(frontmost)"
# The trust dialog can come back at any time, and a tap while it is rising is lost, so the tap is repeated up to 3 times.
for i in {1..3}; do
  wake
  r=$(tap 196 785)
  sleep 4
  [ "$(frontmost)" = com.apple.mobilesafari ] && break
done
check tap-opens-app "$([ "$(iserr <<< "$r")" = false ] && [ "$(frontmost)" = com.apple.mobilesafari ] && echo 1 || echo 0)" "frontmost $(frontmost)"
wake
button home > /dev/null
sleep 2
check key-home "$([ "$(frontmost)" = com.apple.springboard ] && echo 1 || echo 0)" "$(frontmost)"
check swipe-before "$(has "$(ocr)" "App Library" && echo 0 || echo 1)" "App Library already shown"
# Each swipe left moves the home screen one page; the last page is the App Library.
swiped=0
r=
for i in {1..4}; do
  wake
  r=$(swipe 350 400 40 400)
  [ "$(iserr <<< "$r")" = false ] || break
  sleep 2
  swiped=$i
  has "$(ocr)" "App Library" && break
done
check swipe-changes-page "$(has "$(ocr)" "App Library" && echo 1 || echo 0)" "App Library not shown after $swiped swipes: $r"
for i in {1..$swiped}; do
  wake
  swipe 40 400 350 400 > /dev/null
  sleep 2
done
check swipe-back "$(has "$(ocr)" "App Library" && echo 0 || echo 1)" "App Library still shown"

# --- type -------------------------------------------------------------------
wake
tap 196 785 > /dev/null
sleep 4
r=$(call input '{"action":"input.type","text":"x"}')
check type-reply "$([ "$(iserr <<< "$r")" = false ] && echo 1 || echo 0)" "$r"

# --- rpc timeout_ms expiry, then the same session keeps working -------------
rpc apps.launch '{"bundle_id":"com.apple.mobilesafari"}' > /dev/null
sleep 3
req1=$(jq -cn --arg vm "$vm" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"rpc",arguments:{vm:$vm,method:"ui.wait",params:{text:"zzznope",match:"contains",index:0,timeout_ms:12000},timeout_ms:1000}}}')
req2='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"methods","arguments":{"vm":"'"$vm"'","method":"input.tap"}}}'
session=$(printf '%s\n%s\n' "$req1" "$req2" | "$mcp")
r1=$(sed -n 1p <<< "$session")
r2=$(sed -n 2p <<< "$session")
check rpc-timeout-expires "$([ "$(iserr <<< "$r1")" = true ] && has "$(text <<< "$r1")" "after 1s; the guest call may still be running" && echo 1 || echo 0)" "$r1"
check rpc-timeout-server-continues "$([ "$(iserr <<< "$r2")" = false ] && [ "$(inner '.methods|length' "$r2")" = 1 ] && echo 1 || echo 0)" "$r2"
sleep 12
check guest-after-timeout "$(has "$(rpc device.screen)" width && echo 1 || echo 0)" "guest does not answer"

# --- push and pull ----------------------------------------------------------
head -c 70000 /dev/urandom > "$tmp/blob"
r=$(call push "$(jq -cn --arg l "$tmp/blob" '{local: $l, path: "/private/var/tmp/mcp-live-blob"}')")
check push "$([ "$(iserr <<< "$r")" = false ] && echo 1 || echo 0)" "$r"
r=$(call pull "$(jq -cn --arg l "$tmp/back" '{path: "/private/var/tmp/mcp-live-blob", local: $l}')")
check pull-roundtrip "$([ "$(iserr <<< "$r")" = false ] && cmp -s "$tmp/blob" "$tmp/back" && echo 1 || echo 0)" "$r"
r=$(call pull "$(jq -cn --arg l "$tmp/none" '{path: "/private/var/tmp/mcp-live-absent", local: $l}')")
check pull-missing "$([ "$(iserr <<< "$r")" = true ] && [ ! -e "$tmp/none" ] && echo 1 || echo 0)" "$r"
r=$(call push '{"local":"/nonexistent-local-file","path":"/private/var/tmp/x"}')
check push-missing-local "$([ "$(iserr <<< "$r")" = true ] && echo 1 || echo 0)" "$r"
rpc files.remove '{"path":"/private/var/tmp/mcp-live-blob"}' > /dev/null

# --- shell, real guest programs (absolute path; arguments cannot be passed, input goes to the terminal) --
r=$(shellcall '{"input":"1+1"}')
check shell-js-session "$([ "$(iserr <<< "$r")" = false ] && has "$(text <<< "$r")" 'probe> 1+1' && has "$(text <<< "$r")" '"exit":0' && echo 1 || echo 0)" "$r"
r=$(shellcall '{"program":"/sbin/ifconfig","input":"\n"}')
check shell-program-output "$([ "$(iserr <<< "$r")" = false ] && has "$(text <<< "$r")" 'lo0: flags=' && has "$(text <<< "$r")" '{"exit":0,"ok":true}' && echo 1 || echo 0)" "$(text <<< "$r" | head -c 200)"
r=$(shellcall '{"program":"/usr/bin/vm_stat","input":"\n"}')
check shell-program-output-2 "$([ "$(iserr <<< "$r")" = false ] && has "$(text <<< "$r")" 'Pages free' && echo 1 || echo 0)" "$(text <<< "$r" | head -c 200)"
r=$(shellcall '{"program":"/usr/bin/truncate","input":"\n"}')
check shell-nonzero-exit "$([ "$(iserr <<< "$r")" = false ] && has "$(text <<< "$r")" 'usage: truncate' && has "$(text <<< "$r")" '{"exit":1,"ok":true}' && echo 1 || echo 0)" "$r"
r=$(shellcall '{"program":"/no/such/program","input":"\n"}')
check shell-missing-program "$([ "$(iserr <<< "$r")" = true ] && has "$(text <<< "$r")" 'not an executable file' && echo 1 || echo 0)" "$r"
r=$(shellcall '{"program":"bash","input":"\n"}')
check shell-bash-absent-before-bootstrap "$([ "$(iserr <<< "$r")" = true ] && echo 1 || echo 0)" "$r"
r=$(shellcall '{"program":"/usr/sbin/spindump","input":"\n","timeout_seconds":3}')
check shell-program-timeout "$([ "$(iserr <<< "$r")" = true ] && has "$(text <<< "$r")" 'timeout after 3s; raise timeout_seconds' && echo 1 || echo 0)" "$(text <<< "$r" | tail -c 200)"
r=$(shellcall '{"program":"/usr/bin/ltop","input":"\n","timeout_seconds":5}')
check shell-output-cap "$([ "$(iserr <<< "$r")" = true ] && has "$(text <<< "$r")" 'output truncated at 1048576 bytes' && echo 1 || echo 0)" "$(text <<< "$r" | tail -c 200)"

# --- bootstrap and bash -----------------------------------------------------
# A fresh guest boots with a writable root, which the installer reports as layout rootful and refuses; one reboot
# makes it read-only again.
if [ "$(inner '.layout' "$(rpc device.environment)")" = rootful ]; then
r=$(rpc bootstrap.install '{"layout":"roothide"}')
check bootstrap-refused-while-rootful "$([ "$(iserr <<< "$r")" = true ] && has "$(text <<< "$r")" 'does not match the guest bootstrap' && echo 1 || echo 0)" "$r"
rpc system.reboot '{"userspace":false,"force":true}' > /dev/null
sleep 30
ready=0
for i in {1..40}; do
  r=$(rpc device.environment)
  if [ "$(iserr <<< "$r")" = false ] && [ "$(inner '.layout' "$r")" = null ]; then ready=1; break; fi
  sleep 5
done
check guest-back-after-reboot "$ready" "layout never became null: $(text <<< "$r" | head -c 200)"
fi
r=$(rpc bootstrap.install '{"layout":"roothide"}' 170000)
check bootstrap-install "$([ "$(iserr <<< "$r")" = false ] && [ "$(inner .layout "$r")" = roothide ] && echo 1 || echo 0)" "$(text <<< "$r" | head -c 300)"
# bootstrap.packages runs longer than the guest's HTTP reply window, so its reply can be a protocol timeout; the status decides.
rpc bootstrap.packages '' 170000 > /dev/null
done_pkgs=0
for i in {1..60}; do
  s=$(rpc bootstrap.status)
  if [ "$(inner .phase "$s")" = completed ] && has "$s" owngoal-bootstrap-vphone; then done_pkgs=1; break; fi
  sleep 10
done
check bootstrap-packages "$done_pkgs" "$(text <<< "$s")"
r=$(shellcall '{"program":"bash","input":"echo hi-$((6*7)); uname -s; exit 3"}')
check shell-bash-output "$([ "$(iserr <<< "$r")" = false ] && has "$(text <<< "$r")" 'hi-42' && has "$(text <<< "$r")" 'Darwin' && echo 1 || echo 0)" "$r"
check shell-bash-nonzero-exit "$(has "$(text <<< "$r")" '{"exit":3,"ok":true}' && echo 1 || echo 0)" "$(text <<< "$r" | tail -c 120)"
r=$(shellcall '{"program":"bash","input":"sleep 30","timeout_seconds":3}')
check shell-bash-timeout "$([ "$(iserr <<< "$r")" = true ] && has "$(text <<< "$r")" 'timeout after 3s' && echo 1 || echo 0)" "$(text <<< "$r" | tail -c 120)"

# --- two VMs at once, by the per-call vm argument ---------------------------
if [ -n "$vm2" ]; then
  sock2=$lib/$vm2/vphone.sock
  i=0
  until [ -S "$sock2" ] && [ "$(jq -r '.result.isError // false' <<< "$(callvm "$vm2" rpc '{"method":"device.screen"}' 2> /dev/null)" 2> /dev/null)" = false ]; do
    i=$((i + 1))
    [ $i -gt 60 ] && break
    sleep 5
  done
  check second-vm-answers "$([ "$(iserr <<< "$(callvm "$vm2" rpc '{"method":"device.screen"}')")" = false ] && echo 1 || echo 0)" "$vm2 did not answer: $(tail -n 3 "$tmp/launch-$vm2.log" 2> /dev/null | tr "\n" " ")"
  print -rn -- "marker-one" > "$tmp/m1"
  print -rn -- "marker-two" > "$tmp/m2"
  for round in 1 2 3; do
    callvm "$vm" push "$(jq -cn --arg l "$tmp/m1" '{local: $l, path: "/private/var/tmp/mcp-live-id"}')" > "$tmp/push1" &
    pj1=$!
    callvm "$vm2" push "$(jq -cn --arg l "$tmp/m2" '{local: $l, path: "/private/var/tmp/mcp-live-id"}')" > "$tmp/push2" &
    pj2=$!
    wait $pj1 $pj2
    callvm "$vm" pull "$(jq -cn --arg l "$tmp/p1" '{path: "/private/var/tmp/mcp-live-id", local: $l}')" > "$tmp/pull1" &
    pj1=$!
    callvm "$vm2" pull "$(jq -cn --arg l "$tmp/p2" '{path: "/private/var/tmp/mcp-live-id", local: $l}')" > "$tmp/pull2" &
    pj2=$!
    wait $pj1 $pj2
    ok=0
    [ "$(iserr < "$tmp/push1")" = false ] && [ "$(iserr < "$tmp/push2")" = false ] && [ "$(< "$tmp/p1")" = marker-one ] && [ "$(< "$tmp/p2")" = marker-two ] && ok=1
    check "two-vms-concurrent-round-$round" "$ok" "p1=$(< "$tmp/p1" 2> /dev/null) p2=$(< "$tmp/p2" 2> /dev/null)"
    rm -f "$tmp/p1" "$tmp/p2"
  done
  r=$(callvm "$vm2" device '{"action":"device.screen"}')
  check group-tool-on-second-vm "$([ "$(iserr <<< "$r")" = false ] && has "$(text <<< "$r")" width && echo 1 || echo 0)" "$r"
  r=$(callvm nosuchvm-$$ device '{"action":"device.screen"}')
  check vm-unknown "$([ "$(iserr <<< "$r")" = true ] && has "$(text <<< "$r")" "unknown vm" && echo 1 || echo 0)" "$r"
  callvm "$vm" rpc '{"method":"files.remove","params":{"path":"/private/var/tmp/mcp-live-id"}}' > /dev/null
  callvm "$vm2" rpc '{"method":"files.remove","params":{"path":"/private/var/tmp/mcp-live-id"}}' > /dev/null
fi

print -r -- "mcp live: $((pass + fail)) checks, $fail failures"
[ $fail = 0 ]
