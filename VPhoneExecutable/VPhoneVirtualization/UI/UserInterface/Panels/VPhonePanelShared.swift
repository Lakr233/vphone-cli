import Foundation
import SwiftUI

// MARK: - JSON Values

/// vphoned answers with JSONSerialization objects. These readers accept the
/// NSNumber and string spellings the guest uses for the same field.
extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        switch self[key] {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    func int(_ key: String) -> Int? {
        switch self[key] {
        case let value as NSNumber: value.intValue
        case let value as String: Int(value)
        default: nil
        }
    }

    func double(_ key: String) -> Double? {
        switch self[key] {
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
    }

    func bool(_ key: String) -> Bool? {
        switch self[key] {
        case let value as NSNumber: value.boolValue
        case let value as String: ["1", "true", "yes", "on"].contains(value.lowercased())
        default: nil
        }
    }

    func object(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func objects(_ key: String) -> [[String: Any]] {
        self[key] as? [[String: Any]] ?? []
    }
}

// MARK: - Formatting

enum VPhonePanelFormat {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    static func bytes(_ value: Int?) -> String {
        bytes(value.map(Int64.init))
    }

    /// A duration such as `2d 4h`, `3h 12m`, `41s`.
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds < 60 ? [.second] : [.day, .hour, .minute, .second]
        return formatter.string(from: seconds) ?? "—"
    }

    /// CPU time with sub-second precision for short-lived processes.
    static func cpuTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        if seconds < 60 {
            return String(format: "%.2fs", seconds)
        }
        return duration(seconds)
    }

    static func date(_ epoch: Double?) -> String {
        guard let epoch, epoch > 0 else { return "—" }
        return Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .standard)
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

// MARK: - Empty State

/// The centered placeholder a panel shows before its first load or when a
/// filter matches nothing.
struct VPhonePanelEmptyState: View {
    let title: LocalizedStringKey
    let systemImage: String
    var message: LocalizedStringKey?

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title, bundle: VPhoneLocalization.bundle)
            } icon: {
                Image(systemName: systemImage)
            }
        } description: {
            if let message {
                Text(message, bundle: VPhoneLocalization.bundle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Monospaced Cell

/// A single-line table cell in the research-instrument monospace style.
struct VPhonePanelMonoText: View {
    let value: String
    var secondary = false

    init(_ value: String, secondary: Bool = false) {
        self.value = value
        self.secondary = secondary
    }

    var body: some View {
        Text(value)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(secondary ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(value)
    }
}
