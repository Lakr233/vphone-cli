import Darwin
import Foundation

enum VPhoneSystem {
    static func sysctlString(_ name: String) throws -> String {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let bytes = buffer.prefix { $0 != 0 }
        return String(decoding: bytes.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    static func operatingSystemSummary() throws -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let productVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let buildVersion = try sysctlString("kern.osversion").trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "ProductName:\t\tmacOS",
            "ProductVersion:\t\t\(productVersion)",
            "BuildVersion:\t\t\(buildVersion)",
        ].joined(separator: "\n")
    }
}
