import SwiftUI

// MARK: - Status

nonisolated enum VPhoneLaunchpadStatus: Equatable, Sendable {
    case passed
    case warning
    case failed
    case pending
    case running
}

/// The state of a check or step as the system draws it: an SF Symbol in its
/// semantic colour, or a small spinner while work is in flight. Every state
/// occupies the same square, so the triangle and the spinner do not push the
/// text beside them out of line.
struct VPhoneLaunchpadStatusIcon: View {
    let status: VPhoneLaunchpadStatus

    var body: some View {
        symbol
            .frame(width: 16, height: 16)
    }

    @ViewBuilder
    private var symbol: some View {
        switch status {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}
