import Foundation
import UniformTypeIdentifiers

enum VPhoneInstallPackage {
    static let allowedContentTypes: [UTType] = [
        UTType(filenameExtension: "ipa"),
        UTType(filenameExtension: "tipa"),
    ].compactMap { $0 }

    static func isSupportedFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "ipa", "tipa":
            true
        default:
            false
        }
    }

    static func successMessage(for fileName: String, detail: String) -> String {
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
