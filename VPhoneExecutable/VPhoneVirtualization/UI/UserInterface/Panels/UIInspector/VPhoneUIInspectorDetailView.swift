import SwiftUI

/// Every key of the selected record, selectable for copying.
struct VPhoneUIInspectorDetailView: View {
    let details: [VPhoneUIInspectorDetail]

    var body: some View {
        if details.isEmpty {
            Text("Select an element in the table or on the screenshot to see all of its keys.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 2) {
                    ForEach(details) { detail in
                        GridRow {
                            Text(verbatim: detail.key)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(verbatim: detail.value)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
