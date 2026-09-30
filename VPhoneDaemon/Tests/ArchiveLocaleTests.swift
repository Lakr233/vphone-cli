import Dispatch
import Foundation
import xlocale

private enum TestFailure: Error {
    case check(String)
    case expected
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure.check(message) }
}

private func codeset() -> String { String(cString: nl_langinfo(CODESET)) }

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

/// A stored ZIP made entirely from synthetic bytes, with the UTF-8 flag set.
/// Building the records directly also allows invalid UTF-8 and CRC fixtures.
private struct ZIPEntry {
    var name: Data
    var contents: Data
    var mode: UInt32 = 0o100644
    var corruptCRC = false

    init(_ name: String, _ contents: String, mode: UInt32 = 0o100644) {
        self.name = Data(name.utf8)
        self.contents = Data(contents.utf8)
        self.mode = mode
    }
}

private func zip(_ entries: [ZIPEntry]) -> Data {
    var output = Data(), directory = Data()
    for entry in entries {
        let offset = UInt32(output.count)
        let checksum = entry.contents.withUnsafeBytes {
            UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)))
        } ^ (entry.corruptCRC ? 1 : 0)
        output.appendLE(UInt32(0x04034B50))
        output.appendLE(UInt16(20))
        output.appendLE(UInt16(0x0800))
        output.appendLE(UInt16(0)) // stored
        output.appendLE(UInt16(0)) // time
        output.appendLE(UInt16(0)) // date
        output.appendLE(checksum)
        output.appendLE(UInt32(entry.contents.count))
        output.appendLE(UInt32(entry.contents.count))
        output.appendLE(UInt16(entry.name.count))
        output.appendLE(UInt16(0)) // extra
        output.append(entry.name)
        output.append(entry.contents)

        directory.appendLE(UInt32(0x02014B50))
        directory.appendLE(UInt16(0x0314)) // Unix creator
        directory.appendLE(UInt16(20))
        directory.appendLE(UInt16(0x0800))
        directory.appendLE(UInt16(0))
        directory.appendLE(UInt16(0))
        directory.appendLE(UInt16(0))
        directory.appendLE(checksum)
        directory.appendLE(UInt32(entry.contents.count))
        directory.appendLE(UInt32(entry.contents.count))
        directory.appendLE(UInt16(entry.name.count))
        directory.appendLE(UInt16(0)) // extra
        directory.appendLE(UInt16(0)) // comment
        directory.appendLE(UInt16(0)) // disk
        directory.appendLE(UInt16(0)) // internal attributes
        directory.appendLE(entry.mode << 16)
        directory.appendLE(offset)
        directory.append(entry.name)
    }
    let offset = UInt32(output.count)
    output.append(directory)
    output.appendLE(UInt32(0x06054B50))
    output.appendLE(UInt16(0))
    output.appendLE(UInt16(0))
    output.appendLE(UInt16(entries.count))
    output.appendLE(UInt16(entries.count))
    output.appendLE(UInt32(directory.count))
    output.appendLE(offset)
    output.appendLE(UInt16(0))
    return output
}

private func extract(_ archive: URL, _ destination: URL) throws -> [String: Any] {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    guard let result = icli_extract_ipa_json(archive.path, destination.path) else {
        throw TestFailure.check("Extractor returned no result")
    }
    defer { free(result) }
    return try JSONSerialization.jsonObject(with: Data(String(cString: result).utf8)) as! [String: Any]
}

private final class Observation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func store(_ charset: String) { lock.lock(); value = charset; lock.unlock() }
    func read() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

@main
private struct ArchiveLocaleTests {
    static func main() {
        do {
            try run()
            print("PASS: Unicode extraction, byte preservation, invalid UTF-8, CRC, traversal, symlinks, nested/throwing restoration, and concurrent locale isolation")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        // Establish the daemon's default C locale before creating any workers.
        setlocale(LC_ALL, "C")
        let original = uselocale(nil)
        let originalCodeset = codeset()
        try check(originalCodeset == "US-ASCII", "Test requires the C codeset")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "Payload/Test.app/What’s New.html"
        let content = "Synthetic Unicode resource\n"
        let resourceName = "Payload/Test.app/_CodeSignature/CodeResources"
        let resourceBytes = "Synthetic resource manifest\n"
        let data = zip([ZIPEntry(name, content), ZIPEntry(resourceName, resourceBytes)])
        let archive = root.appendingPathComponent("synthetic.ipa")
        try data.write(to: archive)

        let baseline = try extract(archive, root.appendingPathComponent("baseline"))
        try check(
            baseline["error"] as? String == "IPA: Pathname cannot be converted from UTF-8 to current locale",
            "Pinned extractor did not reproduce the C-locale failure"
        )
        let destination = root.appendingPathComponent("unicode")
        let result = try GuestArchiveLocale.withUTF8 {
            try check(codeset() == "UTF-8", "Extraction thread did not select UTF-8")
            return try extract(archive, destination)
        }
        try check(result["error"] == nil && result["entries"] as? Int == 2, "Unicode extraction failed")
        try check(try Data(contentsOf: destination.appendingPathComponent(name)) == Data(content.utf8), "Unicode name or bytes changed")
        try check(try Data(contentsOf: destination.appendingPathComponent(resourceName)) == Data(resourceBytes.utf8), "Resource manifest bytes changed")
        try check(try Data(contentsOf: archive) == data, "Input archive changed")
        try check(uselocale(nil) == original && codeset() == originalCodeset, "Success changed the caller's locale")

        var invalid = ZIPEntry("Payload/Test.app/invalid.txt", "data")
        invalid.name = Data("Payload/Test.app/".utf8) + Data([0xFF]) + Data(".txt".utf8)
        var badCRC = ZIPEntry(name, content)
        badCRC.corruptCRC = true
        let failures: [(String, [ZIPEntry], String)] = [
            ("invalid-utf8", [invalid], "current locale"),
            ("crc", [badCRC], "CRC"),
            ("traversal", [ZIPEntry("../escape", "data")], "unsafe entry path"),
            ("symlink", [ZIPEntry("Payload/Test.app/link", "../../../../escape", mode: 0o120777)], "symlink escapes"),
        ]
        for (label, entries, expected) in failures {
            let source = root.appendingPathComponent("\(label).ipa")
            try zip(entries).write(to: source)
            let failure = try GuestArchiveLocale.withUTF8 { try extract(source, root.appendingPathComponent(label)) }
            try check((failure["error"] as? String)?.contains(expected) == true, "\(label) was not rejected: \(failure)")
            try check(uselocale(nil) == original && codeset() == originalCodeset, "\(label) changed the caller's locale")
        }
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path), "Traversal wrote outside its extraction root")

        do {
            try GuestArchiveLocale.withUTF8 { throw TestFailure.expected }
            throw TestFailure.check("Expected operation error was suppressed")
        } catch TestFailure.expected {}
        try check(uselocale(nil) == original, "Throwing operation did not restore the caller's locale")
        try GuestArchiveLocale.withUTF8 {
            let outer = uselocale(nil)
            try GuestArchiveLocale.withUTF8 { try check(codeset() == "UTF-8", "Nested scope lost UTF-8") }
            try check(uselocale(nil) == outer, "Nested scope did not restore the outer locale")
        }
        try check(uselocale(nil) == original, "Nested scope did not restore the caller's locale")

        let observing = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let observation = Observation()
        DispatchQueue.global().async {
            observing.wait()
            observation.store(codeset())
            finished.signal()
        }
        try GuestArchiveLocale.withUTF8 {
            observing.signal()
            try check(finished.wait(timeout: .now() + 5) == .success, "Observer did not finish")
            try check(observation.read() == originalCodeset, "UTF-8 scope changed another worker's locale")
            _ = try extract(archive, root.appendingPathComponent("concurrent"))
        }
        try check(uselocale(nil) == original && codeset() == originalCodeset, "Concurrent test changed the caller's locale")
    }
}
