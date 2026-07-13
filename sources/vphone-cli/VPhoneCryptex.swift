import Foundation
import System

// CryptexSpec provides a container for describing a cryptex image between various layers


enum CryptexError: Error {
    case FileError(String)
    case ProcessError(String)
    case ZipError
}

struct Cryptex: CustomStringConvertible {
    let variant: String
    let path: FilePath

    var description: String { "\(variant):\(path.lastComponent ?? "-")" }

    init(
        path: String,
        variant: String,
    ) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw POSIXError(.ENOENT)
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw POSIXError(.EFTYPE)
        }

        self.path = FilePath(path)
        self.variant = variant
    }
    
    static func createCryptex(source: String, name: String) throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "vphone-\(UUID.init().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        
        let diskImagePath = try createDiskImage(sourceDirectory: source, tmpDir: tmpDir)
        let cryptexPath = try createCryptex(imagePath: diskImagePath, name: name, tmpDir: tmpDir)
        let cryptexArchivePath = try createCryptexArchive(cryptexPath: cryptexPath, name: name)
        return cryptexArchivePath
    }
    
    static func createDiskImage(sourceDirectory: String, tmpDir: URL) throws -> String {
        let diskImageURL = tmpDir.appendingPathComponent("cryptex.dmg")
        _ = try runProcess("/usr/bin/hdiutil", ["create", "-srcfolder", sourceDirectory, diskImageURL.path])
        return diskImageURL.path
    }

    static func createCryptex(imagePath: String, name: String, tmpDir: URL) throws -> String {
        _ = try runProcess("/System/Library/SecurityResearch/usr/bin/cryptexctl.research", [
            "create",
            "--output-directory=\(tmpDir.path)",
            "--restricted-exec-mode-default=both",
            "--identifier=\(name)",
            "--mount-point=/private/var/PrivateCloudSupportInternalAdditions", // We currently support only one cryptex
            "-v", "1",
            "-V", name,
            "--FCHP=0xff10",
            "--TYPE=0x3",
            "--STYP=0x1",
            "--CLAS=0xf2",
            "--NDOM=0x3",
            "--BORD=0x90",
            "--CHIP=0xfe01",
            "--SDOM=0x1",
            imagePath,
        ])

        let newCryptexURL = tmpDir.appending(component: "\(name).cxbd")
        return newCryptexURL.path
    }

    static func createCryptexArchive(cryptexPath: String, name: String) throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory.appending(path: "vphone-\(UUID.init().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let archivePath = tmpDir.appending(path: name + ".tar")
        
        let cryptexUrl = URL(fileURLWithPath: cryptexPath)

        _ = try runProcess("/usr/bin/tar", [
            "-c",
            "-C", cryptexUrl.deletingLastPathComponent().path,
            "-f", archivePath.path,
            cryptexUrl.lastPathComponent])

        return archivePath.path
    }
    
    static func runProcess(_ launchPath: String, _ arguments: [String], sudo: Bool = false, output: URL? = nil) throws -> String {
        let process = Process()
        if sudo {
            let whoami = try runProcess("/usr/bin/whoami", [])
            if !whoami.contains("root") {
                print("Please rerun as root or fix this program")
                exit(42)
            }
        }
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

        let output = output == nil ? String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) : nil
        guard process.terminationStatus == 0 else {
            throw CryptexError.ProcessError("\(process.terminationStatus), \(output ?? "")")
        }
        return output ?? ""
    }
}
