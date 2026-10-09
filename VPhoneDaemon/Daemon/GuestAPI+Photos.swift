import Foundation
import VphonedNative

extension GuestAPI {
    static func executePhotos(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "photos.import":
            return try vp_photos_import(
                string(params, "job"), string(params, "path"), string(params, "name"),
            ) as? [String: Any]
        case "photos.status":
            return try vp_photos_status(string(params, "job")) as? [String: Any]
        default:
            return nil
        }
    }
}
