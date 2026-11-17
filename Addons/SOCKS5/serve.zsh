#!/bin/zsh
# launchd supplies the machine directory as the working directory.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
[[ -S vphone.sock ]] || exit 0
[[ $(plutil -extract networkConfig.mode raw -o - config.plist) == nat ]] || exit 0
# network.ipv4.get names an address only for a manual configuration; a DHCP
# guest's live address is in device.network's interface list.
address=$(print -r -- '{"t":"rpc","method":"device.network","params":{},"screen":false}' |
  nc -w 5 -U vphone.sock |
  jq -r '[.result.addresses[]? | select(test("^en0 [0-9.]+$")) | ltrimstr("en0 ")][0] // empty')
octets=(${(s:.:)address})
(( ${#octets} == 4 )) || exit 1
for octet in "${octets[@]}"; do
  [[ "$octet" == <0-255> ]] || exit 1
done
[[ "$address" != 0.0.0.0 && "$address" != 127.* ]] || exit 1
cidr=$(plutil -extract networkConfig.ipv4.address raw -o - config.plist 2>/dev/null || true)
[[ -z "$cidr" || "${cidr%/*}" == "$address" ]] || exit 1

# Only the validated IPv4 address enters this guest script. Launchd owns the
# socket client. Closing it ends the terminal session and the guest process.
exec nc -U vphone.sock <<SESSION
{"t":"shell"}
var dir = "/private/var/db/vphone-socks5", config = dir + "/proxy.yml"
var settings = {main: {workers: 2, port: 1080, "listen-address": "$address", "udp-listen-address": "$address", "udp-public-address-v4": "$address"}}
if (api("files.write", {path: config, content: JSON.stringify(settings), encoding: "utf8"}).bytes > 0) proc.run(dir + "/hev-socks5-server", [config])
.exit
SESSION
