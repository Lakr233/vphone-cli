import Foundation
import LibArchive

// MARK: - VPhoneArchiveOwnership

/// Who owns the files that come out of an archive.
///
/// This is not a preference — it is three different correct answers for three
/// different jobs, and using the wrong one is how an unbootable guest gets
/// made.
public enum VPhoneArchiveOwnership: Sendable {
    /// Restore the uid/gid recorded in the archive, **by number**.
    ///
    /// For unpacking onto a mounted guest volume as root. Files in
    /// iosbinpack64 that belong to `mobile` have to keep belonging to
    /// `mobile`, and `ARCHIVE_EXTRACT_PERM` does not do that — it only
    /// restores the mode bits.
    ///
    /// By number, because libarchive's name lookup would resolve the
    /// archive's `mobile` or `_wireless` against the **host's** passwd
    /// database, and either miss or, worse, hit an unrelated macOS account
    /// with the same name. This is what `tar --numeric-owner` means, and it
    /// differs slightly from GNU tar's default, which tries the name first.
    case preserveNumeric

    /// Let everything belong to whoever is running.
    ///
    /// For unpacking into a host directory as a normal user, where restoring
    /// the archive's owners would either fail outright or, as root, be a way
    /// of writing files owned by someone else.
    case currentUser
}

// MARK: - VPhoneArchiveExtractOptions

public struct VPhoneArchiveExtractOptions: Sendable {
    public var ownership: VPhoneArchiveOwnership

    /// Do not touch an existing directory's mode, owner or mtime.
    ///
    /// GNU tar spells this `--no-overwrite-dir`, and libarchive has no
    /// equivalent — see `VPhoneArchiveExtractor` for why neither the default
    /// behaviour nor `ARCHIVE_EXTRACT_NO_OVERWRITE` will do.
    public var noOverwriteDir: Bool

    /// Interpret `._*` AppleDouble members as real extended attributes.
    ///
    /// Off, deliberately. GNU tar does not understand AppleDouble either, so
    /// today those members land as ordinary files on the guest volume and the
    /// installer deletes them afterwards. Turning this on would genuinely
    /// change what ends up on an iOS volume, and the current shape is the one
    /// that has booted.
    public var macMetadata: Bool

    /// Restore ACLs and BSD file flags as well as mode bits.
    public var extendedMetadata: Bool

    public init(
        ownership: VPhoneArchiveOwnership,
        noOverwriteDir: Bool = false,
        macMetadata: Bool = false,
        extendedMetadata: Bool = false
    ) {
        self.ownership = ownership
        self.noOverwriteDir = noOverwriteDir
        self.macMetadata = macMetadata
        self.extendedMetadata = extendedMetadata
    }

    /// Unpacking onto a mounted guest volume, as root.
    ///
    /// Mirrors what `cfw_install*.sh` passes GNU tar today:
    /// `--preserve-permissions --no-overwrite-dir`.
    public static let ontoGuestVolume = VPhoneArchiveExtractOptions(
        ownership: .preserveNumeric,
        noOverwriteDir: true,
        macMetadata: false,
        extendedMetadata: true
    )

    /// Unpacking into a host directory we own and can throw away.
    public static let intoHostDirectory = VPhoneArchiveExtractOptions(
        ownership: .currentUser,
        noOverwriteDir: false,
        macMetadata: false,
        extendedMetadata: false
    )

    /// The libarchive `archive_write_disk` flags for these options.
    var extractFlags: Int32 {
        // SECURE_SYMLINKS and SECURE_NODOTDOT are unconditional, with no way
        // to turn them off. IPSWs and procursus bootstraps come from
        // elsewhere, and the destination is a mounted system volume: without
        // these, a crafted member writes wherever it likes. libarchive leaves
        // both OFF by default.
        //
        // SECURE_NOABSOLUTEPATHS is deliberately NOT set, and this is the one
        // place the implementation departs from the plan's "all three,
        // unconditionally". archive_write_disk has no notion of a destination
        // directory: it writes relative to the process's working directory. So
        // reaching an arbitrary destination means either chdir'ing there —
        // which makes extraction process-global and non-reentrant, and did
        // break when two ran at once — or giving each entry an absolute
        // target, which is what this does. That flag then rejects the very
        // paths we just computed.
        //
        // What replaces it is stronger, not weaker: VPhoneArchiveExtractor
        // normalises each target and requires it to sit under the destination
        // before writing. The flag only inspects whether a member's stored
        // path starts with a slash; the check looks at where the path actually
        // lands.
        var flags = ARCHIVE_EXTRACT_SECURE_SYMLINKS
            | ARCHIVE_EXTRACT_SECURE_NODOTDOT
            | ARCHIVE_EXTRACT_PERM
            | ARCHIVE_EXTRACT_TIME

        if ownership == .preserveNumeric { flags |= ARCHIVE_EXTRACT_OWNER }
        if extendedMetadata { flags |= ARCHIVE_EXTRACT_ACL | ARCHIVE_EXTRACT_FFLAGS }
        if macMetadata { flags |= ARCHIVE_EXTRACT_MAC_METADATA }

        return Int32(flags)
    }
}

// MARK: - VPhoneArchiveFormat

/// The tar dialect to write.
public enum VPhoneArchiveFormat: String, Sendable, CaseIterable {
    /// GNU tar. Not a default — a requirement in two places.
    ///
    /// `vm export` pipes into a consumer that reads pax extended headers as an
    /// mtree listing and fails with "Line too long"; and ustar cannot hold a
    /// member over 8 GB, which a VM bundle exceeds. Changing this breaks
    /// export.
    case gnutar
    case pax
    case ustar
}

// MARK: - VPhoneArchiveCompression

public enum VPhoneArchiveCompression: Sendable, Equatable {
    case none
    /// zstd. The default for `vm export`, at level 3.
    case zstd(level: Int)
    /// xz. What `vm export --max` uses, at level 9.
    case xz(level: Int)
    case gzip(level: Int)

    /// The extension this compressor produces for a tar archive. `vm export`
    /// hands these names to users and to older copies of itself, so they are
    /// part of the contract, not a formatting choice.
    public var tarExtension: String {
        switch self {
        case .none: "tar"
        case .zstd: "tzst"
        case .xz: "txz"
        case .gzip: "tgz"
        }
    }
}
