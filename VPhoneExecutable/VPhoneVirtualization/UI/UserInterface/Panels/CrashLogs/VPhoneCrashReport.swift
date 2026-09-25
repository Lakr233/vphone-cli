import Foundation
import VPhoneCoreKit

// MARK: - Report Row

/// One entry of vphoned `logs.crashes`: a report file in CrashReporter,
/// DiagnosticReports or CrashReporter/Retired.
struct VPhoneCrashReport: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let process: String
    let size: Int
    /// Modification time, seconds since 1970.
    let mtime: Double
    let kind: Kind
    /// `mtime` as `2026-09-25 10:15:00` in the host's time zone.
    let dateText: String
    /// `size` in KB, MB or GB.
    let sizeText: String

    var id: String {
        path
    }

    var kindTitle: String {
        kind.title
    }

    init(path: String, name: String, process: String, size: Int, mtime: Double) {
        let kind = Kind(fileName: name)
        self.path = path
        self.name = name
        self.process = kind.displayProcess(process)
        self.size = size
        self.mtime = mtime
        self.kind = kind
        dateText = Self.dateText(mtime)
        sizeText = Self.sizeText(size)
    }

    /// Returns nil for a report whose name is not one path component: the
    /// name becomes a host file name on export.
    init?(json: [String: Any]) {
        guard let path = json.string("path"), !path.isEmpty else { return nil }
        let name = json.string("name") ?? (path as NSString).lastPathComponent
        guard VPhoneGuestFileName.isSafe(name) else {
            print("[crashlogs] skipping report with unsafe name: \(name.debugDescription)")
            return nil
        }
        self.init(
            path: path,
            name: name,
            process: json.string("process") ?? name,
            size: json.int("size") ?? 0,
            mtime: json.double("mtime") ?? 0,
        )
    }

    private static func sizeText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func dateText(_ epoch: Double) -> String {
        guard epoch > 0 else { return "—" }
        let style = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
            timeZone: .current,
            calendar: Calendar(identifier: .gregorian),
        )
        return Date(timeIntervalSince1970: epoch).formatted(style)
    }
}

// MARK: - Kind

extension VPhoneCrashReport {
    /// What the file name says the report is. Only names the system writes in
    /// a fixed form are classified; everything else is labelled by extension.
    enum Kind: Hashable, Sendable {
        case jetsamEvent
        case excResource
        case excUserFault
        case cpuResource
        case diskWritesResource
        case wakeupsResource
        case stackshot
        case panic
        case legacyCrash
        case ipsReport
        case other

        init(fileName: String) {
            let lower = fileName.lowercased()
            if lower.hasPrefix("jetsamevent") {
                self = .jetsamEvent
            } else if lower.hasPrefix("excresource") {
                self = .excResource
            } else if lower.hasPrefix("excuserfault") {
                self = .excUserFault
            } else if lower.contains(".cpu_resource") {
                self = .cpuResource
            } else if lower.contains(".diskwrites_resource") {
                self = .diskWritesResource
            } else if lower.contains(".wakeups_resource") {
                self = .wakeupsResource
            } else if lower.hasPrefix("stacks") {
                self = .stackshot
            } else if lower.hasPrefix("panic") {
                self = .panic
            } else if lower.hasSuffix(".crash") {
                self = .legacyCrash
            } else if lower.hasSuffix(".ips") {
                self = .ipsReport
            } else {
                self = .other
            }
        }

        var title: String {
            switch self {
            case .jetsamEvent: String(localized: "Jetsam Event", bundle: VPhoneLocalization.bundle)
            case .excResource: String(localized: "Resource Limit", bundle: VPhoneLocalization.bundle)
            case .excUserFault: String(localized: "User Fault", bundle: VPhoneLocalization.bundle)
            case .cpuResource: String(localized: "CPU Resource", bundle: VPhoneLocalization.bundle)
            case .diskWritesResource: String(localized: "Disk Writes", bundle: VPhoneLocalization.bundle)
            case .wakeupsResource: String(localized: "Wakeups", bundle: VPhoneLocalization.bundle)
            case .stackshot: String(localized: "Stackshot", bundle: VPhoneLocalization.bundle)
            case .panic: String(localized: "Panic", bundle: VPhoneLocalization.bundle)
            case .legacyCrash: String(localized: "Crash (.crash)", bundle: VPhoneLocalization.bundle)
            case .ipsReport: String(localized: "Report (.ips)", bundle: VPhoneLocalization.bundle)
            case .other: String(localized: "Report", bundle: VPhoneLocalization.bundle)
            }
        }

        /// vphoned takes the name up to the date, so resource reports come
        /// back as `SpringBoard.cpu_resource`. The kind column says that part.
        func displayProcess(_ process: String) -> String {
            switch self {
            case .cpuResource, .diskWritesResource, .wakeupsResource:
                guard let dot = process.lastIndex(of: "."), process[dot...].hasSuffix("_resource") else { return process }
                return String(process[..<dot])
            default:
                return process
            }
        }
    }
}
