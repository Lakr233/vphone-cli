import Foundation

extension VPhoneGuestControl {
    /// Upload through the same HTTP path as Files, then create a PhotoKit asset.
    /// Keep `job` to query photos.status if the host disconnects or times out.
    /// Progress runs on the transfer queue; callers update UI on the main actor.
    func importMedia(
        localURL: URL,
        job: UUID = UUID(),
        progress: (@Sendable (_ phase: String, _ completed: Int, _ total: Int) -> Void)? = nil,
    ) async throws -> [String: Any] {
        guard guestCapabilities.contains("photos_import") else {
            throw ControlError.unsupportedCapability("photos_import")
        }
        let extensions = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "mov", "mp4", "m4v"]
        let values = try localURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 256 * 1024 * 1024,
              extensions.contains(localURL.pathExtension.lowercased())
        else { throw ControlError.guestError("Choose an image or video from 1 byte to 256 MiB.") }

        let id = job.uuidString
        let path = "/var/mobile/Media/vphone-photo-uploads/\(id)"
        do {
            // A retry with the same job must consult its receipt before uploading.
            var result = try await call("photos.status", params: ["job": id])
            if result["code"] as? String == "not_found" {
                progress?("upload", 0, size)
                let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
                try await uploadFile(path: path, data: data) { sent, total in
                    progress?("upload", sent, total)
                }
                result = try await call("photos.import", params: [
                    "job": id, "path": path, "name": localURL.lastPathComponent,
                ])
            } else if let filename = result["filename"] as? String,
                      filename != localURL.lastPathComponent || result["bytes"] as? Int != size
            {
                throw ControlError.guestError("This job already belongs to another media file.")
            }
            let deadline = ContinuousClock.now + .seconds(330)
            while true {
                if result["ok"] as? Bool == false {
                    throw ControlError.guestError(result["error"] as? String ?? "Photos import failed")
                }
                if result["complete"] as? Bool == true {
                    guard result["ok"] as? Bool == true else {
                        throw ControlError.protocolError("Photos receipt has no outcome")
                    }
                    progress?("complete", size, size)
                    return result
                }
                guard ContinuousClock.now < deadline else {
                    throw ControlError.guestError("Photos import is still pending.")
                }
                progress?("import", size, size)
                try await Task.sleep(for: .seconds(1))
                result = try await call("photos.status", params: ["job": id])
            }
        } catch {
            // The RPC may have committed even if its reply was lost.
            throw ControlError.guestError("\(error.localizedDescription) Query photos.status with job \(id) before starting a new import.")
        }
    }
}
