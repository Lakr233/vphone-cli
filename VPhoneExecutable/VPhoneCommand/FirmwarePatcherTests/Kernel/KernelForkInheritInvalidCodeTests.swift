// KernelForkInheritInvalidCodeTests.swift — the Frida fork patch's declaration,
// gating and, given a real kernelcache, its emitted records.
//
// The kernel half runs only when a raw (decompressed) vphone600 kernelcache is
// at $VPHONE_KERNEL_RAW, or at the tvOS research path the TPRO-pagers test
// uses; without one it returns early, as the other reference-kernel tests do.

@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

struct KernelForkInheritInvalidCodeTests {
    static let identifier = "kernel-exp-frida_fork_inherit_invalid_code"

    @Test func `The patch is a Frida declaration gated on Apple's debugger entitlement`() throws {
        let declaration = try #require(
            FirmwareKernelFridaPatchSet.manifest.patches.first { $0.identifier == Self.identifier },
        )
        #expect(declaration.target == .firmware(.kernelcache))
        #expect(!declaration.bootEssential)
        #expect(KernelCustomFirmwarePatcher.forkInheritInvalidCodeEntitlement == "com.apple.private.cs.debugger")
        #expect(declaration.summary.contains(KernelCustomFirmwarePatcher.forkInheritInvalidCodeEntitlement))
    }

    @Test func `Standard leaves it off and experimental turns it on from cloudOS 26.4`() throws {
        #expect(FirmwarePatchSetCatalog.manualOnlyPatches.contains(Self.identifier))
        for (cloud, expected) in [("26.1", false), ("26.4", true)] {
            let experimental = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.experimentalPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion("27.0.1"),
                cloudOS: VPhoneVersion(cloud),
            )
            #expect(experimental.isEnabled(Self.identifier) == expected)
        }
        let standard = try VPhonePatchPlan.resolve(
            preset: FirmwarePatchSetCatalog.standardPreset,
            patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("27.0.1"),
            cloudOS: VPhoneVersion("26.4"),
        )
        #expect(!standard.isEnabled(Self.identifier))
    }

    @Test func `On a real kernel it emits one hook and one intact cave`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            ProcessInfo.processInfo.environment["VPHONE_KERNEL_RAW"].map { URL(fileURLWithPath: $0) },
            root.appendingPathComponent(".build/tvos-research/kernel-dec/kernelcache.research.vphone600.decompressed"),
        ].compactMap(\.self)
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }

        let data = try Data(contentsOf: url)
        let patcher = KernelCustomFirmwarePatcher(data: data, verbose: false)
        patcher.parseMachO()
        patcher.buildADRPIndex()
        patcher.buildBLIndex()
        #expect(patcher.patchForkInheritInvalidCode())

        let records = patcher.patches.filter { $0.patchID.hasPrefix(Self.identifier) }
        #expect(records.map(\.patchID).sorted() == [Self.identifier + ".cave", Self.identifier + ".hook"])
        let cave = try #require(records.first { $0.patchID.hasSuffix(".cave") })
        let hook = try #require(records.first { $0.patchID.hasSuffix(".hook") })

        // The hook is a BL to the cave, replacing a BL.
        #expect(ARM64Inst.isBL(hook.originalBytes.loadLE(UInt32.self, at: 0)))
        let target = ARM64Encoder.decodeBranchTarget(insn: hook.patchedBytes.loadLE(UInt32.self, at: 0), pc: UInt64(hook.fileOffset))
        #expect(target == UInt64(cave.fileOffset))

        // The cave carries the NUL-terminated key, and no word of it looks like
        // free space to a later findCodeCave (which would overwrite it).
        let key = Data(KernelCustomFirmwarePatcher.forkInheritInvalidCodeEntitlement.utf8) + Data([0])
        #expect(cave.patchedBytes.range(of: key) != nil)
        for i in stride(from: 0, to: cave.patchedBytes.count, by: 4) {
            let word = cave.patchedBytes.loadLE(UInt32.self, at: i)
            #expect(word != 0 && word != 0xFFFF_FFFF && word != 0xD420_0000)
        }
        #expect(patcher.buffer.data.subdata(in: cave.fileOffset ..< cave.fileOffset + cave.patchedBytes.count) == cave.patchedBytes)
    }
}
