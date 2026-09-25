import SwiftUI

/// A log in a terminal that fills the sheet: a machine's console, which
/// `vm launch` writes, or a creation log.
struct VPhoneLaunchpadConsoleView: View {
    let title: LocalizedStringKey
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VPhoneLaunchpadLogTerminal(url: url)
            .frame(minWidth: 900, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
    }
}
