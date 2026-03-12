import Foundation

@MainActor
@Observable
class VPhoneAppBrowserModel {
    let control: VPhoneControl

    var apps: [VPhoneControl.AppInfo] = []
    var filter: AppFilter = .installed
    var searchText = ""
    var isLoading = false
    var error: String?

    enum AppFilter: String, CaseIterable {
        case installed = "all"
        case running
        case user
        case system
    }

    var filteredApps: [VPhoneControl.AppInfo] {
        guard !searchText.isEmpty else { return apps }
        let query = searchText.lowercased()
        return apps.filter {
            $0.name.lowercased().contains(query)
                || $0.bundleId.lowercased().contains(query)
        }
    }

    init(control: VPhoneControl) {
        self.control = control
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            apps = try await control.appList(filter: filter.rawValue)
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}
