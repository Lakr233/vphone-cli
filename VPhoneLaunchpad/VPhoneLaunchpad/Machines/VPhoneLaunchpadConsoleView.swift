import SwiftUI

/// A sheet for a machine's console, which `vm launch` writes, or a creation log.
struct VPhoneLaunchpadConsoleView: View {
    let title: LocalizedStringKey
    let url: URL
    @Environment(\.dismiss) private var dismiss
    private let padding: CGFloat = 16

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
            }

            Divider()
                .padding(.horizontal, -padding)

            VPhoneLaunchpadLogTerminal(url: url)
                .frame(minWidth: 900, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)

            Divider()
                .padding(.horizontal, -padding)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(padding)
    }
}
