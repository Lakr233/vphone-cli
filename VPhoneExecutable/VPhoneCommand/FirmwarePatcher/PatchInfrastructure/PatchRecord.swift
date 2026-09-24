// PatchRecord.swift — Per-patch verification record for migration validation.

import Foundation

/// A single patch application record, used to compare Python vs Swift output.
public struct PatchRecord: Codable, Equatable, Sendable {
    /// Unique patch identifier (e.g., "kernel.bsd_init_rootvp").
    public let patchID: String

    /// Component being patched (e.g., "kernelcache", "ibss", "txm").
    public let component: String

    /// File offset where the patch is applied.
    public let fileOffset: Int

    /// Virtual address (if applicable, nil for raw binaries).
    public let virtualAddress: UInt64?

    /// Original bytes before patching.
    public let originalBytes: Data

    /// Replacement bytes after patching.
    public let patchedBytes: Data

    /// Capstone disassembly of original bytes.
    public let beforeDisasm: String

    /// Capstone disassembly of patched bytes.
    public let afterDisasm: String

    /// Human-readable description of what this patch does.
    public let patchDescription: String

    public init(
        patchID: String,
        component: String,
        fileOffset: Int,
        virtualAddress: UInt64? = nil,
        originalBytes: Data,
        patchedBytes: Data,
        beforeDisasm: String = "",
        afterDisasm: String = "",
        description: String,
    ) {
        self.patchID = patchID
        self.component = component
        self.fileOffset = fileOffset
        self.virtualAddress = virtualAddress
        self.originalBytes = originalBytes
        self.patchedBytes = patchedBytes
        self.beforeDisasm = beforeDisasm
        self.afterDisasm = afterDisasm
        patchDescription = description
    }
}

extension PatchRecord: CustomStringConvertible {
    public var description: String {
        let addr = virtualAddress.map { String(format: " (VA 0x%llX)", $0) } ?? ""
        return String(
            format: "  0x%06X%@: %@ → %@  [%@]",
            fileOffset,
            addr,
            beforeDisasm.isEmpty ? originalBytes.hex : beforeDisasm,
            afterDisasm.isEmpty ? patchedBytes.hex : afterDisasm,
            patchID,
        )
    }
}

extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
