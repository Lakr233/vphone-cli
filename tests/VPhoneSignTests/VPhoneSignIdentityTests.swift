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
///
/// So what is frozen from ldid is the part that does not move — the blobs, in
/// `VPhoneSignFixtures.expected`, and the two byte counts, in
/// `expectedLengths`.
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
    ///
    /// Slot 0 and slot 4096 are the two CodeDirectories; slot 2 is in the same
    /// claim because under `-K` the designated requirement carries the leaf's
    /// common name. A slot the table has no row for must not be written, and a
    /// slot it has a row for must be — otherwise a signature missing a
    /// CodeDirectory entirely would sail past a loop that only compares what
    /// it finds.
    @Test("every CodeDirectory matches ldid -K")
    func codeDirectoriesMatchLdid() throws {
        let identity = try identity()
        let corpus = try VPhoneSignFixtures.fixtures
        #expect(corpus.count >= 12, "only \(corpus.count) fixtures: too few to say anything")
        var compared = 0
        for source in corpus {
            let directory = try VPhoneSignFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent

            let ours = try VPhoneSignFixtures.sign(
                source, in: directory, mergesExisting: true, identity: identity
            )
            for (index, slice) in try VPhoneSignBlobs(fileAt: ours).slices.enumerated() {
                for slot in [UInt32(0), 2, 0x1000] {
                    let key = "\(name).sealed.\(index).\(slot)"
                    guard VPhoneSignFixtures.isFrozen(key) else {
                        #expect(slice[slot] == nil, "\(key): ldid wrote no such blob, this signer did")
                        continue
                    }
                    let blob = try #require(slice[slot], "\(key): ldid wrote this blob, this signer did not")
                    try VPhoneSignFixtures.expect(key, matches: blob)
                    compared += 1
                }
            }
        }
        // every frozen row has to have been reached, or a corpus that lost a
        // fixture — or a signature that lost a slice — compares less and passes
        let frozen = VPhoneSignFixtures.expected.keys.count { $0.contains(".sealed.") }
        #expect(compared == frozen, "compared \(compared) of the \(frozen) frozen CodeDirectory blobs")
    }

    /// The seal, checked by `codesign --verify`, which is an action and not
    /// the verbosity flag that `-d -vvv` turns out to be.
    ///
    /// This signer passes outright, entitlements or not: `codesign --verify`
    /// exits 0 and prints "satisfies its Designated Requirement". An earlier
    /// note here said the DR clause fails whenever entitlements are present,
    /// because ldid compiles a DR naming a leaf that expired in 2018. That
    /// does not reproduce in any configuration tried — `--verify` does not
    /// build a trust chain, so the expiry never comes into it.
    ///
    /// `/usr/bin/codesign` is the one system binary this suite still calls,
    /// and it is called as a verifier rather than as a source of input.
    @Test("codesign --verify accepts the seal, with entitlements and without")
    func codesignVerifiesTheSeal() throws {
        let identity = try identity()
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        let corpus = try VPhoneSignFixtures.fixtures
        var entitled = 0
        for source in corpus {
            let directory = try VPhoneSignFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent
            if try VPhoneSigner.entitlements(ofFileAt: source).contains(where: { !$0.isEmpty }) {
                entitled += 1
            }

            let ours = try VPhoneSignFixtures.sign(
                source, in: directory, mergesExisting: true, identity: identity
            )
            let result = try VPhoneSignFixtures.run(codesign, ["--verify", "--no-strict", "-vvv", ours.path])
            #expect(result.status == 0, "\(name): \(result.error)")
            #expect(result.error.contains("valid on disk"), "\(name): \(result.error)")
            #expect(
                result.error.contains("satisfies its Designated Requirement"),
                "\(name): \(result.error)"
            )
        }
        // the entitlement-carrying half is the case the old note claimed was
        // different, so it has to be in the run
        #expect(entitled >= 7, "only \(entitled) of the fixtures carried entitlements")
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
        let identity = try identity()
        for source in try VPhoneSignFixtures.fixtures {
            let directory = try VPhoneSignFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent

            let ours = try VPhoneSignFixtures.sign(
                source, in: directory, mergesExisting: true, identity: identity
            )
            try VPhoneSignFixtures.expect(
                length: "\(name).sealedSize", is: Data(contentsOf: ours).count
            )
            for (index, slice) in try VPhoneSignBlobs(fileAt: ours).slices.enumerated() {
                let cms = try #require(slice[0x10000], "\(name) slice \(index) has no CMS")
                try VPhoneSignFixtures.expect(length: "\(name).cms.\(index)", is: cms.count)
            }
        }
    }

    /// The gate that is real evidence rather than a display: a verifier from
    /// outside this project, over the bytes this project signed. `-noverify`
    /// skips building a trust chain, which would fail on an expired leaf and
    /// says nothing about whether the signature is sound.
    @Test("openssl cms -verify accepts the signature")
    func opensslVerifiesTheCMS() throws {
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        try #require(FileManager.default.isExecutableFile(atPath: openssl.path), "openssl is not installed")
        let identity = try identity()
        for source in try VPhoneSignFixtures.fixtures.prefix(6) {
            let directory = try VPhoneSignFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = source.lastPathComponent
            let ours = try VPhoneSignFixtures.sign(source, in: directory, identity: identity)

            let blobs = try VPhoneSignBlobs(fileAt: ours)
            for (index, slice) in blobs.slices.enumerated() {
                let cms = try #require(slice[0x10000], "\(name) slice \(index) has no CMS blob")
                let directoryBlob = try #require(slice[0], "\(name) slice \(index) has no CodeDirectory")
                let cmsFile = directory.appendingPathComponent("cms-\(index).der")
                let contentFile = directory.appendingPathComponent("cd-\(index).bin")
                // the blob wrapper's own 8-byte header is not part of the CMS
                try cms.dropFirst(8).write(to: cmsFile)
                try directoryBlob.write(to: contentFile)

                let result = try VPhoneSignFixtures.run(openssl, [
                    "cms", "-verify", "-inform", "DER", "-in", cmsFile.path,
                    "-content", contentFile.path, "-noverify", "-binary", "-out", "/dev/null",
                ])
                #expect(result.status == 0, "\(name) slice \(index): openssl said \(result.error)")
            }
        }
    }
}
