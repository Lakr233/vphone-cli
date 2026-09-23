import Foundation
import Testing
@testable import VPhoneSign

/// `-K`: signing with the repository's own `signcert.p12`.
///
/// The whole file cannot match ldid's, because a CMS carries a signing time.
/// It is only the content that differs: the CMS blob comes out the same
/// length as ldid's on every slice measured (4711 against 4711, 4792 against
/// 4792), and the signed files are the same size to the byte, because both
/// signers reserve `cmsReservation` and pad what is left. What must match is
/// the CodeDirectory, and it is the only part that has to: everything AMFI
/// seals is in there, and the CDHash is computed over it. The CMS is then
/// held to a verifier nobody here wrote.
@Suite("VPhoneSign signs with a PKCS#12")
struct VPhoneSignIdentityTests {
    /// The certificate this repository signs its guest daemon with. It is
    /// checked in, wrapped with no password, and expired in 2018 — none of
    /// which matters to a device whose AMFI this project patched, and all of
    /// which matters to how it has to be read.
    static var p12: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/vphoned/signcert.p12")
    }

    private func identity() throws -> VPhoneSignIdentity {
        try #require(FileManager.default.fileExists(atPath: Self.p12.path), "signcert.p12 is not in the tree")
        return try VPhoneSignIdentity(pkcs12: Data(contentsOf: Self.p12), password: "")
    }

    /// `SecPKCS12Import` cannot do this: it answers `errSecAuthFailed` for an
    /// empty password. That is the entire reason the container is opened by
    /// hand.
    @Test("the repository's PKCS#12 opens with no password")
    func opensWithoutAPassword() throws {
        let identity = try identity()
        #expect(identity.teamIdentifier == "DQF6PC5T2P")
        #expect(identity.commonName == "iPhone Distribution: jiu de (DQF6PC5T2P)")
    }

    @Test("a wrong password is refused, not worked around")
    func refusesAWrongPassword() throws {
        try #require(FileManager.default.fileExists(atPath: Self.p12.path))
        let data = try Data(contentsOf: Self.p12)
        #expect(throws: VPhoneSignError.self) {
            _ = try VPhoneSignIdentity(pkcs12: data, password: "not the password")
        }
    }

    /// The hard gate for `-K`: the CodeDirectories are ldid's, byte for byte.
    @Test("every CodeDirectory matches ldid -K")
    func codeDirectoriesMatchLdid() throws {
        let ldid = try #require(VPhoneSignLdidHarness.ldid, "ldid is not installed")
        let identity = try identity()
        for source in VPhoneSignLdidHarness.corpus {
            let directory = try VPhoneSignLdidHarness.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent

            let theirs = try VPhoneSignLdidHarness.copy(source, into: directory, as: name)
            let result = try VPhoneSignLdidHarness.run(ldid, ["-S", "-M", "-K\(Self.p12.path)", theirs.path])
            #expect(result.status == 0, "ldid -K \(name): \(result.error)")

            let ours = try VPhoneSignLdidHarness.copy(source, into: directory, as: "ours-\(name)")
            try VPhoneSigner.sign(fileAt: ours, options: .init(
                identifier: name, mergesExisting: true, identity: identity
            ))

            let left = try VPhoneSignBlobs(fileAt: theirs), right = try VPhoneSignBlobs(fileAt: ours)
            #expect(left.slices.count == right.slices.count, "\(name): different slice counts")
            for (index, pair) in zip(left.slices, right.slices).enumerated() {
                for slot in [UInt32(0), 0x1000] where pair.0[slot] != nil || pair.1[slot] != nil {
                    #expect(
                        pair.0[slot] == pair.1[slot],
                        "\(name) slice \(index) slot 0x\(String(slot, radix: 16)): CodeDirectory differs"
                    )
                }
                // the designated requirement carries the leaf's common name
                // under -K, so it is part of the same claim
                #expect(pair.0[2] == pair.1[2], "\(name) slice \(index): requirements differ")
            }
        }
    }

    /// The seal, checked by `codesign --verify`, which is an action and not
    /// the verbosity flag that `-d -vvv` turns out to be.
    ///
    /// Both signers pass outright, entitlements or not: `codesign --verify`
    /// exits 0 and prints "satisfies its Designated Requirement" for ldid's
    /// output and for this one. An earlier note here said the DR clause fails
    /// for both whenever entitlements are present, because ldid compiles a DR
    /// naming a leaf that expired in 2018. That does not reproduce in any
    /// configuration tried — `--verify` does not build a trust chain, so the
    /// expiry never comes into it — so the run is asserted rather than only
    /// compared against ldid's.
    @Test("codesign --verify accepts the seal, with entitlements and without")
    func codesignVerifiesTheSeal() throws {
        let ldid = try #require(VPhoneSignLdidHarness.ldid, "ldid is not installed")
        let identity = try identity()
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        // the corpus's first files carry no entitlements and
        // `carryingEntitlements` is the half that does, which is the case the
        // old note claimed was different
        // Filter before the prefix, not after. The other order takes the first
        // four names and *then* drops the missing ones, so a machine without
        // one of lsd/sshd/trustd/pkd quietly shrinks the entitlement-carrying
        // half — possibly to nothing — and the test still passes.
        let entitled = VPhoneSignLdidHarness.carryingEntitlements
            .filter { FileManager.default.fileExists(atPath: $0) }
            .prefix(4)
            .map { URL(fileURLWithPath: $0) }
        #expect(entitled.count == 4, "expected four entitlement-carrying binaries, found \(entitled.count)")
        let corpus = VPhoneSignLdidHarness.corpus.prefix(4) + entitled
        for source in corpus {
            let directory = try VPhoneSignLdidHarness.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent

            let theirs = try VPhoneSignLdidHarness.copy(source, into: directory, as: name)
            let seal = try VPhoneSignLdidHarness.run(ldid, ["-S", "-M", "-K\(Self.p12.path)", theirs.path])
            #expect(seal.status == 0, "ldid -S -M -K \(name): \(seal.error)")
            let ours = try VPhoneSignLdidHarness.copy(source, into: directory, as: "ours-\(name)")
            try VPhoneSigner.sign(fileAt: ours, options: .init(
                identifier: name, mergesExisting: true, identity: identity
            ))

            let mine = try VPhoneSignLdidHarness.run(codesign, ["--verify", "--no-strict", "-vvv", ours.path])
            let theirsResult = try VPhoneSignLdidHarness.run(codesign, ["--verify", "--no-strict", "-vvv", theirs.path])
            #expect(theirsResult.status == 0, "ldid's own output: \(theirsResult.error)")
            #expect(mine.status == 0, "\(name): \(mine.error)")
            #expect(mine.error.contains("valid on disk"), "\(name): \(mine.error)")
            #expect(
                mine.error.contains("satisfies its Designated Requirement"),
                "\(name): ours [\(mine.error)] ldid [\(theirsResult.error)]"
            )
        }
    }

    /// The two files are the same size, and their CMS blobs are the same
    /// length; only the bytes inside differ, where the signing time lives.
    ///
    /// This is here because the opposite was written down — that this
    /// signer's CMS runs eight bytes longer than ldid's — and a CMS that
    /// really was longer would be a real problem: the reservation is fixed,
    /// so overflowing it would move the `__LINKEDIT` size in the load
    /// commands and change every CDHash.
    @Test("the CMS is the same length as ldid's, and so is the file")
    func cmsIsTheSameLengthAsLdids() throws {
        let ldid = try #require(VPhoneSignLdidHarness.ldid, "ldid is not installed")
        let identity = try identity()
        for source in VPhoneSignLdidHarness.corpus.prefix(8) {
            let directory = try VPhoneSignLdidHarness.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent

            let theirs = try VPhoneSignLdidHarness.copy(source, into: directory, as: name)
            _ = try VPhoneSignLdidHarness.run(ldid, ["-S", "-M", "-K\(Self.p12.path)", theirs.path])
            let ours = try VPhoneSignLdidHarness.copy(source, into: directory, as: "ours-\(name)")
            try VPhoneSigner.sign(fileAt: ours, options: .init(
                identifier: name, mergesExisting: true, identity: identity
            ))

            #expect(
                try Data(contentsOf: theirs).count == Data(contentsOf: ours).count,
                "\(name): the signed files are different sizes"
            )
            let left = try VPhoneSignBlobs(fileAt: theirs), right = try VPhoneSignBlobs(fileAt: ours)
            for (index, pair) in zip(left.slices, right.slices).enumerated() {
                let mine = try #require(pair.1[0x10000], "\(name) slice \(index) has no CMS")
                let theirs = try #require(pair.0[0x10000], "\(name) slice \(index): ldid wrote no CMS")
                #expect(mine.count == theirs.count, "\(name) slice \(index): \(mine.count) vs \(theirs.count)")
            }
        }
    }

    /// The gate that is real evidence rather than a display: a verifier from
    /// outside this project, over the bytes this project signed. `-noverify`
    /// skips building a trust chain, which would fail on an expired leaf and
    /// says nothing about whether the signature is sound.
    @Test("openssl cms -verify accepts the signature")
    func opensslVerifiesTheCMS() throws {
        let openssl = try #require(VPhoneSignLdidHarness.which("openssl"), "openssl is not installed")
        let identity = try identity()
        for source in VPhoneSignLdidHarness.corpus.prefix(6) {
            let directory = try VPhoneSignLdidHarness.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent
            let ours = try VPhoneSignLdidHarness.copy(source, into: directory, as: name)
            try VPhoneSigner.sign(fileAt: ours, options: .init(identifier: name, identity: identity))

            let blobs = try VPhoneSignBlobs(fileAt: ours)
            for (index, slice) in blobs.slices.enumerated() {
                let cms = try #require(slice[0x10000], "\(name) slice \(index) has no CMS blob")
                let directoryBlob = try #require(slice[0], "\(name) slice \(index) has no CodeDirectory")
                let cmsFile = directory.appendingPathComponent("cms-\(index).der")
                let contentFile = directory.appendingPathComponent("cd-\(index).bin")
                // the blob wrapper's own 8-byte header is not part of the CMS
                try cms.dropFirst(8).write(to: cmsFile)
                try directoryBlob.write(to: contentFile)

                let result = try VPhoneSignLdidHarness.run(openssl, [
                    "cms", "-verify", "-inform", "DER", "-in", cmsFile.path,
                    "-content", contentFile.path, "-noverify", "-binary", "-out", "/dev/null",
                ])
                #expect(result.status == 0, "\(name) slice \(index): openssl said \(result.error)")
            }
        }
    }
}
