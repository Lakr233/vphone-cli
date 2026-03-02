import CoreLocation
import Foundation

/// Forwards the host Mac's location to the guest VM via vsock.
///
/// Uses macOS CoreLocation to track the Mac's real location and forwards
/// every update to the guest.  Call `startForwarding()` when the guest
/// reports "location" capability.  Safe to call multiple times (e.g.
/// after vphoned reconnects) — re-sends the last known position.
@MainActor
class VPhoneLocationProvider: NSObject {
    private let control: VPhoneControl
    private var hostModeStarted = false

    private var locationManager: CLLocationManager?
    private var delegateProxy: LocationDelegateProxy?
    private var lastLocation: CLLocation?

    init(control: VPhoneControl) {
        self.control = control
        super.init()

        let proxy = LocationDelegateProxy { [weak self] location in
            Task { @MainActor in
                self?.forward(location)
            }
        }
        self.delegateProxy = proxy
        let mgr = CLLocationManager()
        mgr.delegate = proxy
        mgr.desiredAccuracy = kCLLocationAccuracyBest
        self.locationManager = mgr
        print("[location] host location forwarding ready")
    }

    /// Begin sending location to the guest.  Safe to call on every (re)connect.
    func startForwarding() {
        guard let mgr = locationManager else { return }
        mgr.requestAlwaysAuthorization()
        mgr.startUpdatingLocation()
        hostModeStarted = true
        print("[location] started host location tracking")
        // Re-send last known location immediately on reconnect
        if let last = lastLocation {
            forward(last)
            print("[location] re-sent last known host location")
        }
    }

    /// Stop forwarding and clear the simulated location in the guest.
    func stopForwarding() {
        if hostModeStarted {
            locationManager?.stopUpdatingLocation()
            hostModeStarted = false
            print("[location] stopped host location tracking")
        }
    }

    private func forward(_ location: CLLocation) {
        lastLocation = location
        guard control.isConnected else {
            print("[location] forward: not connected, cached for later")
            return
        }
        control.sendLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            course: location.course
        )
    }
}

// MARK: - CLLocationManagerDelegate Proxy

/// Separate object to avoid @MainActor vs nonisolated delegate conflicts.
private class LocationDelegateProxy: NSObject, CLLocationManagerDelegate {
    let handler: (CLLocation) -> Void

    init(handler: @escaping (CLLocation) -> Void) {
        self.handler = handler
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        NSLog("[location] got location: %.6f,%.6f (±%.0fm)",
              location.coordinate.latitude, location.coordinate.longitude,
              location.horizontalAccuracy)
        handler(location)
    }

    func locationManager(_: CLLocationManager, didFailWithError error: any Error) {
        let clErr = (error as NSError).code
        // kCLErrorLocationUnknown (0) = transient, just waiting for fix
        if clErr == 0 { return }
        NSLog("[location] CLLocationManager error: %@ (code %ld)", error.localizedDescription, clErr)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        NSLog("[location] authorization status: %d", status.rawValue)
        if status == .authorized || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}
