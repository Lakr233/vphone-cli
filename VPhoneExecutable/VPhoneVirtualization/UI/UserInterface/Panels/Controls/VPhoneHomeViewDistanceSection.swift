import SwiftUI

struct VPhoneHomeViewDistanceSection: View {
    let control: VPhoneGuestControl
    @State private var model: VPhoneHomeViewDistanceModel

    init(control: VPhoneGuestControl) {
        self.control = control
        _model = State(initialValue: VPhoneHomeViewDistanceModel { method, params in
            try await control.call(method, params: params)
        })
    }

    var body: some View {
        Section("Viewing Distance") {
            LabeledContent("Current") {
                Text(model.mode?.title ?? String(localized: "Unknown", bundle: VPhoneLocalization.bundle))
            }
            Picker("Simulated Distance", selection: $model.selection) {
                ForEach(VPhoneHomeViewDistanceModel.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .disabled(!model.isAvailable || model.isBusy)
            HStack {
                Button { Task { await model.apply() } } label: {
                    if model.selection == .automatic {
                        Text("Reset Environment Simulation")
                    } else {
                        Text("Apply")
                    }
                }
                    .disabled(!model.isAvailable || model.isBusy)
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.isBusy)
            }
            Text(model.selection == .automatic
                ? String(localized: "Resets all native environment simulation overrides, including persona, display style, detail, and backlight.", bundle: VPhoneLocalization.bundle)
                : String(localized: "Near and Far simulate HomeView’s distance-driven detail levels without changing other environment overrides.", bundle: VPhoneLocalization.bundle))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = model.error {
                Text(verbatim: error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if control.isConnected && !control.guestCapabilities.contains("homeview_distance") {
                Text("This guest environment does not support distance simulation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: control.isConnected && control.guestCapabilities.contains("homeview_distance")) {
            if control.isConnected && control.guestCapabilities.contains("homeview_distance") {
                await model.refresh()
            } else {
                model.disconnected()
            }
        }
    }
}
