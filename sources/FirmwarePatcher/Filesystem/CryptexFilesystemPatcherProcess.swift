// CryptexFilesystemPatcherProcess.swift — Subprocess execution for the filesystem patcher.
//
// Split out of CryptexFilesystemPatcher.swift. Every external tool the merge drives — hdiutil,
// diskutil, ipsw, aa, cryptexctl, apfs_sealvolume — runs through runProcess, and ProcessError
// is what it throws. What no longer runs through it: tar (VPhoneArchive), and chmod, chown, ln
// and find (CryptexFilesystemPatcherFileOps.swift).
//
// There used to be a `sudo: Bool` parameter here that spawned `/usr/bin/whoami` and matched
// "root" in its output. Nothing ever passed it — it was dead on every call site — and the
// question it asked is `geteuid()`, which needs no process and no string match. The live root
// check is VPhoneCreateOrchestrator's, before any of this runs.

import Foundation

enum ProcessError: Error {
    case failed(Int32, String)
    case notExecutable(String)
}

extension CryptexFilesystemPatcher {
    func runProcess(
        _ launchPath: String,
        _ arguments: [String],
        output: URL? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        if let output {
            let outFile = try FileHandle.init(forWritingTo: output)
            process.standardOutput = outFile
            process.standardError = outFile
        } else {
            process.standardOutput = outPipe
            process.standardError = outPipe
        }

        try process.run()
        process.waitUntilExit()

        let output = output == nil
            ? String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            : nil
        guard process.terminationStatus == 0 else {
            throw ProcessError.failed(process.terminationStatus, output ?? "")
        }
        return output ?? ""
    }
}
