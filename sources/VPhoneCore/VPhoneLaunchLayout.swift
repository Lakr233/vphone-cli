import Foundation

// MARK: - VPhoneLaunchLayout

public struct VPhoneLaunchLayout: Sendable {
    public let resources: VPhoneResources

    public init(resources: VPhoneResources) { self.resources = resources }
    public init(projectRoot: URL) { self.init(resources: VPhoneResources(base: projectRoot)) }

    public var preflightScript: URL { resources.preflightScript }
    public var fwPrepareScript: URL { resources.fwPrepareScript }
    public var cfwInstallHostScript: URL { resources.cfwInstallHostScript }
    public var pmd3Bridge: URL { resources.pmd3Bridge }
    public var vphoned: URL { resources.vphoned }

    public func python() throws -> URL { try resources.pythonExecutable() }

    /// Copy the built vphoned into the bundle if present and different.
    @discardableResult
    public func stageVphoned(into bundle: VPhoneBundle) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: vphoned.path) else { return false }
        let dst = bundle.url.appendingPathComponent(".vphoned.signed")
        if fm.fileExists(atPath: dst.path),
           let a = try? Data(contentsOf: vphoned),
           let b = try? Data(contentsOf: dst), a == b {
            return false
        }
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: vphoned, to: dst)
        return true
    }
}

// MARK: - VPhoneLsof

public enum VPhoneLsof {
    public static func parsePIDs(_ output: String) -> [Int32] {
        var seen = Set<Int32>()
        var pids: [Int32] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(trimmed), !seen.contains(pid) else { continue }
            seen.insert(pid)
            pids.append(pid)
        }
        return pids.sorted()
    }
}
