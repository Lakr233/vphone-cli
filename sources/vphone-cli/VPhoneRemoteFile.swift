import Foundation

struct VPhoneRemoteFile: Identifiable, Hashable {
    let dir: String
    let name: String
    let type: FileType
    let size: UInt64
    let permissions: String
    let modified: Date

    var id: String { path }
    var path: String { (dir as NSString).appendingPathComponent(name) }
    var isDirectory: Bool { type == .directory }
    var isSymbolicLink: Bool { type == .symbolicLink }

    var displaySize: String {
        if isDirectory || isSymbolicLink { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var displayDate: String {
        Self.dateFormatter.string(from: modified)
    }

    var icon: String {
        switch type {
        case .directory: "folder.fill"
        case .symbolicLink: "link"
        case .file: fileIcon(for: name)
        }
    }

    enum FileType: String, Hashable {
        case file
        case directory = "dir"
        case symbolicLink = "link"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic":
            return "photo"
        case "mov", "mp4", "m4v":
            return "film"
        case "txt", "md", "log":
            return "doc.text"
        case "plist", "json", "xml", "yaml":
            return "doc.badge.gearshape"
        case "dylib", "framework":
            return "shippingbox"
        case "app":
            return "app.dashed"
        default:
            return "doc"
        }
    }
}

extension VPhoneRemoteFile {
    /// Parse from the dict returned by vphoned file_list entries.
    init?(dir: String, entry: [String: Any]) {
        guard let name = entry["name"] as? String,
              let typeStr = entry["type"] as? String,
              let type = FileType(rawValue: typeStr)
        else { return nil }

        self.dir = dir
        self.name = name
        self.type = type
        self.size = (entry["size"] as? NSNumber)?.uint64Value ?? 0
        self.permissions = entry["perm"] as? String ?? "---"
        self.modified = Date(timeIntervalSince1970: (entry["mtime"] as? Double) ?? 0)
    }
}
