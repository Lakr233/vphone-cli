import Foundation
import SwiftUI

// MARK: - Entry

/// One unified log event from vphoned `logs.syslog`. Every display string is
/// computed once at parse time so table rows stay cheap to draw and diff.
struct VPhoneConsoleEntry: Identifiable, Sendable {
    /// A per-window sequence number: arrival order, and the Time sort key.
    let id: Int
    let date: Date?
    /// `HH:mm:ss.SSS` in the Mac's time zone.
    let time: String
    let level: VPhoneConsoleLevel
    let process: String
    let pid: Int
    let subsystem: String
    let category: String
    let message: String
    /// The message's first line, capped, for the single-line table cell.
    let summary: String

    static let summaryLimit = 400

    static func summary(of message: String) -> String {
        var line = message.prefix { !$0.isNewline }
        if line.count > summaryLimit {
            line = line.prefix(summaryLimit)
        }
        return line.count == message.count ? message : String(line) + "…"
    }

    /// `subsystem:category`, or whichever of the two is set.
    var origin: String? {
        switch (subsystem.isEmpty, category.isEmpty) {
        case (true, true): nil
        case (false, true): subsystem
        case (true, false): category
        case (false, false): "\(subsystem):\(category)"
        }
    }

    /// Whether a client-side search matches the message, process or subsystem.
    func matches(_ query: String) -> Bool {
        message.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || process.range(of: query, options: .caseInsensitive) != nil
            || subsystem.range(of: query, options: .caseInsensitive) != nil
    }
}

// MARK: - Level

/// The `level` string icli reports: `notice` (os_log default), `info`,
/// `debug`, `error`, `fault`, or `default` for an unknown type.
enum VPhoneConsoleLevel: Int, Comparable, Sendable {
    case debug
    case info
    case notice
    case error
    case fault

    init(guestValue: String?) {
        switch guestValue?.lowercased() {
        case "debug": self = .debug
        case "info": self = .info
        case "error": self = .error
        case "fault": self = .fault
        default: self = .notice
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .debug: String(localized: "Debug", bundle: VPhoneLocalization.bundle)
        case .info: String(localized: "Info", bundle: VPhoneLocalization.bundle)
        case .notice: String(localized: "Default", bundle: VPhoneLocalization.bundle)
        case .error: String(localized: "Error", bundle: VPhoneLocalization.bundle)
        case .fault: String(localized: "Fault", bundle: VPhoneLocalization.bundle)
        }
    }

    /// The token written to saved log files; not localized.
    var logToken: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .notice: "Default"
        case .error: "Error"
        case .fault: "Fault"
        }
    }

    var color: Color {
        switch self {
        case .fault: .red
        case .error: .orange
        default: .secondary
        }
    }
}

// MARK: - Level Filter

/// The level picker. It is sent as the `level` parameter of the next capture
/// and also filters the rows already loaded.
enum VPhoneConsoleLevelFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case error
    case fault

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .all: String(localized: "All", bundle: VPhoneLocalization.bundle)
        case .error: String(localized: "Errors", bundle: VPhoneLocalization.bundle)
        case .fault: String(localized: "Faults", bundle: VPhoneLocalization.bundle)
        }
    }

    func includes(_ level: VPhoneConsoleLevel) -> Bool {
        switch self {
        case .all: true
        case .error: level >= .error
        case .fault: level == .fault
        }
    }
}
