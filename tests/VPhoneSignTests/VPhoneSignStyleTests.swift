import Foundation
import Testing
@testable import VPhoneSign

/// The Apple-shaped ad-hoc signature, the escape hatch, and what happens to a
/// file that is not a Mach-O.
@Suite("Signature styles and failure")
struct VPhoneSignStyleTests {
    /// `codesign --verify` rejects ldid's ad-hoc output — no ad-hoc flag, no
    /// CMS blob — and rejects this signer's `.ldid` output for the same two
    /// reasons, which is the point. `.appleAdHoc` is the shape it accepts,
    /// kept for anything that has to satisfy the host rather than the guest.
    @Test("the Apple ad-hoc style passes codesign --verify")
    func appleAdHocVerifies() throws {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        for source in VPhoneSignLdidHarness.corpus {
            let directory = try VPhoneSignLdidHarness.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent
            let file = try VPhoneSignLdidHarness.copy(source, into: directory, as: name)
            try VPhoneSigner.sign(fileAt: file, options: .init(identifier: name, style: .appleAdHoc))

            let result = try VPhoneSignLdidHarness.run(codesign, ["--verify", "-vvv", file.path])
            #expect(result.status == 0, "\(name): \(result.error)")
            #expect(result.error.contains("valid on disk"), "\(name): \(result.error)")
        }
    }

    @Test("the Apple ad-hoc style sets the flag and writes the empty wrapper")
    func appleAdHocShape() throws {
        let source = try #require(VPhoneSignLdidHarness.corpus.first)
        let directory = try VPhoneSignLdidHarness.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try VPhoneSignLdidHarness.copy(source, into: directory, as: "binary")
        try VPhoneSigner.sign(fileAt: file, options: .init(identifier: "binary", style: .appleAdHoc))

        for slice in try VPhoneSignBlobs(fileAt: file).slices {
            let directoryBlob = try #require(slice[0])
            // CodeDirectory.flags is the fourth big-endian word
            let flags = UInt32(bigEndian: directoryBlob.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            })
            #expect(flags == 0x2, "the ad-hoc flag is not set")
            #expect(slice[0x10000]?.count == 8, "the empty CMS wrapper is missing")
            #expect(slice[2]?.count == 12, "the requirements blob is not empty")
            #expect(slice[0x1000] == nil, "an Apple ad-hoc signature has one CodeDirectory")
        }
    }

    // MARK: - Refusing rather than corrupting

    @Test("a file that is not a Mach-O is refused")
    func refusesSomethingElse() throws {
        let directory = try VPhoneSignLdidHarness.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("script.sh")
        try Data("#!/bin/sh\necho hello\n".utf8).write(to: file)
        #expect(throws: VPhoneSignError.self) {
            try VPhoneSigner.sign(fileAt: file, options: .init(identifier: "script.sh"))
        }
        // and it is still the file it was
        #expect(try Data(contentsOf: file) == Data("#!/bin/sh\necho hello\n".utf8))
    }

    @Test("a truncated Mach-O is refused rather than signed over garbage")
    func refusesATruncatedMachO() throws {
        let source = try #require(VPhoneSignLdidHarness.corpus.first { $0.path.hasPrefix("/bin") })
        let whole = try Data(contentsOf: source)
        #expect(throws: VPhoneSignError.self) {
            _ = try VPhoneSigner.sign(whole.prefix(whole.count / 3), options: .init(identifier: "x"))
        }
    }

    /// A Java class file opens with the four bytes of a fat Mach-O. Reading
    /// the next two as an architecture count is how a signer ends up writing
    /// over something it does not understand.
    @Test("something that only starts like a fat Mach-O is refused")
    func refusesAJavaClass() throws {
        var file = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41])
        file.append(Data(count: 512))
        #expect(throws: VPhoneSignError.self) {
            _ = try VPhoneSigner.sign(file, options: .init(identifier: "x"))
        }
    }

    /// `sign(_:options:)` takes any `Data`, and a slice of one keeps its
    /// parent's indices. Every offset in the signer counts from the start of
    /// the file, so a slice that starts anywhere else has to be handled
    /// before the first byte is read.
    @Test("a Data slice that does not start at zero signs the same as a copy")
    func signsANonZeroBasedSlice() throws {
        let source = try #require(VPhoneSignLdidHarness.corpus.first)
        let whole = try Data(contentsOf: source)
        let padded = Data(count: 7) + whole
        let slice = padded[7...]
        #expect(slice.startIndex == 7, "the slice was rebased, so this proves nothing")
        let fromSlice = try VPhoneSigner.sign(slice, options: .init(identifier: "x"))
        let fromCopy = try VPhoneSigner.sign(whole, options: .init(identifier: "x"))
        #expect(fromSlice == fromCopy)
    }

    /// Signing a read-only file is the normal case, not the exception:
    /// everything unpacked out of an IPSW is mode 444, and the whole CFW
    /// pipeline signs those in place.
    @Test("a read-only file is signed and keeps its mode")
    func signsAReadOnlyFile() throws {
        let source = try #require(VPhoneSignLdidHarness.corpus.first)
        let directory = try VPhoneSignLdidHarness.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try VPhoneSignLdidHarness.copy(source, into: directory, as: "binary")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)

        try VPhoneSigner.sign(fileAt: file, options: .init(identifier: "binary"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o444)
        #expect(try VPhoneSignBlobs(fileAt: file).slices.allSatisfy { $0[0] != nil })
        // nothing left beside it
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left == ["binary"], "a temporary was left behind: \(left)")
    }
}
