import CryptoKit
import Foundation

// MARK: - The embedded signature

/// The SuperBlob that goes in `__LINKEDIT`: one CodeDirectory per hash, the
/// designated requirement, a program's entitlements as XML and as DER, and
/// for a real signature the CMS blob.
///
/// Every field and every size here was read off `ldid.cpp` (Procursus 2.1.5)
/// and then checked against its output, because the guest's AMFI accepts
/// what ldid writes and the sizes end up inside the hashed load commands:
/// reserving one byte more than ldid does changes the CDHash.
struct VPhoneCodeSignature {
    enum Digest: Equatable {
        case sha1, sha256

        var size: Int {
            self == .sha1 ? 20 : 32
        }

        /// `CS_HASHTYPE_SHA1` / `CS_HASHTYPE_SHA256`.
        var type: UInt8 {
            self == .sha1 ? 1 : 2
        }

        func hash(_ data: Data) -> Data {
            self == .sha1 ? Data(Insecure.SHA1.hash(data: data)) : Data(SHA256.hash(data: data))
        }
    }

    /// What the signature is issued under: the file's name, unless `-I` said
    /// otherwise.
    var identifier: String
    /// The leaf certificate's organizational unit, which is the team ID.
    /// Empty for an ad-hoc signature, and then the field is left at 0.
    var teamIdentifier = ""
    /// The requirements blob, already compiled: ldid's designated
    /// requirement (`requirements(identifier:commonName:)`), or the empty
    /// one `codesign` writes.
    var requirementsBlob = Data()
    var entitlements: (xml: Data, der: Data)?
    /// `__TEXT,__info_plist`, hashed into slot 1 of whatever carries one.
    var infoPlist: Data?
    var executableSegmentFlags: UInt64 = 0
    /// `CodeDirectory.flags`. ldid leaves it at 0; an Apple ad-hoc signature
    /// sets `kSecCodeSignatureAdhoc`.
    var flags: UInt32 = 0
    /// Which CodeDirectories to write, in order. The first is slot 0 and the
    /// rest are `CSSLOT_ALTERNATE`.
    var digests: [Digest] = [.sha1, .sha256]
    /// How much room to leave for the CMS blob, or nil for no CMS slot at
    /// all, which is what ldid writes without `-K`. ldid reserves a flat
    /// 0x3000 and pads whatever is left over, because the signature's size
    /// has to be in the load commands before a CMS over the CodeDirectory
    /// can exist. Zero is the empty wrapper `codesign` writes for an ad-hoc
    /// signature.
    var cmsReservation: Int?

    private static let pageShift = 12
    private static let pageSize = 1 << pageShift
    /// `sizeof(struct Blob)` + `sizeof(struct CodeDirectory)` at v20400.
    private static let directoryHeader = 8 + 80

    // MARK: Sizing

    /// What ldid reserves for the whole signature, before alignment to 16.
    ///
    /// The shape is ldid's: a running total that is re-aligned to 16 once
    /// per hash, which is why the slack is not a constant.
    func allocation(codeLimit: Int) -> Int {
        let pages = (codeLimit + Self.pageSize - 1) / Self.pageSize
        let special = specialSlots

        var total = 12 // sizeof(struct SuperBlob)
        total += 8 + requirementsBlob.count // its BlobIndex, and the blob itself
        if let entitlements {
            total += 8 + 8 + entitlements.xml.count
            total += 8 + 8 + entitlements.der.count
        }
        var directory = 8 + Self.directoryHeader + identifier.utf8.count + 1
        if !teamIdentifier.isEmpty {
            directory += teamIdentifier.utf8.count + 1
        }
        for digest in digests {
            total = (total + directory + (special + pages) * digest.size).aligned(to: 16)
        }
        if let cmsReservation {
            total += 8 + 8 + cmsReservation
        }
        return total
    }

    /// The highest slot anything is hashed into, which is how many special
    /// slots each CodeDirectory carries.
    private var specialSlots: Int {
        entitlements == nil ? 2 : 7
    }

    // MARK: Writing

    /// The SuperBlob over `code`, which is the slice up to `codeLimit` with
    /// its load commands already final.
    ///
    /// `cms` is given the primary CodeDirectory and the cdhashes of them all
    /// and returns the blob to put in the signature slot; it is nil for an
    /// ad-hoc signature, and for an Apple-style one it returns no bytes at
    /// all, which is the empty wrapper `codesign` writes.
    func blob(
        code: Data,
        codeLimit: Int,
        executable: (base: UInt64, limit: UInt64),
        cms: ((_ primary: Data, _ cdHashes: [Data]) throws -> Data)? = nil,
    ) throws -> Data {
        var blobs: [(slot: UInt32, bytes: Data)] = [(2, requirementsBlob)]
        if let entitlements {
            blobs.append((5, Self.wrapped(0xFADE_7171, entitlements.xml)))
            blobs.append((7, Self.wrapped(0xFADE_7172, entitlements.der)))
        }

        var directories: [Data] = []
        for (index, digest) in digests.enumerated() {
            let directory = directory(
                digest: digest,
                code: code,
                codeLimit: codeLimit,
                executable: executable,
                blobs: blobs,
            )
            directories.append(directory)
            blobs.append((index == 0 ? 0 : 0x1000 + UInt32(index) - 1, directory))
        }

        if let cms, let primary = directories.first {
            // each CodeDirectory hashed with its own digest, at full length:
            // the attribute that carries them truncates to 20 bytes itself
            let cdHashes = zip(digests, directories).map { $0.hash($1) }
            try blobs.append((0x10000, Self.wrapped(0xFADE_0B01, cms(primary, cdHashes))))
        }

        // ldid keeps the blobs in a map, so they come out in slot order
        blobs.sort { $0.slot < $1.slot }
        var superBlob = Data()
        superBlob.appendBigEndian(0xFADE_0CC0 as UInt32)
        superBlob.appendBigEndian(UInt32(12 + 8 * blobs.count + blobs.reduce(0) { $0 + $1.bytes.count }))
        superBlob.appendBigEndian(UInt32(blobs.count))
        var offset = 12 + 8 * blobs.count
        for blob in blobs {
            superBlob.appendBigEndian(blob.slot)
            superBlob.appendBigEndian(UInt32(offset))
            offset += blob.bytes.count
        }
        return blobs.reduce(superBlob) { $0 + $1.bytes }
    }

    private func directory(
        digest: Digest,
        code: Data,
        codeLimit: Int,
        executable: (base: UInt64, limit: UInt64),
        blobs: [(slot: UInt32, bytes: Data)],
    ) -> Data {
        let identifierBytes = Data(identifier.utf8) + [0]
        let teamBytes = teamIdentifier.isEmpty ? Data() : Data(teamIdentifier.utf8) + [0]
        let special = specialSlots
        let pages = (codeLimit + Self.pageSize - 1) / Self.pageSize
        let size = Self.directoryHeader + identifierBytes.count + teamBytes.count
            + (special + pages) * digest.size

        var directory = Data()
        directory.appendBigEndian(0xFADE_0C02 as UInt32)
        directory.appendBigEndian(UInt32(size))
        directory.appendBigEndian(0x0002_0400 as UInt32) // the version with an executable segment
        directory.appendBigEndian(flags)
        directory.appendBigEndian(UInt32(
            Self.directoryHeader + identifierBytes.count + teamBytes.count + special * digest.size,
        )) // hashOffset
        directory.appendBigEndian(UInt32(Self.directoryHeader)) // identOffset
        directory.appendBigEndian(UInt32(special))
        directory.appendBigEndian(UInt32(pages))
        directory.appendBigEndian(UInt32(codeLimit))
        directory.append(contentsOf: [UInt8(digest.size), digest.type, 0, UInt8(Self.pageShift)])
        directory.appendBigEndian(0 as UInt32) // spare2
        directory.appendBigEndian(0 as UInt32) // scatterOffset
        directory.appendBigEndian(teamBytes.isEmpty
            ? 0
            : UInt32(Self.directoryHeader + identifierBytes.count)) // teamIDOffset
        directory.appendBigEndian(0 as UInt32) // spare3
        directory.appendBigEndian(0 as UInt64) // codeLimit64, zero below 4 GiB
        directory.appendBigEndian(executable.base)
        directory.appendBigEndian(executable.limit)
        directory.appendBigEndian(executableSegmentFlags)
        directory.append(identifierBytes)
        directory.append(teamBytes)

        // The special slots count down in front of the page hashes: slot 1
        // nearest them, the highest slot first. Whatever is in no slot stays
        // zero, which is how ldid leaves 3, 4 and 6.
        for slot in (1 ... special).reversed() {
            let hashed = slot == 1 ? infoPlist : blobs.first { $0.slot == UInt32(slot) }?.bytes
            directory.append(hashed.map(digest.hash) ?? Data(count: digest.size))
        }
        for start in stride(from: 0, to: codeLimit, by: Self.pageSize) {
            directory.append(digest.hash(code.subdata(in: start ..< min(start + Self.pageSize, codeLimit))))
        }
        return directory
    }

    private static func wrapped(_ magic: UInt32, _ content: Data) -> Data {
        var blob = Data()
        blob.appendBigEndian(magic)
        blob.appendBigEndian(UInt32(8 + content.count))
        return blob + content
    }

    /// `identifier "<identifier>" and anchor apple generic and certificate
    /// leaf[subject.CN] = "<common name>" and certificate
    /// 1[field.1.2.840.113635.100.6.2.1]`, compiled: what ldid writes for
    /// every file it signs, with the identifier and — under `-K` — the
    /// leaf's common name the only parts that vary.
    static func requirements(identifier: String, commonName: String) -> Data {
        func padded(_ bytes: some Sequence<UInt8>) -> Data {
            let data = Data(bytes)
            return data + Data(count: (4 - data.count % 4) % 4)
        }
        var expression = Data()
        expression.appendBigEndian(6 as UInt32) // and
        expression.appendBigEndian(2 as UInt32) // identifier
        expression.appendBigEndian(UInt32(identifier.utf8.count))
        expression.append(padded(identifier.utf8))
        expression.appendBigEndian(6 as UInt32) // and
        expression.appendBigEndian(15 as UInt32) // anchor apple generic
        expression.appendBigEndian(6 as UInt32) // and
        expression.appendBigEndian(11 as UInt32) // certificate field
        expression.appendBigEndian(0 as UInt32) // of the leaf
        expression.appendBigEndian(10 as UInt32)
        expression.append(padded("subject.CN".utf8))
        expression.appendBigEndian(1 as UInt32) // equal
        expression.appendBigEndian(UInt32(commonName.utf8.count))
        expression.append(padded(commonName.utf8))
        expression.appendBigEndian(14 as UInt32) // certificate generic
        expression.appendBigEndian(1 as UInt32) // the one above the leaf
        expression.appendBigEndian(10 as UInt32)
        expression.append(padded([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x06, 0x02, 0x01]))
        expression.appendBigEndian(0 as UInt32) // exists

        var requirements = Data()
        requirements.appendBigEndian(0xFADE_0C01 as UInt32)
        requirements.appendBigEndian(UInt32(20 + 12 + expression.count))
        requirements.appendBigEndian(1 as UInt32) // one requirement
        requirements.appendBigEndian(3 as UInt32) // the designated one
        requirements.appendBigEndian(20 as UInt32) // where it starts
        requirements.appendBigEndian(0xFADE_0C00 as UInt32)
        requirements.appendBigEndian(UInt32(12 + expression.count))
        requirements.appendBigEndian(1 as UInt32) // an expression
        return requirements + expression
    }

    /// An empty requirements blob, which is what `codesign` writes for an
    /// ad-hoc signature: no designated requirement, so the implicit one (the
    /// cdhash) applies and `codesign --verify` is satisfied.
    static var emptyRequirements: Data {
        var requirements = Data()
        requirements.appendBigEndian(0xFADE_0C01 as UInt32)
        requirements.appendBigEndian(12 as UInt32)
        requirements.appendBigEndian(0 as UInt32)
        return requirements
    }

    // MARK: Reading one back

    /// The entitlements XML a signature carries, as ldid reads it: the last
    /// blob in slot 5, and nothing where there is none.
    static func entitlementsXML(in blob: Data) -> Data? {
        guard blob.count >= 12 else { return nil }
        let count = Int(blob.bigEndianValue(at: 8) as UInt32)
        guard blob.holds(12, count * 8) else { return nil }
        var found: Data?
        for index in 0 ..< count where blob.bigEndianValue(at: 12 + index * 8) as UInt32 == 5 {
            let offset = Int(blob.bigEndianValue(at: 16 + index * 8) as UInt32)
            guard blob.holds(offset, 8) else { return nil }
            let length = Int(blob.bigEndianValue(at: offset + 4) as UInt32)
            guard length >= 8, blob.holds(offset, length) else { return nil }
            found = blob.subdata(in: offset + 8 ..< offset + length)
        }
        return found
    }
}
