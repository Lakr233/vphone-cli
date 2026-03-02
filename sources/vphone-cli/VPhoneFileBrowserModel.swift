import Foundation
import Observation

@Observable
@MainActor
class VPhoneFileBrowserModel {
    let control: VPhoneControl

    var currentPath = "/var/mobile"
    var files: [VPhoneRemoteFile] = []
    var isLoading = false
    var error: String?
    var searchText = ""
    var selection = Set<VPhoneRemoteFile.ID>()
    var sortOrder = [KeyPathComparator(\VPhoneRemoteFile.name)]

    // Transfer progress
    var transferName: String?
    var transferCurrent: Int64 = 0
    var transferTotal: Int64 = 0
    var isTransferring: Bool { transferName != nil }

    // Navigation stack
    private var pathHistory: [String] = []

    init(control: VPhoneControl) {
        self.control = control
    }

    // MARK: - Computed

    var breadcrumbs: [(name: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        let components = currentPath.split(separator: "/", omittingEmptySubsequences: true)
        var running = ""
        for c in components {
            running += "/\(c)"
            result.append((String(c), running))
        }
        return result
    }

    var filteredFiles: [VPhoneRemoteFile] {
        let list: [VPhoneRemoteFile]
        if searchText.isEmpty {
            list = files
        } else {
            let query = searchText.lowercased()
            list = files.filter { $0.name.lowercased().contains(query) }
        }
        return list.sorted(using: sortOrder)
    }

    var statusText: String {
        let count = filteredFiles.count
        let suffix = count == 1 ? "item" : "items"
        if !searchText.isEmpty {
            return "\(count) \(suffix) (filtered)"
        }
        return "\(count) \(suffix)"
    }

    // MARK: - Navigation

    func navigate(to path: String) {
        pathHistory.append(currentPath)
        currentPath = path
        selection.removeAll()
        Task { await refresh() }
    }

    func goBack() {
        guard let prev = pathHistory.popLast() else { return }
        currentPath = prev
        selection.removeAll()
        Task { await refresh() }
    }

    func goToBreadcrumb(_ path: String) {
        if path == currentPath { return }
        pathHistory.append(currentPath)
        currentPath = path
        selection.removeAll()
        Task { await refresh() }
    }

    var canGoBack: Bool { !pathHistory.isEmpty }

    func openItem(_ file: VPhoneRemoteFile) {
        if file.isDirectory {
            navigate(to: file.path)
        }
    }

    // MARK: - Refresh

    func refresh() async {
        isLoading = true
        error = nil
        do {
            let entries = try await control.listFiles(path: currentPath)
            files = entries.compactMap { VPhoneRemoteFile(dir: currentPath, entry: $0) }
        } catch {
            self.error = "\(error)"
            files = []
        }
        isLoading = false
    }

    // MARK: - File Operations

    func downloadSelected(to directory: URL) async {
        let selected = files.filter { selection.contains($0.id) && !$0.isDirectory }
        for file in selected {
            transferName = file.name
            transferTotal = Int64(file.size)
            transferCurrent = 0
            do {
                let data = try await control.downloadFile(path: file.path)
                transferCurrent = Int64(data.count)
                let dest = directory.appendingPathComponent(file.name)
                try data.write(to: dest)
                print("[files] downloaded \(file.name) (\(data.count) bytes)")
            } catch {
                self.error = "Download failed: \(error)"
            }
        }
        transferName = nil
    }

    func uploadFiles(urls: [URL]) async {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.lastPathComponent
            let dest = (currentPath as NSString).appendingPathComponent(name)
            transferName = name
            transferTotal = Int64(data.count)
            transferCurrent = 0
            do {
                try await control.uploadFile(path: dest, data: data)
                transferCurrent = Int64(data.count)
                print("[files] uploaded \(name) (\(data.count) bytes)")
            } catch {
                self.error = "Upload failed: \(error)"
            }
        }
        transferName = nil
        await refresh()
    }

    func createNewFolder(name: String) async {
        let path = (currentPath as NSString).appendingPathComponent(name)
        do {
            try await control.createDirectory(path: path)
            await refresh()
        } catch {
            self.error = "Create folder failed: \(error)"
        }
    }

    func deleteSelected() async {
        let selected = files.filter { selection.contains($0.id) }
        for file in selected {
            do {
                try await control.deleteFile(path: file.path)
            } catch {
                self.error = "Delete failed: \(error)"
                return
            }
        }
        selection.removeAll()
        await refresh()
    }

    func renameFile(_ file: VPhoneRemoteFile, to newName: String) async {
        let newPath = (file.dir as NSString).appendingPathComponent(newName)
        do {
            try await control.renameFile(from: file.path, to: newPath)
            await refresh()
        } catch {
            self.error = "Rename failed: \(error)"
        }
    }
}
