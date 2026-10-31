#!/bin/zsh
# vm-convert.zsh <sim-probe.lldb>... : write probes/vm-<name>.lldb beside each one.
#
# Two guest-JIT problems on the VM (arm64e.x1), both in vm-notes.md:
# 1. lldb signs only one cast-call site of objc_msgSend per expression; the others go through
#    the unsigned GOT entry and fault with EXC_GUARD (code 261, blraaz). Fix: declare
#    `void *vpMsg = (void *)objc_msgSend;` first and cast vpMsg instead.
# 2. strcmp / strncmp called from an expression return garbage (lldb binds them to the wrong
#    address; strlen is fine). Fix: blocks vpStrcmp / vpStrncmp declared first.
# 3. The sim probes trace the getter being called into a host file (vpTrace); on the VM that
#    file is /var/tmp/vptrace.txt in the guest (read it with files.read).
set -euo pipefail
for src in "$@"; do
  dst=${src:h}/vm-${src:t}
  awk '
    function flush() {
      if (n) {
        if (casts) print "void *vpMsg = (void *)objc_msgSend;";
        if (scmp) print "int (^vpStrncmp)(const char *, const char *, size_t) = ^int(const char *a, const char *b, size_t n) { for (size_t i = 0; i < n; i++) { if (a[i] != b[i]) return (unsigned char)a[i] - (unsigned char)b[i]; if (!a[i]) return 0; } return 0; };";
        if (scmp) print "int (^vpStrcmp)(const char *, const char *) = ^int(const char *a, const char *b) { return vpStrncmp(a, b, (size_t)-1); };";
        for (i = 1; i <= n; i++) print buf[i];
      }
      n = 0; casts = 0; scmp = 0
    }
    /^expr .*--$/ { flush(); print; inexpr = 1; next }
    inexpr && /^$/ { flush(); print; inexpr = 0; next }
    inexpr {
      line = $0
      casts += gsub(/\)objc_msgSend\)\(/, ")vpMsg)(", line)
      scmp += gsub(/(^|[^A-Za-z_])strncmp\(/, "&", line)
      scmp += gsub(/(^|[^A-Za-z_])strcmp\(/, "&", line)
      gsub(/strncmp\(/, "vpStrncmp(", line); gsub(/strcmp\(/, "vpStrcmp(", line)
      buf[++n] = line; next
    }
    { print }
    END { flush() }
  ' $src | sed "s#/private/tmp/[^\"]*/vptrace.txt#/var/tmp/vptrace.txt#" > $dst
  print "$dst: $(grep -c 'vpMsg)(' $dst) msgSend casts, $(grep -oE 'vpStrn?cmp\(' $dst | wc -l | tr -d ' ') str*cmp calls rewritten"
done
