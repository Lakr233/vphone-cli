// CustomFirmwareMobileActivation.swift — force `-[DeviceType should_hactivate]` to YES.
//
// Swift port of `scripts/patchers/cfw_patch_mobileactivationd.py`, driven by
// `cfw.py patch-mobileactivationd <binary>` from `cfw_install{,_dev}.sh` and
// `cfw-kit/lib/base_stages.sh`'s `stage_mobileactivationd`.
//
// `mobileactivationd` asks `-[DeviceType should_hactivate]` whether the device
// may activate itself without talking to albert.apple.com. On a real iPhone the
// answer is NO and Setup.app sits on the activation screen forever, which is
// where an unpatched guest ends up. The method is a synthesised `_BOOL` ivar
// getter — two instructions, `ldrb w0, [x0, #<ivar>]` then `ret` — so forcing
// YES is `mov x0, #1 ; ret` over the same eight bytes. No cave, no shifting.
//
// Anchoring, and why it is not the Python's
// ----------------------------------------
// The Python takes two shortcuts this does not copy.
//
//   1. It resolves the IMP with a *substring* search over LC_SYMTAB
//      (`find_symbol_va(data, "should_hactivate")`) and patches the first hit.
//      On the iOS 27.0 / 24A435 iPhone17,3 binary four symbols contain that
//      substring — the method, `_objc_msgSend$should_hactivate` (a selector
//      stub in `__TEXT,__objc_stubs`), `_OBJC_IVAR_$_DeviceType._should_hactivate`
//      (a *data* offset in `__DATA`) and a duplicate N_STAB debug entry. It
//      works today only because the method happens to sort first. Patching the
//      ivar-offset word instead would corrupt every access to the ivar.
//      Here the symbol is matched by its exact ObjC name, STAB debug entries
//      are skipped, and the symbol must be N_SECT-defined.
//
//   2. Its ObjC-metadata fallback is dead code on this binary, twice over: it
//      takes the first `memmem` hit for `should_hactivate\0`, which lands at
//      the tail of the property-attribute string `TB,R,N,V_should_hactivate`
//      — the `V` field naming the backing ivar — 0x2F4D bytes before the real
//      selector; and it looks for relative method lists in `__objc_const`,
//      where iOS 16+ no longer puts them (they live in
//      `__TEXT,__objc_methlist`). Called directly on the pristine binary it
//      prints "Selref not found (chained fixups may obscure pointers)" and
//      returns -1. The fallback here finds the NUL-preceded selector,
//      unpacks chained-fixup rebase targets, and walks real relative method
//      lists — so it resolves the same IMP the symbol table does, which is how
//      the anchor is cross-checked rather than trusted.
//
// Both routes run. When both resolve they must agree, or the binary is not the
// shape we were told it was and the run stops. Nothing is a literal address.
//
// Re-attestation
// --------------
// `codeSigningMonitor == 2` on this stack, so TXM holds the original per-page
// slot hashes and any byte changed inside an executable mapping is a SIGKILL on
// first page-in. The touched page is re-hashed through `CustomFirmwareMachOCodeSignature`.
// The Python leaves that to the `ldid_sign` that follows it in the shell; doing
// it here means the binary is runnable the moment it is written, and the later
// `ldid_sign` stays a no-op-in-effect re-sign. Pass `resign: false` to get the
// Python's exact bytes.

import Capstone
import Foundation

/// Forces `-[DeviceType should_hactivate]` to return YES, so the guest
/// self-activates instead of waiting on Apple's activation service.
public enum CustomFirmwareMobileActivation {
    // MARK: - Identity

    /// The ObjC method whose result is forced.
    public static let method = "-[DeviceType should_hactivate]"

    /// The selector, as it appears in `__TEXT,__objc_methname`.
    public static let selector = "should_hactivate"

    /// Component name, matching `records.set_group("mobileactivationd")`.
    public static let component = "mobileactivationd"

    /// Record identity, matching the Python's `records.site` label so a captured
    /// reference and this port sort together.
    public static let patchID = "mobileactivationd.should_hactivate"

    /// Where progress goes when the caller does not say. The Python prints to
    /// stdout and `cfw_install*.sh` captures that, so this does too.
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    // MARK: - Results

    /// Which anchor produced the IMP address.
    public enum AnchorSource: String, Sendable, Equatable {
        /// Both the symbol table and the ObjC metadata chain resolved, and agreed.
        case symbolTableAndObjCMetadata
        /// Only `LC_SYMTAB` carried the method — a binary whose ObjC metadata
        /// this port cannot walk (a layout change), but whose symbol is exact.
        case symbolTable
        /// Only the ObjC metadata chain resolved — a stripped binary.
        case objcMetadata
    }

    /// The located IMP.
    public struct Anchor: Sendable, Equatable {
        public let virtualAddress: UInt64
        public let fileOffset: Int
        public let source: AnchorSource
        /// `segment,section` the IMP lands in. Always an executable one.
        public let section: String
    }

    /// What a run did.
    public enum Outcome: String, Sendable, Equatable {
        /// The eight bytes already read `mov x0, #1 ; ret`. Nothing was written.
        case alreadyPatched
        /// `dryRun` was set, so the site was located and reported only.
        case wouldPatch
        /// The getter was rewritten and its page re-attested.
        case patched
    }

    /// The outcome of one run, and the site it acted on.
    public struct Report: Sendable {
        public let outcome: Outcome
        public let anchor: Anchor
        /// The write, in the shape the Python's reference capture records it.
        /// `nil` unless bytes actually changed.
        public let record: PatchRecord?
        /// Code-directory slots recomputed for the page the write landed in.
        /// Empty on a dry run, and on a re-run whose slots already match.
        public let slotRehashes: [CustomFirmwareSlotRehash]

        /// Sites whose bytes this run changed. The parity number: the Python
        /// writes exactly one, and so must this.
        public var sitesWritten: Int {
            record == nil ? 0 : 1
        }
    }

    // MARK: - Patching

    /// Patch the `mobileactivationd` at `url` in place.
    ///
    /// Idempotent: a second run finds `mov x0, #1 ; ret` already in place,
    /// reports ``Outcome/alreadyPatched`` and leaves the file untouched, byte
    /// for byte. It does not error and it does not write the getter twice.
    ///
    /// - Parameters:
    ///   - url: The `mobileactivationd` Mach-O to patch.
    ///   - resign: Recompute the code-directory slot hash of the touched page.
    ///     `false` reproduces the Python's output exactly, for byte comparison.
    ///   - dryRun: Locate and report, write nothing.
    /// - Throws: ``PatcherError/patchSiteNotFound(_:)`` when neither anchor
    ///   resolves, ``PatcherError/invalidFormat(_:)`` when the two anchors
    ///   disagree or the site is not executable code.
    @discardableResult
    public static func patch(
        fileAt url: URL,
        resign: Bool = true,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let before = data
        let report = try patch(&data, resign: resign, dryRun: dryRun, log: log)

        // Written only when something changed, so a no-op run does not even
        // touch the file's mtime — and so `sha256` before and after a re-run
        // is trivially the same number.
        if data != before {
            try data.write(to: url)
        }
        return report
    }

    /// In-memory form of ``patch(fileAt:resign:dryRun:log:)``.
    @discardableResult
    public static func patch(
        _ data: inout Data,
        resign: Bool = true,
        dryRun: Bool = false,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        if data.startIndex != 0 {
            data = Data(data)
        }

        let anchor = try locateIMP(in: data)
        log?("  [.] \(method) @ 0x\(hex(anchor.virtualAddress)) "
            + "-> foff 0x\(hex(UInt64(anchor.fileOffset))) "
            + "in \(anchor.section) (via \(anchor.source.rawValue))")

        let patched = try replacementBytes()
        guard data.count >= anchor.fileOffset + patched.count else {
            throw PatcherError.invalidFormat(
                "\(method): IMP at 0x\(hex(UInt64(anchor.fileOffset))) is past the end of the file",
            )
        }
        let original = Data(data[anchor.fileOffset ..< anchor.fileOffset + patched.count])
        let body = try decodeBody(original, at: anchor.virtualAddress)

        log?("      [.] before: \(text(of: body))")

        if original == patched {
            // The already-patched shape, recognised rather than re-applied.
            // `8eb6c8b` fixed this exact class of bug for the DSC gates.
            log?("      [=] already `mov x0, #1 ; ret` at 0x\(hex(anchor.virtualAddress)); "
                + "nothing to write")
            let rehashes = dryRun || !resign
                ? []
                : try CustomFirmwareMachOCodeSignature.reattest(&data, modifiedOffsets: touchedOffsets(anchor, patched))
            if !rehashes.isEmpty {
                log?("      [+] re-attested \(rehashes.count) stale slot(s): "
                    + rehashes.map(\.description).joined(separator: ", "))
            }
            return Report(
                outcome: .alreadyPatched,
                anchor: anchor,
                record: nil,
                slotRehashes: rehashes,
            )
        }

        guard isPlausibleGetterBody(body) else {
            throw PatcherError.invalidFormat(
                "\(method): body at 0x\(hex(anchor.virtualAddress)) reads `\(text(of: body))`, "
                    + "which is not a two-instruction body this patch can replace",
            )
        }

        guard !dryRun else {
            log?("      [.] dry-run: would write \(original.hex) -> \(patched.hex) "
                + "at foff 0x\(hex(UInt64(anchor.fileOffset)))")
            return Report(outcome: .wouldPatch, anchor: anchor, record: nil, slotRehashes: [])
        }

        data.replaceSubrange(anchor.fileOffset ..< anchor.fileOffset + patched.count, with: patched)
        try log?("      [+] after:  \(text(of: decodeBody(patched, at: anchor.virtualAddress)))")

        let written = Data(data[anchor.fileOffset ..< anchor.fileOffset + patched.count])
        guard written == patched else {
            throw PatcherError.patchVerificationFailed(
                "\(method): site at 0x\(hex(UInt64(anchor.fileOffset))) reads \(written.hex) after write",
            )
        }

        var rehashes: [CustomFirmwareSlotRehash] = []
        if resign {
            rehashes = try CustomFirmwareMachOCodeSignature.reattest(
                &data,
                modifiedOffsets: touchedOffsets(anchor, patched),
            )
            log?("  [.] re-attested \(rehashes.count) slot(s): "
                + rehashes.map(\.description).joined(separator: ", "))
            let unsupported = CustomFirmwareMachOCodeSignature.unsupportedCodeDirectories(in: data)
            if !unsupported.isEmpty {
                log?("      [-] \(unsupported.count) non-SHA256 CodeDirectory(ies) left alone")
            }
        }

        log?("  [+] Patched at 0x\(hex(UInt64(anchor.fileOffset))): mov x0, #1; ret")
        return try Report(
            outcome: .patched,
            anchor: anchor,
            record: PatchRecord(
                patchID: patchID,
                component: component,
                fileOffset: anchor.fileOffset,
                virtualAddress: anchor.virtualAddress,
                originalBytes: original,
                patchedBytes: patched,
                beforeDisasm: text(of: body),
                afterDisasm: text(of: decodeBody(patched, at: anchor.virtualAddress)),
                description: "\(method) -> mov x0, #1; ret",
            ),
            slotRehashes: rehashes,
        )
    }

    // MARK: - Replacement

    /// `mov x0, #1 ; ret`, assembled rather than written down.
    ///
    /// The MOVZ comes out of ``ARM64Encoder``, whose every encoder is asserted
    /// against keystone; `ret` has no operands to encode, so it is the shared
    /// keystone-generated constant — the same split the Python makes between
    /// `asm("mov x0, #1")` and its `RET`.
    static func replacementBytes() throws -> Data {
        guard let mov = ARM64Encoder.encodeMovzX(rd: 0, imm16: 1) else {
            throw PatcherError.invalidFormat("could not encode `mov x0, #1`")
        }
        return mov + ARM64.ret
    }

    /// The file offsets whose pages need re-hashing. Both words are listed, not
    /// just the first: a getter whose second instruction begins a new 4 KiB page
    /// dirties two slots, and hashing only the first would leave the tail slot
    /// stale — a SIGKILL the first time that page is demand-paged in.
    static func touchedOffsets(_ anchor: Anchor, _ patched: Data) -> [Int] {
        stride(from: anchor.fileOffset, to: anchor.fileOffset + patched.count, by: 4).map(\.self)
    }

    // MARK: - Body Shape

    /// Decode the eight bytes the patch replaces.
    static func decodeBody(_ bytes: Data, at va: UInt64) throws -> [Instruction] {
        let decoded = ARM64Disassembler().disassemble(bytes, at: va, count: 2)
        guard decoded.count == 2, decoded.allSatisfy({ $0.id != 0 }) else {
            throw PatcherError.invalidFormat(
                "\(method): the eight bytes at 0x\(hex(va)) (\(bytes.hex)) are not two "
                    + "decodable instructions",
            )
        }
        return decoded
    }

    /// Whether the decoded body is something this patch may overwrite.
    ///
    /// The method is a synthesised BOOL getter, so the shape to expect is a
    /// single-register load followed by `ret`. The check is deliberately on the
    /// *return* — a two-word body ending in `ret`, or a first instruction that
    /// is a plain function entry — rather than on `ldrb` specifically: a future
    /// build may spell the getter differently, but overwriting eight bytes that
    /// are *not* a function's first two words would land mid-function.
    static func isPlausibleGetterBody(_ body: [Instruction]) -> Bool {
        guard body.count == 2 else { return false }
        // A getter: `ldr…/mov… ; ret`.
        if body[1].mnemonic == "ret" || body[1].mnemonic.hasPrefix("reta") {
            return true
        }
        // A real function: a recognisable prologue in the first word, so the
        // eight bytes are the head of a function and an early return is safe.
        let prologue: Set = ["pacibsp", "paciasp", "stp", "sub"]
        return prologue.contains(body[0].mnemonic)
    }

    // MARK: - Helpers

    static func text(of instructions: [Instruction]) -> String {
        instructions
            .map { $0.operandString.isEmpty ? $0.mnemonic : "\($0.mnemonic) \($0.operandString)" }
            .joined(separator: "; ")
    }

    /// Read a NUL-terminated ASCII string, refusing to run past `limit`.
    static func cString(in data: Data, at offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < min(limit, data.count) else { return nil }
        var end = offset
        let stop = min(limit, data.count)
        while end < stop, data[end] != 0 {
            end += 1
        }
        return String(data: data[offset ..< end], encoding: .ascii)
    }

    static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }
}
