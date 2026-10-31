#!/bin/zsh
# build.zsh: assemble probes/chrome-*.lldb from probes/parts/ (one lldb expression each).
set -euo pipefail
here=${0:a:h}; p=$here/parts
mk() { local out=$1; shift; { print -- 'expr -l objc -O --'; cat $p/chrome-lib.inc $p/chrome-emit.inc; for s in "$@"; do cat $p/chrome-$s.inc; done; cat $p/chrome-footer.inc; print; } > $here/$out }
mk chrome-state.lldb scene statusbar home wallpaper hinge
mk chrome-lock.lldb scene statusbar lock
[[ -z ${CHROME_TEST_PARTS:-} ]] || mk chrome-test.lldb ${=CHROME_TEST_PARTS}
mk chrome-hinge.lldb hinge
