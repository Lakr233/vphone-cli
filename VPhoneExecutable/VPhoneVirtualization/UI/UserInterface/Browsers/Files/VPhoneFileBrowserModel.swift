import Foundation
import Observation
import VPhoneCoreKit

@Observable
@MainActor
class VPhoneFileBrowserModel {
    let control: VPhoneGuestControl
    private let quickLookController: VPhoneQuickLookController
    /// Tracks an in-flight Quick Look download so it can be cancelled on selection change.
    private var quickLookTask: Task<Void, Never>?

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
    var isTransferring: Bool {
        transferName != nil
    }

    /// Navigation stacks
    private var pathHistory: [String] = []
    private var forwardHistory: [String] = []
    private var refreshGeneration = 0

    init(control: VPhoneGuestControl, quickLookController: VPhoneQuickLookController) {
        self.control = control
        self.quickLookController = quickLookController
    }

    // MARK: - Computed

    var breadcrumbs: [(name: String, path: String)] {
        var result = [("/", "/")]
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
        if !searchText.isEmpty {
            return VPhoneLocalization.format("%@ items (filtered)", String(count))
        }
        return count == 1
            ? VPhoneLocalization.text("1 item")
            : VPhoneLocalization.format("%@ items", String(count))
    }

    // MARK: - Navigation

    func navigate(to path: String) {
        pathHistory.append(currentPath)
        forwardHistory.removeAll()
        currentPath = path
        refreshGeneration += 1
        selection.removeAll()
        Task { await refresh() }
    }

    func goBack() {
        guard let prev = pathHistory.popLast() else { return }
        forwardHistory.append(currentPath)
        currentPath = prev
        refreshGeneration += 1
        selection.removeAll()
        Task { await refresh() }
    }

    func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        pathHistory.append(currentPath)
        currentPath = next
        refreshGeneration += 1
        selection.removeAll()
        Task { await refresh() }
    }

    func goToBreadcrumb(_ path: String) {
        guard path != currentPath else { return }
        navigate(to: path)
    }

    var canGoBack: Bool {
        !pathHistory.isEmpty
    }

    var canGoForward: Bool {
        !forwardHistory.isEmpty
    }

    func openItem(_ file: VPhoneRemoteFile) {
        if file.isDirectoryLike {
            navigate(to: file.path)
        }
    }

    // MARK: - Quick Look

    func quickLookSelected() {
        guard let id = selection.first,
              let file = filteredFiles.first(where: { $0.id == id }),
              !file.isDirectoryLike
        else { return }

        quickLookTask?.cancel()

        quickLookTask = Task { @MainActor in
            do {
                let data = try await control.downloadFile(path: file.path)
                guard !Task.isCancelled else { return }
                quickLookController.open(data: data, filename: file.name)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = VPhoneLocalization.format("Unable to preview “%@”. Check the connection, then try again.", file.name)
            }
            quickLookTask = nil
        }
    }

    func closeQuickLook() {
        quickLookTask?.cancel()
        quickLookTask = nil
        quickLookController.close()
    }

    // MARK: - Refresh

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let path = currentPath
        isLoading = true
        error = nil
        do {
            let entries = try await control.listFiles(path: path)
            guard generation == refreshGeneration, path == currentPath else { return }
            files = entries.compactMap { VPhoneRemoteFile(dir: path, entry: $0) }
            selection.formIntersection(Set(files.map(\.id)))
        } catch {
            guard generation == refreshGeneration, path == currentPath else { return }
            self.error = VPhoneLocalization.text("Unable to load this folder. Check the connection, then try again.")
            files = []
        }
        isLoading = false
    }

    // MARK: - File Operations

    func downloadSelected(to directory: URL) async {
        let selected = files.filter { selection.contains($0.id) }
        let destination: Int32
        do {
            destination = try VPhoneHostSafeFile.openDestination(directory)
        } catch {
            self.error = VPhoneLocalization.format("Download failed: %@", String(describing: error))
            return
        }
        defer { close(destination) }
        for file in selected {
            if file.isDirectoryLike {
                await downloadDirectory(file, to: destination, ancestors: [])
            } else {
                await downloadFile(remotePath: file.path, name: file.name, size: file.size, to: destination)
            }
            if error != nil {
                break
            }
        }
        transferName = nil
    }

    /// `directory` is an open descriptor; the file lands there through a
    /// temporary O_EXCL|O_NOFOLLOW entry and a rename, never through a link.
    private func downloadFile(remotePath: String, name: String, size: UInt64, to directory: Int32) async {
        transferName = name
        transferTotal = Int64(size)
        transferCurrent = 0
        do {
            var count = Int64(0)
            try await VPhoneHostSafeFile.write(named: name, in: directory) { handle in
                count = try await control.downloadFile(path: remotePath, to: handle)
            }
            transferCurrent = count
            print("[files] downloaded \(remotePath) (\(count) bytes)")
        } catch {
            self.error = VPhoneLocalization.format("Unable to download “%@”. Try again.", name)
        }
    }

    private func downloadDirectory(
        _ file: VPhoneRemoteFile,
        to localParent: Int32,
        ancestors: Set<String>,
    ) async {
        guard !file.isSymbolicLink || file.resolvedPath != nil else {
            error = VPhoneLocalization.format("Unable to download %@. Update the guest agent, then try again.", file.path)
            return
        }
        let resolvedPath = file.resolvedPath ?? file.path
        guard !ancestors.contains(resolvedPath) else {
            error = VPhoneLocalization.format("Unable to download %@. The folder link points back to a parent folder.", file.path)
            return
        }
        let ancestors = ancestors.union([resolvedPath])
        let localDir: Int32
        do {
            localDir = try VPhoneHostSafeFile.makeDirectory(named: file.name, in: localParent)
        } catch {
            self.error = VPhoneLocalization.format("Unable to create the folder “%@” on this Mac. Choose another location, then try again.", file.name)
            return
        }
        defer { close(localDir) }

        let entries: [[String: Any]]
        do {
            entries = try await control.listFiles(path: file.path)
        } catch {
            self.error = VPhoneLocalization.format("Unable to read the folder “%@”. Check the connection, then try again.", file.name)
            return
        }

        let children = entries.compactMap { VPhoneRemoteFile(dir: file.path, entry: $0) }
        for child in children {
            if child.isDirectoryLike {
                await downloadDirectory(child, to: localDir, ancestors: ancestors)
            } else {
                await downloadFile(
                    remotePath: child.path,
                    name: child.name,
                    size: child.size,
                    to: localDir,
                )
            }
            if error != nil {
                return
            }
        }
    }

    func uploadFiles(urls: [URL]) async {
        var uploadError: String?
        for url in urls {
            let name = url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let dest = (currentPath as NSString).appendingPathComponent(name)
            transferName = name
            transferTotal = size
            transferCurrent = 0
            do {
                // Streamed from disk in chunks; the file is never loaded whole.
                let sent = try await control.uploadFile(path: dest, from: url)
                transferCurrent = sent
                print("[files] uploaded \(name) (\(sent) bytes)")
            } catch {
                uploadError = VPhoneLocalization.format("Unable to upload “%@”. Check the connection, then try again.", name)
                break
            }
        }
        transferName = nil
        await refresh()
        // Set error after refresh so refresh() doesn't clear it before the alert fires.
        if let e = uploadError {
            error = e
        }
    }

    func createNewFolder(name: String) async {
        guard !files.contains(where: { $0.name == name }) else {
            error = VPhoneLocalization.format("An item named “%@” already exists. Choose a different name.", name)
            return
        }
        let path = (currentPath as NSString).appendingPathComponent(name)
        do {
            try await control.createDirectory(path: path)
            await refresh()
        } catch {
            self.error = VPhoneLocalization.format("Unable to create the folder “%@”. Check the connection, then try again.", name)
        }
    }

    func deleteSelected() async {
        let selected = files.filter { selection.contains($0.id) }
        for file in selected {
            do {
                try await control.deleteFile(path: file.path)
            } catch {
                self.error = VPhoneLocalization.format("Unable to delete “%@”. Check the connection, then try again.", file.name)
                return
            }
        }
        selection.removeAll()
        await refresh()
    }

    func renameFile(_ file: VPhoneRemoteFile, to newName: String) async {
        guard newName != file.name else { return }
        guard !files.contains(where: { $0.dir == file.dir && $0.name == newName }) else {
            error = VPhoneLocalization.format("An item named “%@” already exists. Choose a different name.", newName)
            return
        }
        let newPath = (file.dir as NSString).appendingPathComponent(newName)
        do {
            try await control.renameFile(from: file.path, to: newPath)
            await refresh()
        } catch {
            self.error = VPhoneLocalization.format("Unable to rename “%@”. Check the connection, then try again.", file.name)
        }
    }
}
