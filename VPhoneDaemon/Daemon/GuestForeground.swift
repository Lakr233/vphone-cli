import Darwin
import Foundation
import IcliKit
import VphonedNative

enum GuestForeground {
    static func current() -> [String: Any] {
        let reported = frontmostApp()["bundle_id"] as? String ?? "com.apple.springboard"
        let isSpringBoard = reported == "com.apple.springboard" || reported == "com.apple.springboardeducation"
        guard isSpringBoard else {
            return ["bundle_id": reported, "verified": true, "source": "springboard"]
        }

        let screen = screenInfo()
        guard screen["locked"] as? Bool != true, screen["screen_off"] as? Bool != true,
              let focal = vp_runningboard_focal_bundle_id() else {
            return ["bundle_id": reported, "verified": false, "source": "springboard"]
        }
        defer { free(focal) }
        return ["bundle_id": String(cString: focal), "verified": true, "source": "runningboard"]
    }
}
