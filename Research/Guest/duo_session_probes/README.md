# Native X1 validation probes

These small standalone probes reproduce historical validation. They are not
added to normal test schemes and do not change host security settings.

On a host that supports PACIBSPPC/PAUTH-LR, from the repository root:

```sh
xcrun clang -arch arm64 -march=armv9.5-a+pauth-lr -c \
  Research/Guest/duo_session_probes/native_pac_reference.s \
  -o /tmp/vphone-pac-reference.o
xcrun clang -arch arm64 -O0 \
  Research/Guest/duo_session_probes/native_pac_relocation.c \
  /tmp/vphone-pac-reference.o -o /tmp/vphone-pac-probe
/tmp/vphone-pac-probe
```

The native reference and relocated sequence sign 4,096 input values with the
same original PC and SP. This command passed again while preparing the local
review candidate. Keep the C compilation at baseline ARM64 and unoptimized:
compiling the whole program for ARMv9.5 may introduce unrelated instructions
the host does not support, and this fixture depends on matched call-stack
shape. Unsupported hardware may raise an illegal-instruction exception.
This is a targeted signing equivalence check, not a comprehensive detour test.

`guest_mis_validation.c` is the original in-guest 64-call MIS validation probe.
It needs the guest libmisfix hook and an executable path supplied explicitly
as argv[1]; it does not install or launch an app. Build/sign/deploy it using
the project's existing guest-tool workflow. No signed probe, app bundle,
certificate or personal test application is included here.
