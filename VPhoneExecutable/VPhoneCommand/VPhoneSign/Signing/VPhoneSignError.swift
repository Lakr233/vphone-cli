import Foundation

// MARK: - Failures

/// Why a file could not be signed or read back. The cases are the ones a
/// caller can act on: everything else is a programming error and traps.
public enum VPhoneSignError: Error, Equatable, CustomStringConvertible {
    /// The file is not a Mach-O at all. `ldid` says "not a Mach-O file".
    case notMachO(String)
    /// A header, an architecture, a load command or the old signature points
    /// outside the file.
    case malformed(String)
    /// A slice that is not 64-bit little-endian. ldid signs 32-bit slices
    /// too; nothing this project signs has one, so it is refused rather
    /// than written wrong.
    case unsupportedSlice(String)
    /// The longer load commands do not fit in front of the first section,
    /// which happens when a file that never had a signature has no room for
    /// the `LC_CODE_SIGNATURE` one.
    case noRoom(String)
    /// Entitlements this signer will not carry over unchanged: a binary
    /// plist, a date, a real, a negative or zero integer, or XML that
    /// libplist and Foundation read differently. Signing them would silently
    /// change what the guest is granted, so it refuses instead.
    case unsupportedEntitlements(String)
    /// The PKCS#12 could not be opened: wrong password, an algorithm this
    /// reader does not implement, or a structure it does not recognise.
    case identityUnreadable(String)
    /// The CMS signature could not be produced.
    case signingFailed(String)

    public var description: String {
        switch self {
        case let .notMachO(detail): "not a Mach-O file: \(detail)"
        case let .malformed(detail): "malformed Mach-O: \(detail)"
        case let .unsupportedSlice(detail): "unsupported slice: \(detail)"
        case let .noRoom(detail): "no room for the signature load command: \(detail)"
        case let .unsupportedEntitlements(detail): "unsupported entitlements: \(detail)"
        case let .identityUnreadable(detail): "cannot read the signing identity: \(detail)"
        case let .signingFailed(detail): "signing failed: \(detail)"
        }
    }
}
