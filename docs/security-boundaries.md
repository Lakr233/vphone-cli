# Host and guest file boundaries

Imported VM manifests must name bundle-relative resources. Absolute paths, empty
components, `.`/`..`, NUL bytes, and symlinks (including dangling links) are rejected.
Missing resources remain valid for initial VM creation. Resource paths are checked
again before use. These checks do not defend against a concurrent host process
modifying the bundle after validation.

File-browser downloads validate each guest name as a single filename component.
Recursive downloads retain directory descriptors and use `openat` with
`O_NOFOLLOW`. Files are received into exclusive temporary files and committed
with `renameat`; an existing symlink or hard link is replaced, never truncated.
The initial destination is selected by the host user.

Binary responses must match a pending request and contain nonnegative integer
lengths. In-memory responses, including Quick Look and clipboard images, are
limited to 64 MiB. File-browser downloads stream through a 64 KiB buffer. Transfer
reads use the request deadline; outbound sends use nonblocking writes with a
30-second deadline and close the socket on failure; partial JSON frames have a 30-second deadline.
Malformed or incomplete transfers close the connection rather than reusing a
possibly misaligned stream. Streaming bounds memory, not total disk consumption.

The host installer allocates a private mount directory, checks mounted devices,
and runs guest-mutating commands through `guest_write`. Its macOS sandbox permits
writes only inside the three guest mount directories, preventing guest symlinks
from redirecting privileged writes into host staging or system files. Host tool
preparation runs separately. Missing or rejected sandbox support fails the guest
write. Cleanup uses `rmdir`, never recursive deletion of potentially mounted data.

## Regression checks

Run on macOS from the repository root:

```sh
zsh tests/test_cfw_install_safety.sh
swiftc -swift-version 6 sources/VPhoneCore/*.swift tests/security_regressions.swift -o /tmp/vphone-security-tests
/tmp/vphone-security-tests
swift test
make build
```

The standalone tests exercise actual core sources without requiring XCTest. The
installer tests use disposable directories and sentinel files; they do not mount
APFS images or require root. A full installation with a disposable VM remains a
separate integration check.
