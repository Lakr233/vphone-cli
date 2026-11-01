# Local iOS 16.6.1 bring-up experiment

Status: original IPSW restored; guest custom-firmware installation and normal
boot are still under investigation. No desktop success is claimed yet.

- Guest: iPhone 14 Pro, iPhone15,2/d73ap, 1179x2556 at 3x.
- Userland: iOS 16.6.1, 20G81.
- Boot chain and kernel: cloudOS 26.1, 23B85, vphone600.
- VM: 6 CPUs, 6144 MB RAM, 64 GB disk, no NIC.
- Apple IPSW: `https://updates.cdn-apple.com/2023SummerFCS/fullrestores/042-44327/EDD9D5D2-E1C0-4B64-B6B1-642E087BB595/iPhone15,2_16.6.1_20G81_Restore.ipsw`.
- IPSW SHA-1: `1d80ba85912850bb6cc62540730652b29e4c3e8e` (verified after download).

This branch enables the existing older-userland SwapEnd, thread-guard and
paravirtual-user-client declarations for 16, plus the BSD-only Skywalk boot
argument. It does not enable the iOS 17-specific SpringBoard library on 16.
Firmware preparation is restricted to this exact experimental pairing.

Initial validation: complete native bundle build and admission passed;
69 selected firmware/patch-model tests and 20 guest-device tests passed.
The original IPSW restore completed. Guest installation was then refused by
the host helper while walking the external library path, even though that
directory exists. A separate internal-disk copy is being used to distinguish
host path access from guest compatibility.

On the pristine 20G81 seputil, the existing patch resolved the complete
`%s/%s.gl` literal at 0x10001D3A4 through a code reference at 0x10000BEC4.
It changed only the filename field to `AA` and an immediate second run was
idempotent. This is an offline binary check, not evidence of a normal boot.

The internal copy and its bundle binding are ready. The full guest install is
currently waiting for the user's macOS administrator authentication. The UI
tool cannot access SecurityAgent. Normal boot remains untested.
