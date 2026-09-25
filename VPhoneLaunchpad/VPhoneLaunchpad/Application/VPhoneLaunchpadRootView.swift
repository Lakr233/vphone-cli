import SwiftUI

struct VPhoneLaunchpadRootView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.selection {
            case .hostSetup:
                VPhoneLaunchpadHostSetupView()
            case .coreBundle:
                VPhoneLaunchpadCoreBundleView()
            case .machines:
                VPhoneLaunchpadMachinesView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $model.selection) {
                    ForEach(model.sections) { section in
                        Text(model.title(for: section)).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .navigationTitle(model.selection.title)
        .task { await model.start() }
        .alert(
            model.host.actionError?.message ?? "",
            isPresented: errorBinding(\.host.actionError),
            presenting: model.host.actionError,
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.detail ?? "")
        }
        .alert(
            model.bundles.actionError?.message ?? "",
            isPresented: errorBinding(\.bundles.actionError),
            presenting: model.bundles.actionError,
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.detail ?? "")
        }
    }

    private func errorBinding(
        _ keyPath: ReferenceWritableKeyPath<VPhoneLaunchpadModel, VPhoneLaunchpadError?>,
    ) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] != nil },
            set: { if !$0 { model[keyPath: keyPath] = nil } },
        )
    }
}
