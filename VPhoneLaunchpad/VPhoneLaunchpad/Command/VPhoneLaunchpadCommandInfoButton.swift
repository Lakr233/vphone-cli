import AppKit
import SwiftUI

/// An (i) button that keeps a command out of the row and shows it, with a
/// copy button, in a popover.
struct VPhoneLaunchpadCommandInfoButton: View {
    let command: String
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Show the command")
        .accessibilityLabel(Text("Show the command"))
        // Below the button, or above it near the bottom of the screen: a
        // side popover covers the rows next to it.
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480, alignment: .leading)
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
            .padding(12)
        }
    }
}
