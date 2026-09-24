import Foundation

/// The `memory` object of vphoned's `memory.pressure`: kernel memory sysctls.
struct VPhoneProcessMemorySummary {
    /// `hw.memsize`.
    let totalBytes: Int64?
    /// `kern.memorystatus_level`: the percentage of memory available.
    let availablePercent: Int?
    /// `kern.memorystatus_vm_pressure_level`, in dispatch memory pressure
    /// terms: 1 normal, 2 warning, 4 critical.
    let pressureLevel: Int?

    init(_ memory: [String: Any]) {
        totalBytes = memory.int("hw_memsize").map(Int64.init)
        availablePercent = memory.int("memorystatus_level")
        pressureLevel = memory.int("memorystatus_vm_pressure_level")
    }

    var pressureTitle: String? {
        switch pressureLevel {
        case nil: nil
        case 1: String(localized: "normal", bundle: VPhoneLocalization.bundle)
        case 2: String(localized: "warning", bundle: VPhoneLocalization.bundle)
        case 4: String(localized: "critical", bundle: VPhoneLocalization.bundle)
        case let level?: String(level)
        }
    }

    /// `normal, 62% available`, or nil when the guest reported neither value.
    var summary: String? {
        switch (pressureTitle, availablePercent) {
        case let (pressure?, percent?):
            String(localized: "\(pressure), \(percent)% available", bundle: VPhoneLocalization.bundle)
        case let (pressure?, nil):
            pressure
        case let (nil, percent?):
            String(localized: "\(percent)% available", bundle: VPhoneLocalization.bundle)
        case (nil, nil):
            nil
        }
    }
}
