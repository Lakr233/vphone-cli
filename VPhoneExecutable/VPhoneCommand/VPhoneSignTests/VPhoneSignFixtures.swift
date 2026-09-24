// VPhoneSignFixtures.swift — the corpus, and the ldid digests frozen over it.
//
// The digests in `expected` and the byte counts in `expectedLengths` are
// ldid's. They are frozen constants, not a live comparison, and nothing in
// this file runs or looks for ldid.
//
// This replaced a harness that ran Homebrew's ldid at test time over
// /bin/ls, /usr/libexec/lsd and whatever else the host happened to ship. That
// had two holes. It skipped rather than failed when ldid was absent, so on a
// clean machine the parity gate proved nothing while reporting green. And its
// corpus was this macOS version's system binaries, which is not a corpus so
// much as a coincidence — it changes under the suite with every OS update, and
// most of those files are fat with an x86_64 slice, which `VPhoneSign` now
// refuses outright (`VPhoneMachOImage.armCPUTypes`). The fixtures beside this
// file are committed instead: five hand-built Mach-Os covering the shapes that
// matter, and seven copies of the dylib that ldid has already signed with a
// real daemon's real entitlements.
//
// The bar is byte identity, not "the signature verifies". The signature's own
// size lands in the load commands, which are hashed, so one byte of slack more
// than ldid reserves and every CDHash moves. It is also the only bar that
// carries: the device this signs for runs an AMFI this project patched, and
// what that accepts cannot be re-derived from first principles. It accepts
// ldid's bytes, so ldid's bytes are the specification.
//
// KEY SHAPES
//
//   <fixture>.adhoc              after `ldid -S <file>`
//   <fixture>.entitlements       after `ldid -S<sample.plist> <file>`
//   <fixture>.mergeOwn           after `ldid -S -M <file>`
//   <fixture>.mergeSample        after `ldid -S<sample.plist> -M <file>`
//   <fixture>.identifier         after `ldid -S -Icom.apple.seputil <file>`
//   <fixture>.dump               sha256 of `ldid -e <file>` on stdout
//                                (e3b0c442…b855 is the empty string: no
//                                entitlements)
//   <fixture>.sealed.<slice>.<slot>
//                                one blob of one slice after
//                                `ldid -S -M -K<signcert.p12> <file>`; slot 0
//                                and slot 4096 are the two CodeDirectories,
//                                slot 2 the designated requirement
//   integer.<spelling>           after `ldid -S<one-key.plist> <file>` on
//                                hello-arm64 copied in as `binary`
//
// `<sample.plist>` is `VPhoneSignParityTests.sampleEntitlements` written to a
// file. The whole `-K` file cannot be frozen — a CMS carries a signing time —
// so only the blobs AMFI seals are, alongside the file's size and the CMS
// length in `expectedLengths`.
//
// TO RE-DERIVE THE TABLE
//
// ldid is deliberately not a dependency of this repository: there is no
// Homebrew formula in the admission gates, nothing resolves an `ldid` on PATH,
// and `--use-ldid` is gone. So the table is re-derived the way the keystone
// constants in Tests/FirmwarePatcherTests/ARM64EncoderTests.swift are — from a
// throwaway environment OUTSIDE this repository.
//
//   1. `brew install ldid-procursus` on a machine, not into this tree.
//   2. Write a temporary test beside this file that walks `fixtures`, runs
//      ldid over a copy of each, and prints one line per case:
//
//          let file = try copy(fixture, into: directory, as: name)
//          _ = try run(ldid, ["-S", "-I\(name)", file.path])
//          print("\"\(name).adhoc\": \"\(digest(try Data(contentsOf: file)))\",")
//
//      `-I<fixture name>` is not decoration. ldid defaults the signing
//      identifier to the file's basename, and the identifier is hashed into
//      the CodeDirectory, so without the flag every digest here depends on
//      what the working copy happened to be called and a generator that
//      copied to `x` or `theirs-lsd` silently produces a table that will
//      never reproduce. Passing it makes each row a function of the fixture's
//      bytes, the identifier and the options, and of nothing else. The
//      assertions pin it the same way, in `sign(_:in:…)` below.
//      For the `-K` rows read the blobs back with `VPhoneSignBlobs`, which is
//      the same parser the assertions use and is not `VPhoneSign`'s own.
//   3. Run it once, paste what it printed over the table below, and delete the
//      temporary test. Run it twice first: ldid's `-K` output has a signing
//      time in it, and the rows frozen here are the ones that do not move.
//
// Adding a live `ldid` call back — a `which`, a hardcoded Homebrew path, an
// environment variable — is the same regression the "Python" section of
// AGENTS.md forbids for an interpreter: a dependency `Build/ValidateBundle.sh` cannot
// see, and a silent skip when it is missing.

import CryptoKit
import Foundation
import Testing
@testable import VPhoneSign

enum VPhoneSignFixtures {
    // MARK: - The files

    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("VPhoneSignTestFixtures")
    }

    /// The hand-built Mach-Os. Between them: thin arm64 and thin arm64e, a fat
    /// file, an iOS binary whose deployment target is new enough that ldid
    /// drops SHA-1 and writes one CodeDirectory rather than two, and a dylib,
    /// which differs from a program in the executable-segment flags and in
    /// whether the main-binary bit is set.
    static let builtNames = ["hello-arm64", "hello-arm64e", "hello-fat", "hello-ios", "hello-dylib"]

    /// `hello-dylib`, signed by ldid with a real daemon's real entitlements.
    /// They are listed apart because a corpus of files carrying nothing makes
    /// every merge test pass without merging anything — and because what the
    /// merge has to survive is entitlement XML nobody here wrote. See
    /// `VPhoneSignParityTests.mergedWithoutAFile` for why that distinction is
    /// not a matter of taste.
    static let seededNames = [
        "seeded-lsd",
        "seeded-sshd",
        "seeded-spindump",
        "seeded-sysdiagnose_helper",
        "seeded-runningboardd",
        "seeded-promotedcontentd",
        "seeded-seserviced",
    ]

    /// Every fixture. A name that is not on disk fails here rather than
    /// quietly shrinking the corpus, which is the hole the old harness had.
    static var fixtures: [URL] {
        get throws {
            try (builtNames + seededNames).map { try url($0) }
        }
    }

    /// Just the seven that arrive carrying entitlements ldid put there.
    static var seeded: [URL] {
        get throws {
            try seededNames.map { try url($0) }
        }
    }

    static func url(_ name: String) throws -> URL {
        let folder = name.hasPrefix("seeded-") ? "Seeded" : "Executables"
        let url = root.appendingPathComponent(folder).appendingPathComponent(name)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "fixture \"\(name)\" is missing from \(root.path); the corpus is committed, not built",
        )
        return url
    }

    // MARK: - Holding output against the table

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `data` against the digest frozen under `key`.
    ///
    /// A key that is not in the table fails. It must: a typo in a key would
    /// otherwise look up nothing, compare nothing and pass, which is the same
    /// failure mode as the old harness skipping when ldid was absent.
    static func expect(
        _ key: String,
        matches data: Data,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) throws {
        let frozen = try #require(
            expected[key],
            "no frozen digest for \"\(key)\" — a typo, or a row the table never had",
            sourceLocation: sourceLocation,
        )
        let ours = digest(data)
        #expect(
            ours == frozen,
            """
            \(key): \(data.count) bytes
              ldid  \(frozen)
              ours  \(ours)
            """,
            sourceLocation: sourceLocation,
        )
    }

    /// The same, for the two rows that are a length rather than a digest.
    static func expect(
        length key: String,
        is length: Int,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) throws {
        let frozen = try #require(
            expectedLengths[key],
            "no frozen length for \"\(key)\"",
            sourceLocation: sourceLocation,
        )
        #expect(length == frozen, "\(key): ldid \(frozen) bytes, ours \(length)", sourceLocation: sourceLocation)
    }

    /// Whether the table has a row at all, for the cases that assert a blob is
    /// present exactly when ldid wrote one.
    static func isFrozen(_ key: String) -> Bool {
        expected[key] != nil
    }

    // MARK: - Working files

    /// Runs a verifier — `/usr/bin/codesign`, `/usr/bin/openssl` — over what
    /// this signer wrote. Nothing here runs a signer.
    @discardableResult
    static func run(_ tool: URL, _ arguments: [String]) throws -> (status: Int32, out: Data, error: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let out = Pipe(), error = Pipe()
        process.standardOutput = out
        process.standardError = error
        try process.run()
        // read before waiting: a pipe that fills would deadlock the child
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output, String(decoding: diagnostics, as: UTF8.self))
    }

    /// A directory that goes away with the test.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-sign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `source` copied in as `name`. The name matters: ldid signs under the
    /// file's own name unless told otherwise, so the frozen digests are only
    /// reproducible over a copy called what the fixture is called.
    static func copy(_ source: URL, into directory: URL, as name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    /// Signs a copy of `fixture` in `directory`, and hands back the file it
    /// wrote.
    ///
    /// Every assertion goes through here so that the signing identifier is
    /// pinned in one place. `VPhoneSigner.sign(fileAt:)` fills an unset
    /// identifier in from `url.lastPathComponent`, the way ldid does, and the
    /// identifier is hashed into the CodeDirectory — so left to default it is
    /// a hidden input to every digest in the table, taken from whatever the
    /// working copy happens to be called. A table generated against temp
    /// copies named anything else does not reproduce, and says nothing about
    /// where it went wrong. Pinning it costs nothing and removes the
    /// coupling: `identifier` defaults to the fixture's own name, which is the
    /// string the table's keys are built from.
    ///
    /// The default is exercised on its own, once, in
    /// `VPhoneSignParityTests.identifierDefaultsToTheFileName`.
    @discardableResult
    static func sign(
        _ fixture: URL,
        in directory: URL,
        identifier: String? = nil,
        entitlements: Data? = nil,
        mergesExisting: Bool = false,
        style: VPhoneSignOptions.Style = .ldid,
        identity: (any VPhoneSigningIdentity)? = nil,
    ) throws -> URL {
        let name = fixture.lastPathComponent
        let file = try copy(fixture, into: directory, as: name)
        try VPhoneSigner.sign(fileAt: file, options: .init(
            identifier: identifier ?? name,
            entitlements: entitlements,
            mergesExisting: mergesExisting,
            style: style,
            identity: identity,
        ))
        return file
    }

    /// Where two files first differ, for a failure message worth reading.
    static func difference(_ left: Data, _ right: Data) -> String {
        guard left != right else { return "identical" }
        let shared = min(left.count, right.count)
        for offset in 0 ..< shared where left[offset] != right[offset] {
            let window = offset ..< min(offset + 16, shared)
            return """
            \(left.count) vs \(right.count) bytes, first difference at \(offset) \
            (0x\(String(offset, radix: 16))): \
            \(left[window].map { String(format: "%02x", $0) }.joined()) vs \
            \(right[window].map { String(format: "%02x", $0) }.joined())
            """
        }
        return "\(left.count) vs \(right.count) bytes, identical up to the shorter one"
    }

    // MARK: - The frozen table

    static let expected: [String: String] = [
        "hello-arm64.adhoc": "0d867f9539eb1e589a3e1e76ce1185df69f46549c9037c908dea61ea164310d7",
        "hello-arm64.entitlements": "d0d84d266aef6145247c65c56995d132ddeafcf45db60dfb82792d0047b63274",
        "hello-arm64.mergeOwn": "0d867f9539eb1e589a3e1e76ce1185df69f46549c9037c908dea61ea164310d7",
        "hello-arm64.mergeSample": "d0d84d266aef6145247c65c56995d132ddeafcf45db60dfb82792d0047b63274",
        "hello-arm64.identifier": "6c8faceb90c95a56de9c47b481544af0295ddcd1c7c05dba501b4e635acfc29a",
        "hello-arm64.dump": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "hello-arm64.sealed.0.0": "7000dc5ce45ad8c41740f8d1608315c86def95971cff6c021b09090cc7636aee",
        "hello-arm64.sealed.0.2": "56df2d7c39d1dafec30312d6d60010331133c3ed34e49163d120e8fa4aac71f0",
        "hello-arm64.sealed.0.4096": "963018fc53a62908a3d258eb9dc8d5f816201469d6b28f434080bae3bee9e905",

        "hello-arm64e.adhoc": "1205cdc6e3b7a015c7faa8e589d80a1b52b9b750789caedbc25f948ad60375dd",
        "hello-arm64e.entitlements": "26ba87b649265f51b24268cfba0add33584d9a4418903acdaf7f3e0ab3273828",
        "hello-arm64e.mergeOwn": "1205cdc6e3b7a015c7faa8e589d80a1b52b9b750789caedbc25f948ad60375dd",
        "hello-arm64e.mergeSample": "26ba87b649265f51b24268cfba0add33584d9a4418903acdaf7f3e0ab3273828",
        "hello-arm64e.identifier": "b975db8c5cc84838cbded51dc9a4378c2094901fb757f7bb62cc8c34d64df4ff",
        "hello-arm64e.dump": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "hello-arm64e.sealed.0.0": "ba4239dedf25fc225252558bf2143bd77147a9b8f1e4e719a6e5c65808727589",
        "hello-arm64e.sealed.0.2": "be24f4898d79c5331187b8bb701d1c00b29687caaa813bd2f8e167e4afa30a80",
        "hello-arm64e.sealed.0.4096": "f9fc81be3406c91d1ef7b82e09dfdd31395ac0b8054703684247b6a1b0f0ce46",

        "hello-fat.adhoc": "5d29290d6336b51d4340c462a6d4688c3ecdbbf970397d9aa05aa9896fa6dbc1",
        "hello-fat.entitlements": "11007eceecac970081f7fc763b83de15c4ba2904bfee662ee42739b7a1fa48b5",
        "hello-fat.mergeOwn": "5d29290d6336b51d4340c462a6d4688c3ecdbbf970397d9aa05aa9896fa6dbc1",
        "hello-fat.mergeSample": "11007eceecac970081f7fc763b83de15c4ba2904bfee662ee42739b7a1fa48b5",
        "hello-fat.identifier": "2b767540f816150a308a4366b455e0e317bc419c1451d50a23f69d8b0538e7b7",
        "hello-fat.dump": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "hello-fat.sealed.0.0": "47d93fa448587e1e6ecffc88651a15bdc36f4857d95dac69b3eb062939e225bc",
        "hello-fat.sealed.0.2": "70f361565650c8a8e72985e2055b0fadb83f25831563b6bf6b62017270535540",
        "hello-fat.sealed.0.4096": "4bf4fd75338c8ee5220f5497141bc2d84632607ac66fe3e5642987a56d81a758",
        "hello-fat.sealed.1.0": "d5d8bd44aaaed12553b8e50e9ee9abc5c6d2beb4d7bb10cbe3e7b3f87a3aa4f1",
        "hello-fat.sealed.1.2": "70f361565650c8a8e72985e2055b0fadb83f25831563b6bf6b62017270535540",
        "hello-fat.sealed.1.4096": "e6c0f177fcbc8c827b2840004c3134e4a6606e1c98f15bdbbfbb9c4affc0c0d9",

        "hello-ios.adhoc": "8c421ac9b0cbd6f39f61cd6490915e111ba39daea5dbcf19c5c7474025a66f0d",
        "hello-ios.entitlements": "3dadd4e4df010a28fc34e3c6b490c0fe166d3a9b07ee0d2adf581dbe8dd447f5",
        "hello-ios.mergeOwn": "8c421ac9b0cbd6f39f61cd6490915e111ba39daea5dbcf19c5c7474025a66f0d",
        "hello-ios.mergeSample": "3dadd4e4df010a28fc34e3c6b490c0fe166d3a9b07ee0d2adf581dbe8dd447f5",
        "hello-ios.identifier": "676e138bedf69015cb96d923353beab6f47fbea8b2fd540463ff03263b7f55e8",
        "hello-ios.dump": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "hello-ios.sealed.0.0": "009aa84e21744a6a76d58886103ec4e80f225ca2b92a8826a32e90b628679ff8",
        "hello-ios.sealed.0.2": "352b75882b048bc8598e0ffb4fd74fb5150134cb801b9cb144e9aab52be6b7c7",
        // no hello-ios.sealed.0.4096: its deployment target is new enough that
        // ldid drops SHA-1 and writes one CodeDirectory, in slot 0

        "hello-dylib.adhoc": "e1b6a4120269fe8f6ec02338628c6381aa6a1622f9b7f908eef424cea71fa396",
        "hello-dylib.entitlements": "ba34c07b84510688eddf37619faf017640d193652ac828e2028f754322d9d7ce",
        "hello-dylib.mergeOwn": "e1b6a4120269fe8f6ec02338628c6381aa6a1622f9b7f908eef424cea71fa396",
        "hello-dylib.mergeSample": "ba34c07b84510688eddf37619faf017640d193652ac828e2028f754322d9d7ce",
        "hello-dylib.identifier": "2e413f5b67786c53e4120257ffd2891cd1c4639c393ba3c557d6095b1b44c336",
        "hello-dylib.dump": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "hello-dylib.sealed.0.0": "26b74990d9e841ccaf79b7f272b9e05f0da8efff8ff310f43901305fd77e7e7d",
        "hello-dylib.sealed.0.2": "325c672072d1d1d260b9ace6f1375623df9cc15cbd0f113158a4682a53bcece6",
        "hello-dylib.sealed.0.4096": "7325013e5e7eaea295811f768ae2e4f62a711fd6825c9270787f7e23a477911b",

        "seeded-lsd.adhoc": "b75865daa2a6bbf961aff7a6dd2fc459fd48398344edbc417343ff9915e03505",
        "seeded-lsd.entitlements": "5a58e561bc889f60b812d6841ffb796c6f7c1b28f9cca5987a6469a9fe782155",
        "seeded-lsd.mergeOwn": "374243d92856a422fa9e509c3235120f45f3a90e54856f893e549fa149832b6a",
        "seeded-lsd.mergeSample": "e4b391757d0918e6e0fab0bc883df4168a9c15fc434374b29e4e76949da8ea74",
        "seeded-lsd.identifier": "2e413f5b67786c53e4120257ffd2891cd1c4639c393ba3c557d6095b1b44c336",
        "seeded-lsd.dump": "03f79da2e8bbb9b0a14e28287ed4db3356b0bcd91a98a8b61a21f0aaff05b23d",
        "seeded-lsd.sealed.0.0": "87791b3159ae2922d6a8dd4f1d74302de20eb733d64b304301efcfad9ec92c4f",
        "seeded-lsd.sealed.0.2": "38a19160f022629395db4097ebbd1df707acb17bad32e5d20c05800359a38e47",
        "seeded-lsd.sealed.0.4096": "828517d3165d0f86a57d0824a5a10a4df6fcfbacd30d24c10ad2df7668016ff5",

        "seeded-sshd.adhoc": "59bfe57991238b9729f5d49153a88d3405876ca9ff1a023f14d130ed68879765",
        "seeded-sshd.entitlements": "8f8359417aa759412827d34db5fcb32531f7be9048a62d5915ea87d21b129c19",
        "seeded-sshd.mergeOwn": "b44de957acf5791c27b835960f33b4b9ad994e5fe2d9c6479c940e948a0bdcf7",
        "seeded-sshd.mergeSample": "acdc4e97a5ea948e0164182d8c9014d0317330254640efd95060811be5ef7048",
        "seeded-sshd.identifier": "2e413f5b67786c53e4120257ffd2891cd1c4639c393ba3c557d6095b1b44c336",
        "seeded-sshd.dump": "238db087d3cc5e94fbedaf707da33ea09f4b7b725f8af8e5841f3e9a3a6321ee",
        "seeded-sshd.sealed.0.0": "e01b21184f987edb8f2510a4eb74c723f023442b9e2c51cdc79d5a7e7a7971f6",
        "seeded-sshd.sealed.0.2": "451c5e1f01dc6ab4918de17ef406408e8702d0d969cdb1808a8ded85d8ab1a2f",
        "seeded-sshd.sealed.0.4096": "f70b05e63a5daf10d9381db4f8785bbea37325fd2385ceea30da2b1505156a16",

        "seeded-spindump.adhoc": "908ee56bf1ebc6ee4e8868ec7f12e58983484787d588b90039b05cdfa7d8269f",
        "seeded-spindump.entitlements": "d8373f3691f9defb6a71bf18f9681949f60fa3b596a56dff679f9c769e5c1b2c",
        "seeded-spindump.mergeOwn": "b6b662e901f3c1f1e397cf165ebb6519f96fe394ab73d185d48d644c74449788",
        "seeded-spindump.mergeSample": "51ff525437d9375c37bd80e86a721c258b30f9f287bf3318f1773891fd135594",
        "seeded-spindump.identifier": "2e413f5b67786c53e4120257ffd2891cd1c4639c393ba3c557d6095b1b44c336",
        "seeded-spindump.dump": "3d5d3b68deb2cf105e3a9863f672fc185383288484d47ae3b9812aa9a3e921e1",
        "seeded-spindump.sealed.0.0": "3244e7d7c5ab5556a5b3b313859ed13e9cd7ddd5274a613365056fae878be8aa",
        "seeded-spindump.sealed.0.2": "a911d0d54a8fc8662c80603d6c554a730d9c035258636aad859074111097a36d",
        "seeded-spindump.sealed.0.4096": "1abc8354901482ca2015426a311668a9286a64b656a4fa3add2a2fd543000220",

        "seeded-sysdiagnose_helper.adhoc": "d51083c4dcd9831860fec772c44a28417f2506a6ff0dd62d12339cd5f48ce044",
        "seeded-sysdiagnose_helper.entitlements": "b6d35156375cf3edcdb7d2ecb76fdf2ab5a7d1b52ad062948e4ff9649a215f49",
        "seeded-sysdiagnose_helper.mergeOwn": "7da7f83530016532ed594a85fdd283518eba0e05c7f9dbfae93bec5a364cfcd9",
        "seeded-sysdiagnose_helper.mergeSample": "c956aec3769a25a33b5974a691f8ce66d9fea726e1c1830eaf62806a73efe345",
        "seeded-sysdiagnose_helper.identifier": "2e413f5b67786c53e4120257ffd2891cd1c4639c393ba3c557d6095b1b44c336",
        "seeded-sysdiagnose_helper.dump": "5b9242e28d3e22a7cb231025d87132364af26860cbf6c1e5fc374f9aba32fcd6",
        "seeded-sysdiagnose_helper.sealed.0.0": "77a63b99c0af2678ff478cae61285696d9ba704da7486417eea12e005ba8894e",
        "seeded-sysdiagnose_helper.sealed.0.2": "a7dcb962998db6319752e24aeddec356a1cb05e58bebd958ce8c2874ec748a34",
        "seeded-sysdiagnose_helper.sealed.0.4096": "86756ed1a7353d9f3e451ed1ec6403bf5a5b0a5b8d68a8135420c8c69afb869c",

        "seeded-runningboardd.adhoc": "47eb4fc3e42abe3387d134e3050c5ce4e3022e86b8b507cfd332990035a1df26",
        "seeded-runningboardd.entitlements": "788000ebce992cc7c7644a72c139d8f3dbf588107b26945ed6ebcacb7fedb3b9",
        "seeded-runningboardd.mergeOwn": "d9f88ef88705e2cc78587ee1b288dccebcd1bc4f6a05b93fab2530d8827dbfb9",
        "seeded-runningboardd.mergeSample": "c7bdcf8e3b1aed1950e19a20ff8c08ab069340e1b12f642619e4d754f5d8f21a",
        "seeded-runningboardd.identifier": "2e413f5b67786c53e4120257ffd2891cd1c4639c393ba3c557d6095b1b44c336",
        "seeded-runningboardd.dump": "c4d27ee51ecc2fe15839687c8b4bdd127379f7ef865f4b8192ed26a0f4a3ff8d",
        "seeded-runningboardd.sealed.0.0": "ece7108f377e238802680df60d21d015f855b93d18a4deea4fc9b1ef657facb8",
        "seeded-runningboardd.sealed.0.2": "211b9b442e58c341ab3a749fcd685499e142422411d7cccc87fa62409b556f33",
        "seeded-runningboardd.sealed.0.4096": "01837980ff82700381ae3b4d276e9d56cbd83c8b306abb7f2534d6827631912d",

        "seeded-promotedcontentd.adhoc": "12e35ee8e4b2af9d9707ab57ef323d13ef37c5149b6ec96726bbe5efb03bd6b6",
        "seeded-promotedcontentd.entitlements": "254b33ba1a9a146935ab14fbe8b5f4037d59cbb31e41d3b6926a4d796b72b660",
        "seeded-promotedcontentd.mergeOwn": "3367c8f0eade36706116e6247818ce2743cb5edffff5f3d0cce76eb99f6abf55",
        "seeded-promotedcontentd.mergeSample": "da829eb5bd753041565795e55461b93fa5473497cab8e7f0316c088f12df267a",
        "seeded-promotedcontentd.identifier": "2e413f5b67786c53e4120257ffd2891cd1c4639c393ba3c557d6095b1b44c336",
        "seeded-promotedcontentd.dump": "15128d76126ff2f72ae252d4b4bbddbc314bdf813d17fa4cd89e9e2743229ca7",
        "seeded-promotedcontentd.sealed.0.0": "ddb90967d3ab281a2d84b9427946d8566fd6bb4e5e145a4a91b6ed4e5f43d0ae",
        "seeded-promotedcontentd.sealed.0.2": "9e075a6b694728c7ffe2ac9856ac7c69051e8125f060c4397704f048201d6f09",
        "seeded-promotedcontentd.sealed.0.4096": "10b3b9e55924d0228ddcc7df1360921512a8e72d6ec53760c265b040fabe83ba",

        "seeded-seserviced.adhoc": "e9a9020cd7cf9505e7b83a6a9ee87265f031463c61859fe0847886c5de04276e",
        "seeded-seserviced.entitlements": "0ed50260b214935c9776e5eb241631f2d256f7210bf9824060014f245eb494cb",
        "seeded-seserviced.mergeOwn": "3baefc92a9b0d81f2be8ae1b2fde442aedcd04ef6ef91f6c72d5bb523238de35",
        "seeded-seserviced.mergeSample": "2738f7bdff96ba44ed32093a6575d28a362c3f93466776ce9ef5584715c47208",
        "seeded-seserviced.identifier": "2e413f5b67786c53e4120257ffd2891cd1c4639c393ba3c557d6095b1b44c336",
        "seeded-seserviced.dump": "956de5a3455b78d5884cdb7595de932cf5ad160643e9d49791bfd10c7c4b9d7b",
        "seeded-seserviced.sealed.0.0": "373ee2b148f2049b5977364dac6c25a4f1a623163824a9e5205134e2a2919cb7",
        "seeded-seserviced.sealed.0.2": "2d82270e0c3807d9f38fd1fe80af5c34d9b57e66117da1f48dc9a5956dbc2e78",
        "seeded-seserviced.sealed.0.4096": "5d7588251220816ff003b82dbfed38d6ed0c25dc34e7a34b836344a6f149ca79",

        // Every `<integer>` spelling ldid takes, over hello-arm64 signed as
        // `binary`. `0`, `-0` and `+42` are not decoration: see
        // `VPhoneSignEntitlementsTests.integerSpellingsMatchLdid`.
        "integer.0": "d528a24a152ba3fb92cd563cf9f7a9dba62ed0e3b97b9eadc150589838d94c61",
        "integer.-1": "a5872164069d5e7d842afe5756a50080985cba26847d7511b5db972e82352afe",
        "integer.007": "8efe05b0ee70de5ace3571a4c573a1c1f59589f8b9b225d3c0db099a86fcc22b",
        "integer.0x10": "54b173c63ede3cb0c8c0eba6b128799257d7fda0ab70997ba92ecb1c159611d7",
        "integer.0777": "05227d8ca49e4b29a5a867125ee751f4ca4a11b4a09eee7193e7ef33618c7fcf",
        "integer.0X1F": "c33e239fce7268d87876a7017d8fff7fac4c7cacaa7e15738f171daf5240ff3f",
        "integer.+42": "ff15ea9b5e6f844b54091d1fe3e8b3e8c973e2a609ad4e1c797b474b4c7e3d08",
        "integer.-0": "d528a24a152ba3fb92cd563cf9f7a9dba62ed0e3b97b9eadc150589838d94c61",
        "integer.-0x10": "b776d9e5fa9162995a4fde6f896f5c6b4ea25cb50e2e9d0130e7c87c492bc8ee",
        "integer.1": "8597f68f6a462e65f5bd23761b568d3e8ea56c30852968758ddacd96f192bc66",
        "integer.42": "ff15ea9b5e6f844b54091d1fe3e8b3e8c973e2a609ad4e1c797b474b4c7e3d08",
        "integer.128": "d340a144ec82f451aab110e01bc183dfe12beb66e457a406936319c59e075592",
        "integer.256": "4ace6020446dd7897cecc2ca215901a16dd246832b4b74b57ce37fcc6696190d",
        "integer.2033844765": "63645cdf2608c02e191b05c9284c63ff231b37132c046cdaa6d95bc5a74ff095",
        "integer.4014732562": "72c0413f04e1d09fdb0016cf56d872f3e0f9306f5d720fd85feb56d0232b89db",
        "integer.9223372036854775807": "4af3c2b5b0631a7bc23776887e6b3b082ed19f383d8060e8eba8dcbda60f87b6",
        "integer.-9223372036854775808": "d79dcc4e26d02f41f6fe47e5e948c67cbb7042e89a49419effaf42806aef41cf",
        "integer.9223372036854775808": "52d0f381447f9754726ff63445122565643ff71392f836b433be8b358e76cdfc",
        "integer.18446744073709551615": "b59cdd1859a27174b159bfff24e5938592ec864871874edf9b1b866877f3fde3",
        "integer.  42  ": "ff15ea9b5e6f844b54091d1fe3e8b3e8c973e2a609ad4e1c797b474b4c7e3d08",
    ]

    /// The `-K` rows that are a byte count rather than a digest: the whole
    /// signed file's size, and the length of the CMS blob ldid wrote into slot
    /// 0x10000 of each slice. A CMS carries a signing time, so its bytes move
    /// between runs and its length does not — and the length is the one that
    /// matters, because the reservation is fixed and overflowing it would move
    /// `__LINKEDIT` in the load commands and change every CDHash.
    static let expectedLengths: [String: Int] = [
        "hello-arm64.sealedSize": 62976,
        "hello-arm64.cms.0": 4792,
        "hello-arm64e.sealedSize": 46352,
        "hello-arm64e.cms.0": 4792,
        "hello-fat.sealedSize": 128_272,
        "hello-fat.cms.0": 4792,
        "hello-fat.cms.1": 4792,
        "hello-ios.sealedSize": 62528,
        "hello-ios.cms.0": 4711,
        "hello-dylib.sealedSize": 29616,
        "hello-dylib.cms.0": 4792,
        "seeded-lsd.sealedSize": 35104,
        "seeded-lsd.cms.0": 4792,
        "seeded-sshd.sealedSize": 30368,
        "seeded-sshd.cms.0": 4792,
        "seeded-spindump.sealedSize": 34464,
        "seeded-spindump.cms.0": 4792,
        "seeded-sysdiagnose_helper.sealedSize": 36800,
        "seeded-sysdiagnose_helper.cms.0": 4792,
        "seeded-runningboardd.sealedSize": 35856,
        "seeded-runningboardd.cms.0": 4792,
        "seeded-promotedcontentd.sealedSize": 39040,
        "seeded-promotedcontentd.cms.0": 4792,
        "seeded-seserviced.sealedSize": 48672,
        "seeded-seserviced.cms.0": 4792,
    ]
}
