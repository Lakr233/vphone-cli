# Preserve X1 lowering when applications install crash reporters

## Failure and reproduction

An iOS 27.1 (24A94425) / cloudOS 26.4 (23E5207q) Duo guest can launch an app,
then lose the inherited `EXC_BAD_INSTRUCTION` action when the app registers its
own task exception ports. The launchd handler can no longer lower an X1
instruction encountered later in a standalone image.

Observed with Taobao 10.69.0 (59622514), after separately addressing a legacy
TXM remap failure and an Intents metadata assertion:

1. Launch the app on a host requiring X1 lowering.
2. Its crash reporter calls `task_set_exception_ports` for mask `0x106e`.
3. FramePacing later calls into the separately loaded
   `libMetalMetricsInterpose.dylib` (`arm64e.x1`).
4. `FPMTLMetricsInterposeGetDetachCode` or `FPMTLMetricsInterposeInit` executes
   `PACIBSPPC` (`0xdac1a7fe`) and the process terminates with `SIGILL`; the
   recorded terminating process is the app's own `exc handler`.

Lowering one function exposed the next unlowered function. Keeping the inherited
exception action instead let the existing X1 handler deal with the actual
instruction sites without adding a system-library offset or binary patch.

## Change and boundaries

SystemHook now interposes `task_set_exception_ports` using the same cached
inherited-action discovery as `VPhoneX1Spawn.c` already uses for spawn attributes.
For the current task, if an inherited action has the existing X1 shape
(`EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES`, flavor 0, a non-null port), remove
only `EXC_MASK_BAD_INSTRUCTION` from the application's registration. In the
observed case `0x106e` becomes `0x106a`. An otherwise empty request is a no-op.

Other exception bits, remote-task requests, port/behavior/flavor arguments and
underlying error results are forwarded unchanged. If discovery fails or finds
no compatible inherited action, the entire request is unchanged. Discovery
retains the send right for the lifetime of the process, as the existing spawn
path does. This adds no firmware patch declaration or preset.

The inherited-action shape is the existing spawn policy's heuristic, not a new
attestation of its receiver. `task_swap_exception_ports`, thread-level exception
registration and direct Mach messages are outside this change. On a matching
guest, genuine illegal instructions also continue through the inherited handler
and its original forwarding path, rather than the app's new crash reporter.
This is an explicit crash-reporting tradeoff of preserving guest compatibility.

## Validation

- `test-x1-task-exceptions` uses ASan/UBSan and mocks only the Mach boundary. It
  checks mixed and BAD_INSTRUCTION-only masks, unchanged non-X1 registrations,
  remote tasks, invalid empty requests, missing/query-failed inherited actions,
  incompatible behavior/flavor, send-right ownership, one-time discovery and
  propagation of registration errors.
- Existing `test-x1-lowering` and `test-mach-ports-compat` remain separate
  regression checks.
- The full `VPhone` Debug bundle build, signing and bundle admission pass with
  Xcode 27.1. This includes the arm64e guest SystemHook payload.
- An application-scoped equivalent on the above guest recorded both the
  inherited compatible action and the `0x106e` to `0x106a` registration. Two
  cold starts reached the homepage; fold/unfold rendered; backgrounding for
  16 seconds and restoring retained the same PID. Crash count did not grow.
  That runtime check used an app-local shim, not this complete SystemHook build.

The app-local check also needed a bounded executable-remap fallback on this
guest's old flashed TXM and removal of optional Siri parameter-combination
metadata to avoid Foundation's `_predicateSecurityAction`. Neither workaround
is part of this PR. In particular, this change alone does not establish that
the untouched application will start on every guest or that the Intents
assertion has a general fix. No application binaries, account credentials,
SINF data, models or raw private captures are included in the repository.
