#!/bin/bash
# usage: rpc.sh method 'json-params'
S=~/.vphone/machines/Basil/vphone.sock
printf '%s\n' "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":${2:-{\}}}" | timeout ${3:-20} nc -U $S
