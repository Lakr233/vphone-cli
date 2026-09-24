import Foundation
import zlib

// MARK: - VPhoneRestoreTicket

/// Reading back what idevicerestore's `-t/--shsh` wrote.
///
/// It writes a GZIPPED binary plist — `plist_to_bin` into `gzopen`/`gzwrite`,
/// `idevicerestore.c`'s `FLAG_SHSHONLY` block — under a name that carries the
/// device's real ECID. The Python bridge wrote a plain plist under a different
/// name, so both halves have to be undone before the file can be put where
/// everything else expects it.
public enum VPhoneRestoreTicket {
    // MARK: Filename

    /// The ECID out of `<ecid>-<product type>-<version>.shsh`.
    ///
    /// idevicerestore prints `client->ecid` there in DECIMAL, and it is the
    /// ECID the device actually reported — which is the one Python used for the
    /// output name too (`device.get_ecid_value()`, not the requested value). So
    /// this is how a probe-free `--ecid`-less fetch still gets a named `.shsh`.
    public static func ecid(fromSHSHFilename name: String) -> UInt64? {
        let digits = name.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return UInt64(digits)
    }

    // MARK: Contents

    /// The plist bytes of a `.shsh`, gzip wrapper removed if there is one.
    ///
    /// Three shapes reach this: idevicerestore's gzipped binary plist, the
    /// plain XML plist the Python bridge wrote, and a bare binary plist. The
    /// result is written out as-is rather than re-serialized, so a file that
    /// came in as XML stays XML and a blob's bytes are never rewritten.
    public static func plistData(of data: Data, at path: URL) throws -> Data {
        let unwrapped: Data
        if isGzipped(data) {
            guard let inflated = gunzip(data) else {
                throw VPhoneRestoreBackendError.shshNotDecompressible(path)
            }
            unwrapped = inflated
        } else {
            unwrapped = data
        }

        // A TSS response is a dictionary with an entry per component. Anything
        // else here means the wrong file, and finding that out now beats
        // finding it out from a device that rejects every component.
        guard let object = try? PropertyListSerialization.propertyList(
            from: unwrapped,
            options: [],
            format: nil,
        ), object is [String: Any] else {
            throw VPhoneRestoreBackendError.shshMalformed(path)
        }
        return unwrapped
    }

    /// The gzip magic, `1f 8b`.
    public static func isGzipped(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Inflates a gzip stream, or `nil` if it is not one.
    ///
    /// `windowBits = 15 + 32` is zlib's "detect zlib or gzip from the header"
    /// setting, so this also reads a plain zlib stream — which nothing here
    /// writes, but a hand-made `.shsh` might.
    public static func gunzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        var stream = z_stream()
        let initialized = inflateInit2_(
            &stream,
            15 + 32,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size),
        )
        guard initialized == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return false }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(raw.count)

            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: chunk[0 ..< produced])
                }

                switch status {
                case Z_STREAM_END:
                    return true
                case Z_OK, Z_BUF_ERROR:
                    // No input left and no output produced means inflate can
                    // make no further progress and the stream ended without
                    // its trailer — a truncated file, not a finished one. Z_OK
                    // otherwise just means "call me again".
                    if produced == 0, stream.avail_in == 0 {
                        return false
                    }
                default:
                    return false
                }
            }
        }
        return ok ? output : nil
    }
}
