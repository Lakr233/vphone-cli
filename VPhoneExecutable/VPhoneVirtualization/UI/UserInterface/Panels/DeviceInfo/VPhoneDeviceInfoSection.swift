import SwiftUI

// MARK: - Section

/// One titled group of key-value rows in the Device Info readout.
struct VPhoneDeviceInfoSection: Identifiable {
    enum Kind: String {
        case device
        case hardware
        case power
        case display
        case security
        case environment
        case agent
    }

    let kind: Kind
    let title: String
    let rows: [VPhoneDeviceInfoRow]

    var id: Kind {
        kind
    }
}

// MARK: - Row

struct VPhoneDeviceInfoRow: Identifiable {
    /// A semantic status dot drawn before the value.
    enum Tone {
        case good
        case warning
        case critical
        case info

        var color: Color {
            switch self {
            case .good: .green
            case .warning: .orange
            case .critical: .red
            case .info: .blue
            }
        }
    }

    let label: String
    let value: String
    var tone: Tone?
    /// A 0...1 fill drawn as a thin capacity bar under the value.
    var gauge: Double?
    /// Long single-token values (hashes) truncate in the middle and show the
    /// full value in a tooltip; everything else wraps.
    var truncatesMiddle = false

    var id: String {
        label
    }
}
