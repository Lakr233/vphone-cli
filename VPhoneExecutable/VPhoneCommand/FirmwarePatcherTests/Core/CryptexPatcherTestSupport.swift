// CryptexPatcherTestSupport.swift — shared fixtures for the CryptexFilesystemPatcher suites.
//
// `makeScratch` and `makePatcher` stand a patcher up over a throwaway restore
// directory. They are shared by the file-operation suite (CryptexFileOpsTests)
// and the watch speaker payload selection suite

@testable import FirmwarePatcher
import Foundation

func makePatcher(_ scratch: URL) -> CryptexFilesystemPatcher {
    CryptexFilesystemPatcher(buildManiest: Data(), restoreDir: scratch, verbose: false)
}

func makeScratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("vphone-cryptex-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    guard let path = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path))
}
