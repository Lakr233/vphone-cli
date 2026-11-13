import Foundation

// MARK: - Files App

extension GuestAPI {
    static let filesAppGroup = "group.com.apple.FileProvider.LocalStorage"
    static let filesAppDropFolder = "vphone-drop"

    /// The folder the Files app shows as On My iPhone: `File Provider Storage`
    /// in the LocalStorage app group, whose container UUID differs per device.
    static func filesAppRoot() throws -> String {
        let groups = "/var/mobile/Containers/Shared/AppGroup"
        for name in try FileManager.default.contentsOfDirectory(atPath: groups) {
            let container = groups + "/" + name
            let metadata = NSDictionary(
                contentsOfFile: container + "/.com.apple.mobile_container_manager.metadata.plist",
            )
            if metadata?["MCMMetadataIdentifier"] as? String == filesAppGroup {
                return container + "/File Provider Storage"
            }
        }
        throw GuestAPIError.notFound("Files app storage not found. Open Files once and try again.")
    }

    /// Moves an uploaded file into On My iPhone › vphone-drop. Items there are
    /// shown by the Files app at once when they look like the ones it creates:
    /// owned by mobile, folders 755 and files 644, no extended attributes. A
    /// name already taken is kept; the new file gets " 2", " 3", … before its
    /// extension.
    static func saveToFilesApp(_ source: String, name: String) throws -> [String: Any] {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw GuestAPIError.invalidRequest("name must be a single file name", hint: "Use a non-empty name without slashes, not . or ..")
        }
        let manager = FileManager.default
        let root = try filesAppRoot()
        let directory = root + "/" + filesAppDropFolder
        let mobile: [FileAttributeKey: Any] = [.ownerAccountID: 501, .groupOwnerAccountID: 501]
        for path in [root, directory] where !manager.fileExists(atPath: path) {
            var attributes = mobile
            attributes[.posixPermissions] = 0o755
            try manager.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: attributes)
        }

        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while manager.fileExists(atPath: directory + "/" + candidate) {
            candidate = suffix.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(suffix)"
            number += 1
        }
        let destination = directory + "/" + candidate
        try manager.moveItem(atPath: source, toPath: destination)
        var attributes = mobile
        attributes[.posixPermissions] = 0o644
        try manager.setAttributes(attributes, ofItemAtPath: destination)
        return ["path": destination, "name": candidate, "folder": filesAppDropFolder]
    }
}
