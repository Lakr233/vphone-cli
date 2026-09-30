// VPhoneExamplePatchSet.swift — The template a `.vphonepatchset` is copied from.
//
// This builds `VPhonePatchSetExample.vphonepatchset`. It is not staged into
// VPhone.bundle and no shipped preset names it: it exists so the loader has
// something real to load in the tests, and so an author has a working set to copy
// rather than a description of one.
//
// Three pieces, and that is the whole contract:
//
//   1. `Contents/Resources/Manifest.plist` — what the set declares. Read before any
//      of this code is mapped.
//   2. A ``VPhonePatchSetPrincipal`` subclass, handed to the loader by the one
//      exported symbol `vphone_patch_set_principal`.
//   3. A ``BufferedPatcher`` per component the manifest declares a patch for.
//      Anything else the pipeline cannot read bytes back from.
//
// What the example patch does: rewrite one ASCII string in iBEC, in place, to a
// replacement of the same length or shorter. A string rewrite is the simplest whole
// class of firmware patch — it is how the serial labels in the bundled boot-chain
// set work — and it needs no instruction encoding, so the shape stays visible.
//
// Both strings come from the preset's `Parameters`, so the set patches nothing
// until a preset says what to rewrite. To make this a real patch instead of a
// template, delete the parameter lookup, hardcode your anchor, and follow it to the
// site you actually want: `ARM64Disassembler` decodes, `ARM64Encoder` and the
// `ARM64` constants produce replacement instructions, and `BinaryBuffer` holds the
// bytes. Never write an instruction word as a literal — see the kernel patcher
// guardrails in AGENTS.md.

import Foundation
import VPhonePatchKit

// MARK: - Entry Point

/// The one symbol the loader looks for — the name is
/// ``vphonePatchSetPrincipalSymbol``. Copy this function verbatim into a new set and
/// change only the class it builds.
@_cdecl("vphone_patch_set_principal")
public func makeExamplePatchSetPrincipal() -> UnsafeMutableRawPointer {
    VPhonePatchSetPrincipal.export(VPhoneExamplePatchSet())
}

// MARK: - Principal

/// What the exported symbol hands back.
///
/// No initializer is declared, so `init()` is inherited — which is what the factory
/// above calls.
public final class VPhoneExamplePatchSet: VPhonePatchSetPrincipal {
    /// The preset parameter naming the string to find.
    public static let findParameter = "ExampleFindString"
    /// The preset parameter naming what to put there.
    public static let replaceParameter = "ExampleReplaceString"

    override public func makePatcher(
        for component: VPhoneFirmwareComponent,
        data: Data,
        context: VPhonePatchSetContext,
    ) throws -> any BufferedPatcher {
        // One component, one patcher. A set declaring patches for several
        // components switches here and returns a different patcher for each.
        guard component == .iBEC else {
            // The default implementation raises the right error: the manifest
            // promised a patch for a component this code does not handle.
            return try super.makePatcher(for: component, data: data, context: context)
        }
        return VPhoneExampleStringPatcher(
            data: data,
            find: context.parameters[Self.findParameter] ?? "",
            replace: context.parameters[Self.replaceParameter] ?? "",
            verbose: context.verbose,
            gate: context.gate,
        )
    }
}

// MARK: - Patcher

/// Rewrites one NUL-terminated ASCII string in place.
///
/// In place matters: growing a string would move everything after it, and nothing
/// in a signed boot-chain image tolerates that. The replacement is therefore
/// padded with NULs to the original's length and refused if it is longer.
public final class VPhoneExampleStringPatcher: BufferedPatcher {
    /// The record identifier, and the identifier the manifest declares. Keeping
    /// them equal is what lets the gate turn this patch off: the gate resolves a
    /// record to the declaration covering it, and a record no declaration covers
    /// applies anyway, with a warning.
    public static let patchIdentifier = "ibec-exp-string_rewrite"

    public let component = VPhoneFirmwareComponent.iBEC.rawValue
    public let verbose: Bool
    public let gate: VPhonePatchGate

    public let buffer: BinaryBuffer
    public var patchedData: Data {
        buffer.data
    }

    private let find: String
    private let replace: String
    private var found: [PatchRecord] = []

    public init(data: Data, find: String, replace: String, verbose: Bool, gate: VPhonePatchGate) {
        buffer = BinaryBuffer(data)
        self.find = find
        self.replace = replace
        self.verbose = verbose
        self.gate = gate
    }

    // MARK: Find

    public func findAll() throws -> [PatchRecord] {
        found = []

        // The gate is asked before the site is even looked for, which is the rule
        // every patcher here follows: consulting it after the write would leave the
        // bytes patched with nothing recording it.
        guard gateAllows(Self.patchIdentifier) else { return [] }

        guard !find.isEmpty else {
            log("  [=] \(Self.patchIdentifier): no \(VPhoneExamplePatchSet.findParameter) in the preset")
            return []
        }
        guard let anchor = find.data(using: .ascii), let replacement = replace.data(using: .ascii) else {
            throw PatcherError.invalidFormat(
                "\(Self.patchIdentifier): both strings must be ASCII",
            )
        }
        guard replacement.count <= anchor.count else {
            throw PatcherError.invalidFormat(
                "\(Self.patchIdentifier): '\(replace)' is longer than '\(find)';"
                    + " a string is rewritten in place and cannot grow",
            )
        }

        for offset in buffer.findAll(anchor) {
            var bytes = replacement
            bytes.append(Data(repeating: 0, count: anchor.count - replacement.count))
            found.append(PatchRecord(
                patchID: Self.patchIdentifier,
                component: component,
                fileOffset: offset,
                originalBytes: buffer.readBytes(at: offset, count: anchor.count),
                patchedBytes: bytes,
                description: "Rewrite '\(find)' as '\(replace)'",
            ))
        }
        if found.isEmpty {
            log("  [=] \(Self.patchIdentifier): '\(find)' is not in this iBEC")
        }
        return found
    }

    // MARK: Apply

    @discardableResult
    public func apply() throws -> Int {
        if found.isEmpty {
            _ = try findAll()
        }
        for record in found {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
            log("  [+] \(record)")
        }
        return found.count
    }
}
