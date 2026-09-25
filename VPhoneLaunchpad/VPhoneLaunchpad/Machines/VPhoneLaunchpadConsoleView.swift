import SwiftUI

/// A machine's console: the log `vm launch` writes, in a terminal that fills
/// the sheet.
struct VPhoneLaunchpadConsoleView: View {
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VPhoneLaunchpadLogTerminal(url: VPhoneLaunchpadMachineLibrary.consoleLog(name))
            .frame(minWidth: 900, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
            .navigationTitle("\(name) Console")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
    }
}
