import Foundation

@MainActor
@Observable
class VPhoneAppBrowserModel {
    let control: VPhoneGuestControl

    var apps: [VPhoneGuestControl.AppInfo] = []
    var filter: AppFilter = .installed
    var searchText = ""
    var selection = Set<VPhoneGuestControl.AppInfo.ID>()
    var sortOrder = [KeyPathComparator(\VPhoneGuestControl.AppInfo.name)]
    var isLoading = false
    var error: String?

    enum AppFilter: String, CaseIterable {
        case installed = "all"
        case running
        case user
        case system
    }

    var filteredApps: [VPhoneGuestControl.AppInfo] {
        let query = searchText.lowercased()
        let visible = query.isEmpty ? apps : apps.filter {
            $0.name.lowercased().contains(query)
                || $0.bundleId.lowercased().contains(query)
        }
        return visible.sorted(using: sortOrder)
    }

    init(control: VPhoneGuestControl) {
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
