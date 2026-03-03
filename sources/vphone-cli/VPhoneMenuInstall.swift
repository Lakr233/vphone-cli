import AppKit
import UniformTypeIdentifiers

// MARK: - Install Menu

extension VPhoneMenuController {
    func buildInstallMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Install")
        menu.addItem(makeItem("Install Package (.ipa) [WIP]", action: #selector(installPackage)))
        menu.addItem(makeItem("Install Package with Resign (.ipa) [WIP]", action: #selector(installPackageResign)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Upload Binary to Guest", action: #selector(uploadBinary)))
        menu.addItem(makeItem("Upload Binary with Resign to Guest", action: #selector(uploadBinaryResign)))
        item.submenu = menu
        return item
    }

    // MARK: - IPA Install

    @objc func installPackage() {
        pickAndInstall(resign: false)
    }

    @objc func installPackageResign() {
        pickAndInstall(resign: true)
    }

    private func pickAndInstall(resign: Bool) {
        let panel = NSOpenPanel()
        panel.title = "Select IPA"
        panel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let installer = ipaInstaller else {
            showAlert(
                title: "Install Package",
                message: "IPA installer not available (bundled tools missing).",
                style: .warning
            )
            return
        }

        Task {
            do {
                try await installer.install(ipaURL: url, resign: resign)
                showAlert(
                    title: "Install Package",
                    message: "Successfully installed \(url.lastPathComponent).",
                    style: .informational
                )
            } catch {
                showAlert(
                    title: "Install Package",
                    message: "\(error)",
                    style: .warning
                )
            }
        }
    }

    // MARK: - Upload Binary

    @objc func uploadBinary() {
        pickAndUploadBinary(resign: false)
    }

    @objc func uploadBinaryResign() {
        pickAndUploadBinary(resign: true)
    }

    private func pickAndUploadBinary(resign: Bool) {
        let panel = NSOpenPanel()
        panel.title = "Select Binary to Upload"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                var data = try Data(contentsOf: url)

                if resign {
                    guard let signer else {
                        showAlert(
                            title: "Upload Binary",
                            message: "Signing tools not available (bundled tools missing).",
                            style: .warning
                        )
                        return
                    }
                    data = try await signer.resign(data: data, filename: url.lastPathComponent)
                }

                let filename = url.lastPathComponent
                let remotePath = "/var/root/Library/Caches/\(filename)"
                try await control.uploadFile(path: remotePath, data: data, permissions: "755")
                showAlert(
                    title: "Upload Binary",
                    message: "Uploaded \(filename) to \(remotePath) (\(data.count) bytes)\(resign ? " [resigned]" : "").",
                    style: .informational
                )
            } catch {
                showAlert(
                    title: "Upload Binary",
                    message: "\(error)",
                    style: .warning
                )
            }
        }
    }
}
