import Foundation
import MobileRestoreCore

enum VPhoneRestoreEngine {
    static func requestSHSH(
        restoreBundlePath: String,
        cacheDirectory: String,
        udid: String?,
        ecid: UInt64?
    ) throws -> URL {
        try run(
            restoreBundlePath: restoreBundlePath,
            cacheDirectory: cacheDirectory,
            udid: udid,
            ecid: ecid,
            flags: Int32(VPHONE_RESTORE_FLAG_SHSH_ONLY)
        )

        let shshDirectory = URL(fileURLWithPath: cacheDirectory, isDirectory: true)
            .appendingPathComponent("shsh", isDirectory: true)
        return try latestSHSH(in: shshDirectory, matching: ecid)
    }

    static func restore(
        restoreBundlePath: String,
        cacheDirectory: String,
        udid: String?,
        ecid: UInt64?
    ) throws {
        try run(
            restoreBundlePath: restoreBundlePath,
            cacheDirectory: cacheDirectory,
            udid: udid,
            ecid: ecid,
            flags: 0
        )
    }
}

private extension VPhoneRestoreEngine {
    final class CallbackBox {
        var lastProgressStep: Int32 = -1
        var lastProgressValue: Int = -1
    }

    static func run(
        restoreBundlePath: String,
        cacheDirectory: String,
        udid: String?,
        ecid: UInt64?,
        flags: Int32
    ) throws {
        let box = CallbackBox()
        let retained = Unmanaged.passRetained(box)
        defer { retained.release() }

        let result = restoreBundlePath.withCString { restorePath in
            cacheDirectory.withCString { cachePath in
                withOptionalCString(udid) { udidPtr in
                    var options = vphone_restore_options(
                        ipsw_path: restorePath,
                        cache_dir: cachePath,
                        udid: udidPtr,
                        ecid: ecid ?? 0,
                        flags: flags,
                        log_cb: vphoneRestoreLogCallback,
                        progress_cb: vphoneRestoreProgressCallback,
                        context: retained.toOpaque()
                    )
                    return vphone_restore_run(&options)
                }
            }
        }

        guard result == 0 else {
            throw VPhoneHostError.invalidArgument("idevicerestore returned \(result)")
        }
    }

    static func latestSHSH(in directory: URL, matching ecid: UInt64?) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let candidates = entries.filter { url in
            let lowercased = url.pathExtension.lowercased()
            guard lowercased == "shsh" || lowercased == "shsh2" else {
                return false
            }
            guard let ecid else {
                return true
            }
            let prefix = "\(ecid)"
            return url.lastPathComponent.hasPrefix(prefix)
        }

        guard let latest = candidates.max(by: {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs < rhs
        }) else {
            throw VPhoneHostError.invalidArgument("idevicerestore completed but no SHSH file was written to \(directory.path)")
        }
        return latest
    }

    static func withOptionalCString<Result>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let string else {
            return body(nil)
        }
        return string.withCString(body)
    }
}

private func vphoneRestoreLogCallback(
    _ level: Int32,
    _ message: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let message else {
        return
    }
    fputs(message, stdout)
    if message.pointee != 0, String(cString: message).hasSuffix("\n") == false {
        fputc(Int32(UInt8(ascii: "\n")), stdout)
    }
    fflush(stdout)
}

private func vphoneRestoreProgressCallback(
    _ step: Int32,
    _ progress: Double,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else {
        return
    }
    let box = Unmanaged<VPhoneRestoreEngine.CallbackBox>.fromOpaque(context).takeUnretainedValue()
    let rounded = Int(progress * 100.0)
    if box.lastProgressStep == step, box.lastProgressValue == rounded {
        return
    }
    box.lastProgressStep = step
    box.lastProgressValue = rounded
    print(String(format: "[*] restore progress step=%d %.1f%%", step, progress * 100.0))
}
