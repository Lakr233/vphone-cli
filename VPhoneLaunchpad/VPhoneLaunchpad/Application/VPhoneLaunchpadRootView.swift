import SwiftUI

struct VPhoneLaunchpadRootView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var host = model.host
        @Bindable var bundles = model.bundles
        VPhoneLaunchpadMachinesView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Machines")
            .task { await model.start() }
            // Coming back from Settings, with or without Host Setup open.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                host.refreshDeveloperTools()
            }
            .sheet(item: $model.panel, onDismiss: model.panelDidDismiss) { panel in
                Group {
                    switch panel {
                    case .hostSetup:
                        VPhoneLaunchpadHostSetupView()
                    case .coreBundle:
                        VPhoneLaunchpadCoreBundleView()
                    case .bundleInstall:
                        VPhoneLaunchpadInstallView()
                    case .ipswCache:
                        VPhoneLaunchpadIPSWCacheView()
                    case .templates:
                        VPhoneLaunchpadTemplatesView()
                    }
                }
                .environment(model)
            }
            // Over whatever sheet is open: the copy can start from Finder.
            .sheet(isPresented: Binding(get: { model.ipswImport.copy != nil }, set: { _ in })) {
                VPhoneLaunchpadIPSWImportView()
                    .environment(model)
            }
            .alert(
                model.ipswImport.outcome?.title ?? "",
                isPresented: Binding(get: { model.ipswImport.outcome != nil }, set: {
                    if !$0 {
                        model.ipswImport.outcome = nil
                    }
                }),
                presenting: model.ipswImport.outcome,
            ) { _ in
                Button("OK") {}
            } message: { outcome in
                Text(verbatim: outcome.message)
            }
            // A sheet shows its own errors; these cover work done with none
            // open, such as the helper update on launch.
            .errorAlert($host.actionError, isEnabled: model.panel == nil)
            .errorAlert($bundles.actionError, isEnabled: model.panel == nil)
    }
}

extension View {
    /// Presents an action error as an alert and clears it when dismissed.
    func errorAlert(_ error: Binding<VPhoneLaunchpadError?>, isEnabled: Bool = true) -> some View {
        alert(
            error.wrappedValue?.message ?? "",
            isPresented: Binding(
                get: { isEnabled && error.wrappedValue != nil },
                set: {
                    if !$0 {
                        error.wrappedValue = nil
                    }
                },
            ),
            presenting: error.wrappedValue,
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.detail ?? "")
        }
    }
}
