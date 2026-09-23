import Foundation
import MachO

// MARK: - What ldid was called for

/// The identity `-K` signs with. The CMS half is behind a protocol so the
/// ad-hoc path, which is nearly every call, needs nothing from Security.
public protocol VPhoneSigningIdentity: Sendable {
    /// The leaf certificate's common name, which goes in the designated
    /// requirement.
    var commonName: String { get }
    /// The leaf certificate's organizational unit, which is the team ID and
    /// goes in the CodeDirectory.
    var teamIdentifier: String { get }
    /// A detached CMS SignedData over `codeDirectory`, carrying the cdhashes
    /// of every CodeDirectory in the signature.
    func cms(codeDirectory: Data, cdHashes: [Data]) throws -> Data
}

/// How to sign.
public struct VPhoneSignOptions {
    /// What shape of signature to write.
    public enum Style: Sendable {
        /// Byte for byte what `ldid` writes, which is what the guest's AMFI
        /// is known to accept and what every call site in this repository
        /// has always produced. `codesign --verify` rejects it — it rejects
        /// ldid's own output too, because there is no CMS blob and the
        /// ad-hoc flag is not set.
        case ldid
        /// An ad-hoc signature in Apple's shape: the ad-hoc flag set, no
        /// designated requirement, and the empty CMS wrapper. This is what
        /// `codesign --sign -` writes and what `codesign --verify` accepts.
        case appleAdHoc
    }

    /// `-I`. The file's name when nil, as ldid defaults it.
    public var identifier: String?
    /// `-S<file>`: the entitlements to embed, as the file holds them.
    public var entitlements: Data?
    /// `-M`: merge over whatever the file is already signed with.
    public var mergesExisting = false
    public var style = Style.ldid
    /// `-K`: sign for real rather than ad-hoc.
    public var identity: (any VPhoneSigningIdentity)?

    public init(
        identifier: String? = nil,
        entitlements: Data? = nil,
        mergesExisting: Bool = false,
        style: Style = .ldid,
        identity: (any VPhoneSigningIdentity)? = nil
    ) {
        self.identifier = identifier
        self.entitlements = entitlements
        self.mergesExisting = mergesExisting
        self.style = style
        self.identity = identity
    }
}

/// Signs Mach-O files the way `ldid` does, and reads entitlements back out
/// the way `ldid -e` does.
///
/// This exists because `ldid` is the one program this project ships that
/// links Homebrew — `libcrypto.3` and `libplist-2.0.4` — and so the one
/// thing that fails the self-contained admission rule. Nothing here is
/// outside the system frameworks.
public enum VPhoneSigner {
    /// ldid's `certificate`: "a sufficiently large number" of bytes kept for
    /// the CMS blob, which has to be reserved before it can be made.
    static let cmsReservation = 0x3000

    // MARK: Signing

    /// Signs the file in place, keeping its mode.
    @discardableResult
    public static func sign(fileAt url: URL, options: VPhoneSignOptions = .init()) throws -> Data {
        var options = options
        options.identifier = options.identifier ?? url.lastPathComponent
        let data = try Data(contentsOf: url)
        let signed = try sign(data, options: options)
        // The same path ldid takes: a temporary beside the file, its mode
        // copied over, then rename(2). It has to be rename and not
        // replaceItemAt because a great many of the files this signs are
        // mode 444 — anything unpacked out of an IPSW is — and replacing
        // one needs write permission on the file, where renaming over it
        // needs it only on the directory. It is also why an interrupted run
        // leaves the original untouched rather than half written.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).vphonesign")
        try? FileManager.default.removeItem(at: temporary)
        try signed.write(to: temporary, options: .atomic)
        if let mode = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        }
        guard rename(temporary.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw VPhoneSignError.signingFailed("cannot replace \(url.path): \(reason)")
        }
        return signed
    }

    /// Signs `data`. `options.identifier` must be set; the file-based entry
    /// point fills it in from the name.
    public static func sign(_ data: Data, options: VPhoneSignOptions) throws -> Data {
        guard let identifier = options.identifier else {
            throw VPhoneSignError.signingFailed("no identifier, and no file name to take one from")
        }
        let file = try VPhoneMachOFile(data: data)

        // ldid works out the hashes once, from the first slice it reads, and
        // keeps them for the rest of the run. Every other slice inherits
        // that decision however new its own deployment target is.
        let digests = options.style == .appleAdHoc ? [.sha256] : file.slices[0].digests

        var images: [Data] = []
        for (index, slice) in file.slices.enumerated() {
            let alignment = file.architectures.map { Int($0[index].alignment) } ?? slice.linkeditAlignment
            let signature = try self.signature(
                for: slice, identifier: identifier, digests: digests, options: options
            )
            let executable = slice.executableSegment
            images.append(try slice.signed(
                alignment: alignment,
                signatureSize: { signature.allocation(codeLimit: $0) },
                makeSignature: { code, codeLimit in
                    try signature.blob(
                        code: code,
                        codeLimit: codeLimit,
                        executable: executable,
                        cms: cmsBuilder(options: options)
                    )
                }
            ))
        }
        return try file.assembled(images)
    }

    private static func cmsBuilder(
        options: VPhoneSignOptions
    ) -> ((Data, [Data]) throws -> Data)? {
        if let identity = options.identity {
            return { try identity.cms(codeDirectory: $0, cdHashes: $1) }
        }
        // codesign writes the wrapper with nothing in it, and its absence is
        // one of the two reasons codesign --verify calls ldid's output
        // unsigned
        return options.style == .appleAdHoc ? { _, _ in Data() } : nil
    }

    private static func signature(
        for slice: VPhoneMachOImage,
        identifier: String,
        digests: [VPhoneCodeSignature.Digest],
        options: VPhoneSignOptions
    ) throws -> VPhoneCodeSignature {
        var signature = VPhoneCodeSignature(identifier: identifier)
        signature.digests = digests
        signature.infoPlist = slice.infoPlist

        let mainBinary = slice.fileType == UInt32(MH_EXECUTE)
        switch options.style {
        case .ldid:
            signature.teamIdentifier = options.identity?.teamIdentifier ?? ""
            signature.requirementsBlob = VPhoneCodeSignature.requirements(
                identifier: identifier, commonName: options.identity?.commonName ?? ""
            )
            signature.cmsReservation = options.identity == nil ? nil : cmsReservation
        case .appleAdHoc:
            signature.requirementsBlob = VPhoneCodeSignature.emptyRequirements
            signature.flags = 0x2 // kSecCodeSignatureAdhoc
            signature.cmsReservation = 0
        }

        let existing = options.mergesExisting ? slice.embeddedEntitlements : nil
        if existing?.isEmpty == false || options.entitlements?.isEmpty == false {
            var combined = try VPhoneSignEntitlements(xml: existing ?? Data())
            combined.merge(try VPhoneSignEntitlements(xml: options.entitlements ?? Data()))
            signature.entitlements = (try combined.xml(), combined.der)
            signature.executableSegmentFlags = combined.executableSegmentFlags(mainBinary: mainBinary)
        } else {
            signature.executableSegmentFlags = mainBinary ? 1 : 0
        }
        return signature
    }

    // MARK: Reading entitlements back

    /// What `ldid -e` prints: the entitlements of each slice that carries
    /// any, in slice order, exactly as the signature stores them. A slice
    /// with none contributes nothing, so a file with no entitlements at all
    /// gives an empty array.
    public static func entitlements(ofFileAt url: URL) throws -> [Data] {
        try entitlements(in: Data(contentsOf: url))
    }

    public static func entitlements(in data: Data) throws -> [Data] {
        try VPhoneMachOFile(data: data).slices.compactMap(\.embeddedEntitlements)
    }
}
