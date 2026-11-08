import CoreLocation
import Foundation
import ObjectiveC

extension GuestAPI {
    /// The guest's Location Services switch as locationd reports it.
    static func locationServices() -> [String: Any] {
        let enabled: Bool = CLLocationManager.locationServicesEnabled()
        return ["enabled": enabled]
    }

    /// Turns the guest's Location Services switch on or off through
    /// `+[CLLocationManager setLocationServicesEnabled:]` (needs
    /// `com.apple.locationd.authorizeapplications`) and returns the state
    /// read back, failing when it does not reach `enabled` within 2 s.
    static func setLocationServices(_ enabled: Bool) throws -> [String: Any] {
        let selector = NSSelectorFromString("setLocationServicesEnabled:")
        guard let method = class_getClassMethod(CLLocationManager.self, selector) else {
            throw GuestAPIError.operationFailed("setLocationServicesEnabled: unavailable")
        }
        typealias Setter = @convention(c) (AnyClass, Selector, Bool) -> Void
        let setter = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        setter(CLLocationManager.self, selector, enabled)
        var state: Bool = CLLocationManager.locationServicesEnabled()
        for _ in 0 ..< 20 where state != enabled {
            Thread.sleep(forTimeInterval: 0.1)
            state = CLLocationManager.locationServicesEnabled()
        }
        guard state == enabled else {
            throw GuestAPIError.operationFailed("Location Services did not change to \(enabled) (now \(state))")
        }
        return ["enabled": state]
    }
}
