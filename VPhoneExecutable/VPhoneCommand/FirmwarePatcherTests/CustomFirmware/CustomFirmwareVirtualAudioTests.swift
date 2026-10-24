// CustomFirmwareVirtualAudioTests.swift — the no-default-VAD throw's anchor.

// The parity bar the other patcher suites hold — same bytes as a frozen
// reference on a pristine binary — needs `ipsws/ref_extract` fixtures this
// machine does not carry, so what is tested here is everything around that:
// the anchor refuses binaries that are not the shape it was told about, and
// the exception-size check is exactly the guard the patcher applies. The
// located-and-patched behaviour on both real builds (iPadOS 26.6.2 and
// iOS 27.0) was verified by hand while the patcher was written and is
// recorded in `Research/Guest/virtio_sound.md` — that covers the mute-set
// patch this suite's second half names. The arm64e.x1 frame forms
// (iOS 27.1, iPhone19,4) are tested below on words read off that build.

@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("CustomFirmwareVirtualAudio")
struct CustomFirmwareVirtualAudioTests {
    /// Not a Mach-O at all.
    static let junk = Data(repeating: 0x41, count: 4096)

    @Test(
        arguments: [Self.junk, Data()],
    )
    func `a binary without the message is refused, not searched past`(_ input: Data) throws {
        var data = input
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudio.patch(
                &data,
                reattest: false,
                dryRun: true,
                log: nil,
            )
        }
    }

    @Test
    func `the message string is the anchor the records name`() {
        #expect(CustomFirmwareVirtualAudio.message == "No default VAD present")
        #expect(CustomFirmwareVirtualAudio.patchID == "system-virtualaudio-cfw-speaker_route_throws")
    }

    @Test(
        arguments: [Self.junk, Data()],
    )
    func `a binary without the mute-set log is refused, not searched past`(_ input: Data) throws {
        var data = input
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudio.patchMuteSet(
                &data,
                reattest: false,
                dryRun: true,
                log: nil,
            )
        }
    }

    @Test
    func `the mute-set anchor strings and record identity are stable`() {
        #expect(CustomFirmwareVirtualAudio.muteSetMessage == "Set mute value of %u on HAL device")
        #expect(CustomFirmwareVirtualAudio.muteSetException == "Unable to set property data.")
        #expect(CustomFirmwareVirtualAudio.muteSetPatchID == "system-virtualaudio-cfw-mute_set_throw")
    }

    @Test(
        arguments: [Self.junk, Data()],
    )
    func `a binary without the decline log is refused, not searched past`(_ input: Data) throws {
        var data = input
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudio.patchSpeakerProtectionGate(
                &data,
                reattest: false,
                dryRun: true,
                log: nil,
            )
        }
    }

    @Test
    func `the SP-gate anchor strings and record identity are stable`() {
        #expect(CustomFirmwareVirtualAudio.spGateMessage == "HAL Speaker Protection is missing. Failing route")
        #expect(CustomFirmwareVirtualAudio.spGateFile == "RoutingHandler_Playback_GenericConfig1.cpp")
        #expect(CustomFirmwareVirtualAudio.spGatePatchID == "system-virtualaudio-cfw-speaker_protection_gate")
    }

    @Test
    func `each SP-gate handler has its own file anchor and a record the declaration covers`() {
        typealias Handler = CustomFirmwareVirtualAudio.SPGateHandler
        #expect(Handler.allCases == [.playback, .playbackAndRecord])
        #expect(Handler.playback.file == CustomFirmwareVirtualAudio.spGateFile)
        #expect(Handler.playback.patchID == CustomFirmwareVirtualAudio.spGatePatchID)
        #expect(Handler.playbackAndRecord.file == "RoutingHandler_PlaybackAndRecord_GenericConfig1.cpp")
        // A site of the same declaration: only a dot starts one.
        #expect(Handler.playbackAndRecord.patchID
            == "system-virtualaudio-cfw-speaker_protection_gate.playback_and_record")
        // Neither file name may be found inside the other, or one handler's
        // anchor would qualify both.
        #expect(!Handler.playbackAndRecord.file.contains(Handler.playback.file))
        #expect(!Handler.playback.file.contains(Handler.playbackAndRecord.file))
    }

    @Test(
        arguments: [Self.junk, Data()],
    )
    func `a binary without the play-and-record decline is refused, not searched past`(_ input: Data) throws {
        var data = input
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudio.patchSpeakerProtectionGate(
                &data,
                handler: .playbackAndRecord,
                reattest: false,
                dryRun: true,
                log: nil,
            )
        }
    }

    @Test(
        arguments: [Self.junk, Data()],
    )
    func `a binary without the precondition decline is refused, not searched past`(_ input: Data) throws {
        var data = input
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudio.patchVolumeModePrecondition(
                &data,
                reattest: false,
                dryRun: true,
                log: nil,
            )
        }
    }

    @Test
    func `the volume-gate anchor strings and record identity are stable`() {
        #expect(CustomFirmwareVirtualAudio.volumePreconditionFormat == "PRECONDITION FAILURE (std::logic_error)")
        #expect(CustomFirmwareVirtualAudio.volumeModePackingMask == 0x1_FFFF_FFFF)
        #expect(CustomFirmwareVirtualAudio.volumeGatePatchID == "system-virtualaudio-cfw-volume_mode_precondition")
    }

    /// `tbz w21, #0, 0x136878` at 0x136620 — the real gate branch, read off
    /// the iPadOS 26.6.2 plugin binary this patch was written against (bytes
    /// d5 12 00 36 at that offset).
    @Test
    func `the conditional-branch decoder reads the real gate's target`() {
        #expect(
            CustomFirmwareVirtualAudio.decodeConditionalBranchTarget(
                insn: 0x3600_12D5,
                pc: 0x136620,
            ) == 0x136878,
        )
    }

    /// The 19-bit immediate must sign-extend, or a backward branch decodes
    /// up to 512 KB ahead instead of up to 256 KB back. The word is built
    /// from its fields — `b.eq` with every immediate bit set, i.e. −1 — not
    /// taken as a literal.
    @Test
    func `the 19-bit immediate sign-extends`() {
        let word: UInt32 = 0x5400_0000 | (0x7FFFF << 5) // b.eq, imm19 = −1
        #expect(
            CustomFirmwareVirtualAudio.decodeConditionalBranchTarget(
                insn: word,
                pc: 0x1000,
            ) == 0x0FFC,
        )
    }

    /// `tbz` reaches ±32 KB through a 14-bit immediate at bits 18-5, and a
    /// 64-bit `cbnz` proves the leading sf/b5 bit is not mistaken for part
    /// of the family. Both words are built from their fields.
    @Test
    func `the 14-bit and 64-bit families decode`() {
        // tbz w21, #0, imm14 = −1 (bits 30-25 = 011011, bit 24 = 0)
        let tbz: UInt32 = 0x3600_0000 | (0x3FFF << 5) | 21
        #expect(CustomFirmwareVirtualAudio.decodeConditionalBranchTarget(insn: tbz, pc: 0x1000) == 0x0FFC)
        // cbnz xzr, +0x40 (sf = 1, bit 24 = 1): top byte 1_011010_1
        let cbnz: UInt32 = 0xB500_0000 | (0x10 << 5) | 31
        #expect(CustomFirmwareVirtualAudio.decodeConditionalBranchTarget(insn: cbnz, pc: 0x2000) == 0x2040)
    }

    @Test
    func `the conditional-branch decoder refuses words outside its families`() {
        #expect(CustomFirmwareVirtualAudio.decodeConditionalBranchTarget(insn: 0xD503_201F, pc: 0) == nil)
        // A `b` — the family `ARM64Encoder.decodeBranchTarget` owns.
        #expect(CustomFirmwareVirtualAudio.decodeConditionalBranchTarget(insn: 0x1400_0002, pc: 0) == nil)
        // A PAUTH BC.cond — bit 24 set, a register operand, not an offset.
        #expect(CustomFirmwareVirtualAudio.decodeConditionalBranchTarget(insn: 0x5500_0FE0, pc: 0) == nil)
    }

    // MARK: - arm64e.x1 (FEAT_PAuth_LR) frames

    // iOS 27.1's iPhone19,4 userland is arm64e.x1: functions open with
    // `pacibsppc` and return with `retabsppc <label>`. Every word below was
    // read off that build's VirtualAudio (24A94425) and checked against
    // llvm-objdump, except the fixture returns, which are built from their
    // fields.

    /// `pacibsppc` — the speaker-route walker's prologue at 0x1717bc.
    static let x1Prologue: UInt32 = 0xDAC1_A7FE
    /// `ldp x29, x30, [sp, #0x130]` / `ldp x20, x19, [sp, #0x120]` /
    /// `add sp, sp, #0x140` — the walker's epilogue at 0x172044.
    static let framePop: UInt32 = 0xA953_7BFD
    static let calleePop: UInt32 = 0xA952_4FF4
    static let stackRelease: UInt32 = 0x9105_03FF
    /// `b 0x172198` — the no-default-VAD throw's terminator at 0x171cd0.
    static let terminator: UInt32 = 0x1400_0132

    /// RETABSPPC <label>: the label is `imm16` words back from the return.
    static func retabsppc(back words: UInt32) -> UInt32 {
        0x5520_001F | (words & 0xFFFF) << 5
    }

    static func instruction(_ word: UInt32, at offset: Int = 0) -> ARM64Instruction? {
        ARM64Disassembler().disassembleOne(in: ARM64.encodeU32(word), at: 0, address: UInt64(offset))
    }

    /// A walker tail: prologue, the throw's terminator, the pops, the
    /// return. The epilogue's entry is the frame-pair pop at 0xC.
    static func walkerTail(prologue: Data, return ret: Data) -> Data {
        var data = prologue + ARM64.nop
        data += ARM64.encodeU32(terminator)
        data += ARM64.encodeU32(framePop) + ARM64.encodeU32(calleePop) + ARM64.encodeU32(stackRelease)
        return data + ret
    }

    @Test
    func `both signing prologues and both B-key returns are recognised, a plain ret is not`() {
        #expect(CustomFirmwareVirtualAudio.isPrologue(Self.instruction(Self.x1Prologue)))
        #expect(CustomFirmwareVirtualAudio.isPrologue(Self.instruction(ARM64.pacibspU32)))
        #expect(!CustomFirmwareVirtualAudio.isPrologue(Self.instruction(ARM64.nopU32)))

        let x1Return = Self.instruction(0x5520_455F, at: 0x172064)
        #expect(x1Return?.mnemonic == "retabsppc")
        #expect(CustomFirmwareVirtualAudio.isAuthenticatedReturn(x1Return))
        #expect(CustomFirmwareVirtualAudio.isAuthenticatedReturn(
            ARM64Disassembler().disassembleOne(ARM64.retab),
        ))
        // `ret` — closes a leaf or an `autibsppc` pair, never these frames.
        #expect(!CustomFirmwareVirtualAudio.isAuthenticatedReturn(Self.instruction(0xD65F_03C0)))
        #expect(CustomFirmwareVirtualAudio.returnMnemonics.contains("ret"))
        #expect(CustomFirmwareVirtualAudio.returnMnemonics.isSuperset(of: CustomFirmwareVirtualAudio.authenticatedReturnMnemonics))
    }

    /// Capstone decodes the label as `#0` whatever the field holds, so the
    /// label is read off the word: the walker's return at 0x172064 names
    /// 0x1717bc, the mute-set wrapper's at 0x110ae4 names 0x110478 — both
    /// the prologues the patcher's own walk found.
    @Test
    func `the retabsppc label is read off the real returns`() throws {
        let walker = try #require(Self.instruction(0x5520_455F, at: 0x172064))
        #expect(CustomFirmwareVirtualAudio.retabsppcLabel(walker, at: 0x172064) == 0x1717BC)
        #expect(CustomFirmwareVirtualAudio.returnCloses(walker, at: 0x172064, prologue: 0x1717BC))
        #expect(!CustomFirmwareVirtualAudio.returnCloses(walker, at: 0x172064, prologue: 0x1725E4))

        let muteSet = try #require(Self.instruction(0x5520_337F, at: 0x110AE4))
        #expect(CustomFirmwareVirtualAudio.retabsppcLabel(muteSet, at: 0x110AE4) == 0x110478)

        // `retab` names no frame: nothing to read, and nothing to refuse.
        let retab = try #require(ARM64Disassembler().disassembleOne(ARM64.retab))
        #expect(CustomFirmwareVirtualAudio.retabsppcLabel(retab, at: 0) == nil)
        #expect(CustomFirmwareVirtualAudio.returnCloses(retab, at: 0x40, prologue: 0))
    }

    @Test
    func `an x1 epilogue ending in retabsppc is found from the throw`() throws {
        let data = Self.walkerTail(prologue: ARM64.encodeU32(Self.x1Prologue), return: ARM64.encodeU32(Self.retabsppc(back: 6)))
        let disasm = ARM64Disassembler()
        #expect(CustomFirmwareVirtualAudio.nearestPrologue(in: data, disasm: disasm, below: 0x14, floor: 0) == 0)
        let entry = try CustomFirmwareVirtualAudio.locateEpilogue(
            in: data, disasm: disasm, after: 0x8, prologue: 0, textEnd: data.count,
        )
        #expect(entry == 0xC)
    }

    @Test
    func `an arm64e epilogue ending in retab is found as before`() throws {
        let data = Self.walkerTail(prologue: ARM64.pacibsp, return: ARM64.retab)
        let disasm = ARM64Disassembler()
        #expect(CustomFirmwareVirtualAudio.nearestPrologue(in: data, disasm: disasm, below: 0x14, floor: 0) == 0)
        let entry = try CustomFirmwareVirtualAudio.locateEpilogue(
            in: data, disasm: disasm, after: 0x8, prologue: 0, textEnd: data.count,
        )
        #expect(entry == 0xC)
    }

    /// A `retabsppc` that authenticates against another frame's signature is
    /// not this function's epilogue, and branching to it would fault — the
    /// search stops and refuses rather than looking further.
    @Test
    func `a retabsppc naming another prologue is refused`() {
        // Five words back from 0x18 is the `nop` at 0x4, not the prologue.
        let data = Self.walkerTail(prologue: ARM64.encodeU32(Self.x1Prologue), return: ARM64.encodeU32(Self.retabsppc(back: 5)))
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudio.locateEpilogue(
                in: data, disasm: ARM64Disassembler(), after: 0x8, prologue: 0, textEnd: data.count,
            )
        }
    }

    // MARK: - Device-state null gate

    @Test(
        arguments: [Self.junk, Data()],
    )
    func `a binary without the singleton diagnostic is refused, not searched past`(_ input: Data) throws {
        var data = input
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudio.patchDeviceStateNullGate(
                &data,
                reattest: false,
                dryRun: true,
                log: nil,
            )
        }
    }

    @Test
    func `the null-gate anchor strings and record identity are stable`() {
        #expect(CustomFirmwareVirtualAudio.deviceStateInstanceMissing == "TheInstance() called before SetInstance()")
        #expect(CustomFirmwareVirtualAudio.deviceStateNullGatePatchID == "system-virtualaudio-cfw-device_state_null_gate")
    }

    /// The arm64e.x1 header word iOS 27.1's plugin carries, and the plain
    /// arm64e one 26.6.2 and 27.0 carry — both read off those builds, LIB64
    /// bit included.
    static let x1Subtype: UInt32 = 0x8000_000C
    static let arm64eSubtype: UInt32 = 0x8000_0002

    @Test
    func `the plugin subtype gate tells the three arm64 worlds apart`() {
        func header(_ subtype: UInt32) -> Data {
            var data = Data()
            for word: UInt32 in [0xFEED_FACF, 0x0100_000C, subtype, 6, 0, 0, 0, 0] {
                withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }
        #expect(CustomFirmwareVirtualAudio.arm64Subtype(of: header(Self.x1Subtype)) == .x1)
        #expect(CustomFirmwareVirtualAudio.arm64Subtype(of: header(Self.arm64eSubtype)) == .other)
        #expect(CustomFirmwareVirtualAudio.arm64Subtype(of: Self.junk) == .notArm64)
        #expect(CustomFirmwareVirtualAudio.arm64Subtype(of: Data()) == .notArm64)
    }

    // A synthetic plugin carrying the guarded device-state shape:
    // TheInstance with its diagnostic reference, two gated updates, and
    // the caller the shape must refuse — the haptic delegate's unguarded
    // deref. Every instruction comes from the encoder or the frozen
    // constants, and the layout is fixed so the addresses are the same in
    // every test.
    //
    //   text+0x00 pacibsppc              TheInstance
    //   text+0x04 adrp x3, <cstring>     the diagnostic's reference
    //   text+0x08 add  x3, x3, #0
    //   text+0x0c retab
    //   text+0x10 bl   stub              gate check, site 1 — the slot the patch rewrites
    //   text+0x14 cbz  w0, +0x20         the branch that tests the answer
    //   text+0x18 bl   TheInstance
    //   text+0x1c mov  x20, x0
    //   text+0x20 ldr  x21, [x0]         the deref that faults
    //   text+0x24-0x2c nops              the rest of the update
    //   text+0x30 …site 2, the same shape…
    //   text+0x54 bl   stub              the haptic caller's release call
    //   text+0x58 bl   TheInstance       unguarded: no gate above it
    //   text+0x5c mov  x20, x0
    //   text+0x60 ldr  x21, [x0]
    //   text+0x64 nop, bl TheInstance    a pass-through caller
    static let deviceStateText = 0x108
    static let deviceStateGateCall1 = 0x118
    static let deviceStateGateCall2 = 0x138

    /// The guarded plugin image. `gatedSites` builds only that many gated
    /// updates (the refusal test wants fewer than two); the mismatching
    /// callers ride along every time.
    static func deviceStateImage(cpuSubtype: UInt32, gatedSites: Int = 2) throws -> Data {
        func word(_ encoded: Data?) throws -> UInt32 {
            guard let encoded, encoded.count == 4 else {
                throw PatcherError.invalidFormat("the test build could not encode an instruction")
            }
            return UInt32(encoded[encoded.startIndex])
                | UInt32(encoded[encoded.startIndex + 1]) << 8
                | UInt32(encoded[encoded.startIndex + 2]) << 16
                | UInt32(encoded[encoded.startIndex + 3]) << 24
        }

        let theInstance = deviceStateText
        let stub = theInstance + 0xC
        func gatedSite(start: Int) throws -> [UInt32] {
            let call = start + 8
            let skip = call + 0x1C
            return [
                try word(ARM64Encoder.encodeBL(from: start, to: stub)),
                try word(ARM64Encoder.encodeCompareBranch(nonzero: false, register: 0, from: start + 4, to: skip)),
                try word(ARM64Encoder.encodeBL(from: call, to: theInstance)),
                try word(ARM64Encoder.encodeMovX(rd: 20, rm: 0)),
                try word(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 21, rn: 0, offset: 0)),
                ARM64.nopU32, ARM64.nopU32, ARM64.nopU32,
            ]
        }

        var code: [UInt32] = [
            Self.x1Prologue,
            try word(ARM64Encoder.encodeADRP(rd: 3, pc: UInt64(theInstance + 4), target: 0x2000)),
            try word(ARM64Encoder.encodeAddImm12(rd: 3, rn: 3, imm12: 0)),
            ARM64.retabU32,
        ]
        for index in 0 ..< gatedSites {
            code += try gatedSite(start: deviceStateText + 0x10 + index * 0x20)
        }
        // The haptic delegate's shape: the same unguarded deref, but the
        // instruction above the call is a release call without a gate
        // branch below it; then a caller that passes the singleton on.
        let haptic = deviceStateText + 0x10 + gatedSites * 0x20
        code += [
            try word(ARM64Encoder.encodeBL(from: haptic, to: stub)),
            try word(ARM64Encoder.encodeBL(from: haptic + 4, to: theInstance)),
            try word(ARM64Encoder.encodeMovX(rd: 20, rm: 0)),
            try word(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 21, rn: 0, offset: 0)),
            ARM64.nopU32,
            try word(ARM64Encoder.encodeBL(from: haptic + 0x14, to: theInstance)),
            ARM64.nopU32, ARM64.nopU32,
        ]
        return pluginImage(
            cpuSubtype: cpuSubtype,
            text: code,
            cstrings: [CustomFirmwareVirtualAudio.deviceStateInstanceMissing],
        )
    }

    /// A thin arm64 plugin image: one __TEXT segment carrying `text` as
    /// __text (address == file offset, like the real plugin) and
    /// `cstrings` in __cstring from 0x2000, each page-aligned.
    static func pluginImage(cpuSubtype: UInt32, text: [UInt32], cstrings: [String]) -> Data {
        let textOffset = 32 + 72 + 2 * 80
        let cstringOffset = textOffset + text.count * 4
        var cstringBytes = [UInt8]()
        for string in cstrings {
            let padding = (0x1000 - cstringBytes.count % 0x1000) % 0x1000
            cstringBytes += Array(repeating: 0, count: padding)
            cstringBytes += Array("\(string)\0".utf8)
        }
        let total = cstringOffset + cstringBytes.count

        func padded(_ name: String) -> [UInt8] {
            Array(name.utf8) + Array(repeating: 0, count: 16 - name.utf8.count)
        }
        func word32(_ value: [UInt32]) -> [UInt8] {
            value.flatMap { withUnsafeBytes(of: $0.littleEndian) { Array($0) } }
        }
        func word64(_ value: [UInt64]) -> [UInt8] {
            value.flatMap { withUnsafeBytes(of: $0.littleEndian) { Array($0) } }
        }

        var command = word32([0x19, 72 + 160])
        command += padded("__TEXT")
        command += word64([0, UInt64(total), 0, UInt64(total)])
        command += word32([0b111, 0b111, 2, 0])
        // __text
        command += padded("__text") + padded("__TEXT")
        command += word64([UInt64(textOffset), UInt64(text.count * 4)])
        command += word32([UInt32(textOffset), 2, 0, 0, 0x8000_0400, 0, 0, 0])
        // __cstring
        command += padded("__cstring") + padded("__TEXT")
        command += word64([0x2000, UInt64(cstringBytes.count)])
        command += word32([UInt32(cstringOffset), 3, 0, 0, 2, 0, 0, 0])

        var image = word32([0xFEED_FACF, 0x0100_000C, cpuSubtype, 6, 1, UInt32(command.count), 0, 0])
        image += command
        image += text.flatMap { withUnsafeBytes(of: $0.littleEndian) { Array($0) } }
        image += cstringBytes
        image += Array(repeating: 0, count: total - image.count)
        return Data(image)
    }

    @Test
    func `the gate calls are redirected to TheInstance, idempotently`() throws {
        var data = try Self.deviceStateImage(cpuSubtype: Self.x1Subtype)
        let pristine = data

        let report = try CustomFirmwareVirtualAudio.patchDeviceStateNullGate(
            &data, reattest: false, dryRun: false, log: nil,
        )
        #expect(report.outcome == .patched)
        #expect(report.records.count == 2)
        #expect(report.records.map(\.patchID) == [
            CustomFirmwareVirtualAudio.deviceStateNullGatePatchID,
            CustomFirmwareVirtualAudio.deviceStateNullGatePatchID,
        ])
        #expect(report.theInstanceVMA == UInt64(Self.deviceStateText))
        #expect(report.sites.map(\.gateCallVMA) == [
            UInt64(Self.deviceStateGateCall1), UInt64(Self.deviceStateGateCall2),
        ])

        // Each gate-check `bl` now calls TheInstance; the branches, the
        // calls and the dereferences below them are untouched.
        let changed = zip(pristine, data).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        let slots = [Self.deviceStateGateCall1, Self.deviceStateGateCall2]
        #expect(!changed.isEmpty)
        #expect(changed.allSatisfy { offset in slots.contains { gate in gate <= offset && offset < gate + 4 } })
        for gate in slots {
            let redirect = try #require(ARM64Encoder.encodeBL(from: gate, to: Self.deviceStateText))
            #expect(Data(data[gate ..< gate + 4]) == redirect)
        }

        // A second run recognises its own redirects and writes nothing.
        let once = data
        let again = try CustomFirmwareVirtualAudio.patchDeviceStateNullGate(
            &data, reattest: false, dryRun: false, log: nil,
        )
        #expect(again.outcome == .alreadyPatched)
        #expect(again.records.isEmpty)
        #expect(data == once)
    }

    @Test
    func `a dry run locates both sites and writes nothing`() throws {
        var data = try Self.deviceStateImage(cpuSubtype: Self.x1Subtype)
        let pristine = data
        let report = try CustomFirmwareVirtualAudio.patchDeviceStateNullGate(
            &data, reattest: false, dryRun: true, log: nil,
        )
        #expect(report.outcome == .wouldPatch)
        #expect(report.records.isEmpty)
        #expect(data == pristine)
        #expect(report.sites.map(\.gateCallVMA) == [
            UInt64(Self.deviceStateGateCall1), UInt64(Self.deviceStateGateCall2),
        ])
    }

    @Test
    func `a plain arm64e plugin is reported and left byte-identical`() throws {
        var data = try Self.deviceStateImage(cpuSubtype: Self.arm64eSubtype)
        let pristine = data
        let report = try CustomFirmwareVirtualAudio.patchDeviceStateNullGate(
            &data, reattest: false, dryRun: false, log: nil,
        )
        #expect(report.outcome == .notArm64EX1)
        #expect(report.records.isEmpty)
        #expect(report.sites.isEmpty)
        #expect(data == pristine)
    }

    @Test
    func `fewer gated updates than the plugin carries are refused, not half-patched`() throws {
        var data = try Self.deviceStateImage(cpuSubtype: Self.x1Subtype, gatedSites: 1)
        let pristine = data
        #expect(throws: PatcherError.self) {
            try CustomFirmwareVirtualAudio.patchDeviceStateNullGate(
                &data, reattest: false, dryRun: false, log: nil,
            )
        }
        #expect(data == pristine)
    }
}
