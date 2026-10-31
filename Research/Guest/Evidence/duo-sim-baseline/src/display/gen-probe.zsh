#!/bin/zsh
# gen-probe.zsh <body-name> : writes probes/display-<body-name>.lldb from src/helpers + src/<body>.body + src/footer
set -euo pipefail
here=${0:a:h}
root=${here:h:h}
{ print -- "expr -l objc -O --"; cat $here/src/helpers.lldbfrag $here/src/$1.body $here/src/footer.lldbfrag; } > $root/probes/display-$1.lldb
print -- $root/probes/display-$1.lldb
