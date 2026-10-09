import SwiftUI

/// A sheet for a machine's console, which `vm launch` writes, or a creation log.
struct VPhoneLaunchpadConsoleView: View {
    let title: LocalizedStringKey
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VPhoneLaunchpadSheet(Text(title), width: VPhoneLaunchpadSheetSize.wide) {
            VPhoneLaunchpadLogTerminal(url: url)
                .frame(maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        } actions: {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }
}
