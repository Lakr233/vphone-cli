#!/bin/bash
# usage: shot.sh name -> /tmp/ym/shots/name.png
mkdir -p /tmp/ym/shots
printf '%s\n' "{\"t\":\"screenshot\",\"path\":\"/tmp/ym/shots/$1.png\"}" | timeout 20 nc -U ~/.vphone/machines/Basil/vphone.sock
echo|cut -c1-120
