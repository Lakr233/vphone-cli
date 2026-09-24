import Foundation
import UniformTypeIdentifiers

/// What counts as an installable package. This lives in the shared layer
/// because both sides need the same answer: `vphone-cli` rejects a bad
/// `--install-ipa` before it launches anything, and `vphone-vm` applies the
/// same rule to a file dropped on the VM window.
public enum VPhoneInstallPackage {
    public static let allowedContentTypes: [UTType] = [
        UTType(filenameExtension: "ipa"),
        UTType(filenameExtension: "tipa"),
    ].compactMap(\.self)

    public static func isSupportedFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "ipa", "tipa":
            true
        default:
            false
        }
    }

    public static func successMessage(for fileName: String, detail: String) -> String {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDetail.isEmpty else {
            return "Installed \(fileName)."
        }
        if trimmedDetail.localizedCaseInsensitiveContains(fileName) {
            return trimmedDetail
        }
        return "Installed \(fileName).\n\n\(trimmedDetail)"
    }
}
