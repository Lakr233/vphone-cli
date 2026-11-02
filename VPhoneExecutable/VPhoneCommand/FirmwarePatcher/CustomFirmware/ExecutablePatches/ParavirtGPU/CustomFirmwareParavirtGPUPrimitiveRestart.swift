// CustomFirmwareParavirtGPUPrimitiveRestart.swift — stop sending the primitive
// restart override the host refuses.
//
// What goes wrong. AppleMetalGLRenderer, OpenGL ES over Metal, calls
// `-[MTLRenderCommandEncoder setPrimitiveRestartEnabled:index:]` before its
// draws, with the restart index itself as `index`: `NO, 0xffffffff` for an
// OpenGL ES 2 context. The guest driver serialises that as command 0x91, eight
// bytes of (enabled, index):
//
//     mov  w2, #0x8 ; mov w3, #0x91
//     bl   objc_msgSend$getCommandBytesRetry:forCommand:
//     stp  w20, w19, [x0]
//
// The host's ParavirtualizedGraphicsGPUTask checks that `index` against
// `[device maxViewportCount]` before replaying it, throws "Invalid viewport
// index" for anything above 15, and fails the whole command buffer. The guest
// sees `kIOGPUCommandBufferCallbackErrorHang` and a GPU restart, and nothing the
// command buffer drew reaches the framebuffer. `Research/Guest/gpu_acceleration.md`
// ("OpenGL ES") has the evidence.
//
// The patch. The serialiser method returns at its first instruction, so the
// command is never sent and the host encoder keeps Metal's own behaviour:
// primitive restart on, at the index type's largest value, which is what
// OpenGL ES 3 asks for with its fixed restart index. An OpenGL ES 2 strip that
// really draws vertex 65535 would be cut there; nothing else changes.
//
// Finding the site. The `mov w2, #0x8 ; mov w3, #0x91` pair is unique in
// `__TEXT,__text`: it names the command. The method's `pacibsp` is the nearest
// one before it, within a few instructions and with no return between. A
// method that already starts with `ret` is this patch's own output and is left
// alone. A driver laid out otherwise is refused unchanged.

import Foundation
import VPhonePatchKit

public enum CustomFirmwareParavirtGPUPrimitiveRestart {
    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }

    static let method = "-[PGSerializerRenderCommandEncoder setPrimitiveRestartEnabled:index:]"
    static let commandSize: UInt32 = 0x08
    static let command: UInt32 = 0x91
    /// How far before the command setup the method may start.
    static let maximumPrologue = 16

    public enum State: Sendable, Equatable {
        case patched
        case alreadyPatched
    }

    public struct Report: Sendable, Equatable {
        /// File offset of the method's first instruction.
        public let fileOffset: Int
        public let state: State
    }

    /// Patch the driver binary at `url` in place. The file is rewritten only
    /// when the method changes.
    @discardableResult
    public static func patch(
        fileAt url: URL,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let report = try patch(&data, log: log)
        if report.state == .patched {
            try data.write(to: url)
        }
        return report
    }

    /// In-memory form. `data` is left untouched unless the site resolves.
    @discardableResult
    public static func patch(
        _ data: inout Data,
        log: ((String) -> Void)? = stdoutLog,
    ) throws -> Report {
        if data.startIndex != 0 {
            data = Data(data)
        }
        let report = try resolve(in: data)
        switch report.state {
        case .patched:
            data.replaceSubrange(report.fileOffset ..< report.fileOffset + 4, with: ARM64.ret)
            log?("  [+] 0x\(hex(report.fileOffset)): \(method) — pacibsp -> ret, command 0x\(hex(command)) no longer sent")
        case .alreadyPatched:
            log?("  [·] 0x\(hex(report.fileOffset)): \(method) — already returns at entry")
        }
        return report
    }

    /// Resolve the method's first instruction, or throw without having changed anything.
    public static func resolve(in data: Data) throws -> Report {
        let sections = MachOParser.parseSections(from: data)
        guard let text = sections["__TEXT,__text"] else {
            throw PatcherError.invalidFormat("not a 64-bit Mach-O with a __TEXT,__text section")
        }
        let start = Int(text.fileOffset)
        let end = start + Int(text.size)
        guard start >= 0, end <= data.count, start < end else {
            throw PatcherError.invalidFormat("__TEXT,__text lies outside the file")
        }
        let setup = CustomFirmwareParavirtGPUIndexOffset.setup(size: commandSize, command: command)
        let setups = CustomFirmwareParavirtGPUIndexOffset.offsets(of: setup, in: data, range: start ..< end)
        guard setups.count == 1, let setupOffset = setups.first else {
            throw PatcherError.patchSiteNotFound(
                "\(method) — expected one command 0x\(hex(command)) setup in __text, found \(setups.count); this is not the cloudOS 26.4 (23E5207q) driver",
            )
        }
        let pacibsp = ARM64.pacibsp.loadLE(UInt32.self, at: 0)
        let ret = ARM64.ret.loadLE(UInt32.self, at: 0)
        let returns: Set<UInt32> = [ret, ARM64.retab.loadLE(UInt32.self, at: 0), ARM64.retaa.loadLE(UInt32.self, at: 0)]
        for distance in 1 ... maximumPrologue {
            let offset = setupOffset - 4 * distance
            guard offset >= start else { break }
            let word = data.loadLE(UInt32.self, at: offset)
            if word == pacibsp {
                return Report(fileOffset: offset, state: .patched)
            }
            if word == ret, offset == start || returnsBefore(offset, in: data, start: start, returns: returns) {
                return Report(fileOffset: offset, state: .alreadyPatched)
            }
            if returns.contains(word) {
                break
            }
        }
        throw PatcherError.patchSiteNotFound(
            "\(method) — no pacibsp within \(maximumPrologue) instructions before the command 0x\(hex(command)) setup at 0x\(hex(setupOffset))",
        )
    }

    /// True when the word before `offset` ends a function, so `offset` starts one.
    static func returnsBefore(_ offset: Int, in data: Data, start: Int, returns: Set<UInt32>) -> Bool {
        offset - 4 >= start && returns.contains(data.loadLE(UInt32.self, at: offset - 4))
            || branchBefore(offset, in: data, start: start)
    }

    /// True when the word before `offset` is an unconditional `b`, the tail of
    /// the previous method.
    static func branchBefore(_ offset: Int, in data: Data, start: Int) -> Bool {
        offset - 4 >= start
            && CustomFirmwareParavirtGPUIndexOffset.branchDisplacement(data.loadLE(UInt32.self, at: offset - 4)) != nil
    }

    static func hex(_ value: some BinaryInteger) -> String {
        String(value, radix: 16)
    }
}
