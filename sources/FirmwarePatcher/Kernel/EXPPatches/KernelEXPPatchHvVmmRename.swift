// KernelEXPPatchHvVmmRename.swift — EXP kernel patch: rename the
// `hv_vmm_present` sysctl OID name AND mangle every kernel-internal
// `kern.hv_vmm_present` caller cstring so they keep working after the
// rename.
//
// Variant scope: `.exp` only. JB and other variants are NOT affected.
//
// Two-part design:
//
//   Part A (OID rename): single byte change at offset 0 of the
//     14-byte NUL-delimited cstring `\0hv_vmm_present\0` (the OID's
//     `oid_name` value): 'h' (0x68) → 'X' (0x58). After this, the
//     kernel resolves `sysctlbyname("kern.hv_vmm_present", ...)` as
//     ENOENT and `sysctlbyname("kern.Xv_vmm_present", ...)` to the
//     OID's real int value (1 on this VM).
//
//   Part B (internal caller mangle): single byte change at offset 5
//     of every kernel-internal NUL-delimited cstring
//     `\0kern.hv_vmm_present\0`: the `'h'` after `kern.` → `'X'`. This
//     covers cstrings that the kernel itself, AMFI, or other kexts
//     hard-code as the full sysctl name when they call a kernel-side
//     sysctlbyname-equivalent. Without this mangle those callers
//     query the now-ENOENT name and take their "not in a VM" branch,
//     which on this hardware causes AMFI to panic with
//     "AMFI: No PMGR?" (ConfigurationSettings.cpp:388) during ramdisk
//     boot. Mangling those callers to the new name makes them see
//     the truthful `1` again — same value they got pre-Part-A.
//
// User-mode counterpart
// ---------------------
// `scripts/patchers/cfw_patch_hv_vmm_dsc.py` applies the same byte-5
// mangle to DSC dylibs that are NOT in `DONT_PATCH_INSTALL_NAMES`
// (graphics + accel passthrough). Blacklisted dylibs keep the
// original cstring and hit ENOENT after Part A. The two halves
// (kernel + user-mode) together implement the blacklist-flip
// design: callers that should see `1` (graphics, accel, AMFI,
// other kexts) get the byte-5 mangle; callers that should see
// ENOENT-which-defensively-caches-0 (sign-in / device-likeness
// libs) get left alone.
//
// Reveal strategy
// ---------------
// The kernelcache's LC_SYMTAB is fully stripped on this build, so
// symbol-based reveals don't apply. Both parts work by byte search
// for cstrings in `buffer.data`:
//
//   - Part A's needle is `\0hv_vmm_present\0` (16 bytes). We require
//     exactly one match — there's only one OID with this short name.
//   - Part B searches for two byte-aligned forms of the
//     `kern.hv_vmm_present` name:
//       (i)  `\0kern.hv_vmm_present\0` (21 bytes) — the standard
//            NUL-delimited cstring form used by code in
//            `__TEXT,__cstring` of every kext that calls
//            `sysctlbyname` by full name. Verified consumers on
//            iPhone17,3 / iOS 26.1: AMFI, IOCryptoAcceleratorFamily,
//            sandbox (regular cstring), apfs.
//       (ii) `kern.hv_vmm_present\x0f` (20 bytes, no leading or
//            trailing NUL) — a sandbox-profile name-token. The
//            compiled sandbox-profile format inside
//            com.apple.security.sandbox stores OID names this way;
//            without this needle, Part B misses one occurrence at
//            file offset 0xa6618b. The token's terminator byte
//            `\x0f` is the sandbox-profile end-of-name marker.
//     Each match is mangled at byte 5 of the cstring/token (the
//     `'h'` after `kern.`) → `'X'`, producing `kern.Xv_vmm_present`,
//     so sysctlbyname-by-name callers and sandbox-profile name
//     matches both continue to resolve correctly after Part A's
//     OID rename.
//
// Idempotence
// -----------
// Re-running this patch is a no-op:
//   - Part A: detects post-patch `\0Xv_vmm_present\0` and bails.
//   - Part B: each cstring's byte 5 is checked before write; if it
//     is already 'X' the patcher skips that occurrence.

import Foundation

extension KernelEXPPatcher {
    /// Apply Part A (OID rename) + Part B (kernel-internal caller
    /// byte-5 mangle). Returns true if any byte was modified.
    @discardableResult
    func patchHvVmmRename() -> Bool {
        log("\n[EXP] hv_vmm_present sysctl: OID rename + kernel-internal caller mangle")
        let aChanged = renameOidNameCstring()
        let bChanged = mangleKernelInternalCallers()
        return aChanged || bChanged
    }

    // MARK: - Part A: rename the OID's name cstring

    /// Rename `\0hv_vmm_present\0` → `\0Xv_vmm_present\0` (single byte at
    /// offset 0 of the 14-byte cstring). Exactly one occurrence is required.
    private func renameOidNameCstring() -> Bool {
        // Bytes:  '\0' 'h' 'v' '_' 'v' 'm' 'm' '_' 'p' 'r' 'e' 's' 'e' 'n' 't' '\0'
        let needle = Data([
            0x00, 0x68, 0x76, 0x5F, 0x76, 0x6D, 0x6D, 0x5F,
            0x70, 0x72, 0x65, 0x73, 0x65, 0x6E, 0x74, 0x00,
        ])
        let patched = Data([
            0x00, 0x58, 0x76, 0x5F, 0x76, 0x6D, 0x6D, 0x5F,
            0x70, 0x72, 0x65, 0x73, 0x65, 0x6E, 0x74, 0x00,
        ])

        let originalHits = buffer.findAll(needle)
        let patchedHits = buffer.findAll(patched)

        if originalHits.isEmpty, patchedHits.count == 1 {
            log("  [.] Part A: OID name already renamed at foff 0x"
                + String(format: "%X", patchedHits[0] + 1))
            return false
        }

        guard !originalHits.isEmpty else {
            log("  [-] Part A: no NUL-delimited 'hv_vmm_present' cstring "
                + "found — OID may have a different name shape on this build")
            return false
        }

        guard originalHits.count == 1 else {
            let list = originalHits.map { String(format: "0x%X", $0 + 1) }
                .joined(separator: ", ")
            log("  [-] Part A: expected exactly 1 NUL-delimited "
                + "'hv_vmm_present' cstring, found \(originalHits.count) "
                + "(\(list)) — refusing to rename ambiguously")
            return false
        }

        if !patchedHits.isEmpty {
            log("  [-] Part A: both original and renamed cstrings present "
                + "(\(originalHits.count) + \(patchedHits.count)) — refusing")
            return false
        }

        let cstringStart = originalHits[0] + 1
        let firstByte = buffer.data[cstringStart]
        guard firstByte == 0x68 else {
            log("  [-] Part A: unexpected first byte at 0x"
                + String(format: "%X", cstringStart)
                + " (found 0x\(String(format: "%02X", firstByte)), "
                + "expected 0x68 'h') — refusing")
            return false
        }

        let va = fileOffsetToVA(cstringStart)
        emit(cstringStart,
             Data([0x58]),
             patchID: "kernelcache_exp.hv_vmm_oid_rename",
             virtualAddress: va,
             description: "Part A: rename OID name 'h' -> 'X' "
                + "('hv_vmm_present' -> 'Xv_vmm_present')")
        return true
    }

    // MARK: - Part B: mangle kernel-internal `kern.hv_vmm_present` callers

    /// For every kernel-internal occurrence of `kern.hv_vmm_present`
    /// inside the kernelcache buffer (kernel proper + kexts + fileset
    /// entries + compiled sandbox-profile blobs), flip byte 5 of the
    /// cstring/token from 'h' to 'X' so it becomes
    /// `kern.Xv_vmm_present`. Matches Part A's OID rename, so the
    /// caller's runtime sysctlbyname call (or the sandbox profile's
    /// name-token comparison) now hits the renamed OID and gets the
    /// truthful 1.
    ///
    /// Two byte-aligned forms are handled:
    ///   - NUL-delimited cstring `\0kern.hv_vmm_present\0` (4 known
    ///     occurrences: AMFI, IOCryptoAcceleratorFamily, sandbox
    ///     cstring, apfs).
    ///   - Sandbox-profile name-token `kern.hv_vmm_present\x0f` —
    ///     trailing `\x0f` is the sandbox-profile end-of-name marker,
    ///     no leading NUL. 1 known occurrence inside
    ///     com.apple.security.sandbox.
    private func mangleKernelInternalCallers() -> Bool {
        // ── Form (i): NUL-delimited cstring.
        //   21 bytes total (leading NUL + 19 cstring bytes + trailing NUL).
        //   Mangle offset within the needle: 1 (skip leading NUL) + 5 = 6.
        let cstrOriginalNeedle = Data([
            0x00,                                            // \0
            0x6B, 0x65, 0x72, 0x6E, 0x2E,                    // "kern."
            0x68, 0x76, 0x5F, 0x76, 0x6D, 0x6D, 0x5F,        // "hv_vmm_"
            0x70, 0x72, 0x65, 0x73, 0x65, 0x6E, 0x74,        // "present"
            0x00,                                            // \0
        ])
        let cstrPatchedNeedle = Data([
            0x00,
            0x6B, 0x65, 0x72, 0x6E, 0x2E,                    // "kern."
            0x58, 0x76, 0x5F, 0x76, 0x6D, 0x6D, 0x5F,        // "Xv_vmm_"
            0x70, 0x72, 0x65, 0x73, 0x65, 0x6E, 0x74,
            0x00,
        ])

        // ── Form (ii): sandbox-profile name-token.
        //   20 bytes total (19 name bytes + trailing \x0f). No leading byte
        //   in the needle. Mangle offset within the needle: 5.
        let tlvOriginalNeedle = Data([
            0x6B, 0x65, 0x72, 0x6E, 0x2E,                    // "kern."
            0x68, 0x76, 0x5F, 0x76, 0x6D, 0x6D, 0x5F,        // "hv_vmm_"
            0x70, 0x72, 0x65, 0x73, 0x65, 0x6E, 0x74,        // "present"
            0x0F,                                            // sandbox EOT
        ])
        let tlvPatchedNeedle = Data([
            0x6B, 0x65, 0x72, 0x6E, 0x2E,
            0x58, 0x76, 0x5F, 0x76, 0x6D, 0x6D, 0x5F,        // "Xv_vmm_"
            0x70, 0x72, 0x65, 0x73, 0x65, 0x6E, 0x74,
            0x0F,
        ])

        // (mangle position relative to the needle's start, originalByte)
        let sites: [(needle: Data, patched: Data, mangleDelta: Int, label: String)] = [
            (cstrOriginalNeedle, cstrPatchedNeedle, 6, "cstring"),
            (tlvOriginalNeedle, tlvPatchedNeedle, 5, "sandbox-profile token"),
        ]

        var totalOriginal = 0
        var totalPatched = 0
        var totalWritten = 0

        for site in sites {
            let originalHits = buffer.findAll(site.needle)
            let patchedHits = buffer.findAll(site.patched)
            totalOriginal += originalHits.count
            totalPatched += patchedHits.count

            log("  [.] Part B (\(site.label)): \(originalHits.count) "
                + "original, \(patchedHits.count) already-mangled")

            for needleOff in originalHits {
                let mangleOffset = needleOff + site.mangleDelta

                // Defensive re-check: the byte we're about to flip must
                // be 'h' (0x68). If it isn't, something has changed
                // structurally — skip this occurrence and log it.
                let byteHere = buffer.data[mangleOffset]
                guard byteHere == 0x68 else {
                    log("  [-] Part B (\(site.label)): byte at 0x"
                        + String(format: "%X", mangleOffset)
                        + " is 0x\(String(format: "%02X", byteHere)), "
                        + "expected 0x68 'h' — skipping")
                    continue
                }

                let va = fileOffsetToVA(mangleOffset)
                emit(mangleOffset,
                     Data([0x58]),
                     patchID: "kernelcache_exp.hv_vmm_internal_caller_mangle",
                     virtualAddress: va,
                     description: "Part B (\(site.label)): byte-5 mangle "
                        + "'h' -> 'X' at foff 0x"
                        + String(format: "%X", mangleOffset)
                        + " ('kern.hv_vmm_present' -> 'kern.Xv_vmm_present')")
                totalWritten += 1
            }
        }

        let totalKnown = totalOriginal + totalPatched
        log("  [.] Part B summary: \(totalOriginal) original + "
            + "\(totalPatched) already-mangled (total \(totalKnown)) — "
            + "wrote \(totalWritten) byte(s)")

        if totalOriginal == 0 {
            if totalPatched == 0 {
                log("  [.] Part B: no kernel-internal callers found — "
                    + "either no kext queries the sysctl by full name, "
                    + "or they all live elsewhere")
            } else {
                log("  [.] Part B: all \(totalPatched) kernel-internal "
                    + "occurrence(s) already mangled — nothing to do")
            }
            return false
        }

        if totalWritten > 0 {
            log("  [+] Part B: mangled \(totalWritten) kernel-internal "
                + "occurrence(s) (cstring + sandbox-profile combined)")
        }
        return totalWritten > 0
    }
}
