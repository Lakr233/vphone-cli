#!/bin/bash
# usage: bsh.sh <script-file> [timeout]  -- run a bash script inside Basil through the shell socket (root)
S=~/.vphone/machines/Basil/vphone.sock
T=${2:-60}
{
  echo '{"t":"shell","program":"/var/jb/usr/bin/bash","cols":220,"rows":50}'
  sleep 1
  # send line by line with a pause: the pty is fresh and chokes on a burst
  while IFS= read -r line; do echo "$line"; sleep 0.05; done < "$1"
  echo 'echo __END__'
  sleep "$T"; echo exit
} | timeout $((T+15)) nc -U "$S" 2>&1
