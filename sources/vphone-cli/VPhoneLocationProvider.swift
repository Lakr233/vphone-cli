import CoreLocation
import Foundation

/// Forwards the host Mac's location to the guest VM via vsock.
///
/// Uses macOS CoreLocation to track the Mac's real location and forwards
/// every update to the guest.  Call `startForwarding()` when the guest
/// reports "location" capability.  Safe to call multiple times (e.g.
/// after vphoned reconnects) - re-sends the last known position.
@MainActor
class VPhoneLocationProvider: NSObject {
    struct ReplayPoint {
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let horizontalAccuracy: Double
        let verticalAccuracy: Double
        let speed: Double
        let course: Double

        init(
            latitude: Double,
            longitude: Double,
            altitude: Double = 0,
            horizontalAccuracy: Double = 5,
            verticalAccuracy: Double = 8,
            speed: Double = 0,
            course: Double = -1
        ) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
            self.horizontalAccuracy = horizontalAccuracy
            self.verticalAccuracy = verticalAccuracy
            self.speed = speed
            self.course = course
        }
    }

    private let control: VPhoneControl
    private var hostModeStarted = false

    private var locationManager: CLLocationManager?
    private var delegateProxy: LocationDelegateProxy?
    private var lastLocation: CLLocation?
    private var replayTask: Task<Void, Never>?
    private var replayName: String?

    var isReplaying: Bool {
        replayTask != nil
    }

    init(control: VPhoneControl) {
        self.control = control
        super.init()

        let proxy = LocationDelegateProxy { [weak self] location in
            Task { @MainActor in
                self?.forward(location)
            }
        }
        delegateProxy = proxy
        let mgr = CLLocationManager()
        mgr.delegate = proxy
        mgr.desiredAccuracy = kCLLocationAccuracyBest
        locationManager = mgr
        print("[location] host location forwarding ready")
    }

    /// Begin sending location to the guest.  Safe to call on every (re)connect.
    func startForwarding() {
        stopReplay()
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

    /// Stop forwarding host location updates.
    func stopForwarding() {
        if hostModeStarted {
            locationManager?.stopUpdatingLocation()
            hostModeStarted = false
            print("[location] stopped host location tracking")
        }
    }

    /// Send a fixed simulated location to the guest.
    func sendPreset(name: String, latitude: Double, longitude: Double, altitude: Double = 0) {
        stopReplay()
        sendSimulatedLocation(
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: 8,
            speed: 0,
            course: -1
        )
        print("[location] applied preset '\(name)' (\(latitude), \(longitude))")
    }

    /// Start replaying a list of simulated locations at a fixed interval.
    func startReplay(
        name: String,
        points: [ReplayPoint],
        intervalSeconds: Double = 1.5,
        loop: Bool = true
    ) {
        guard !points.isEmpty else {
            print("[location] replay '\(name)' ignored: no points")
            return
        }

        stopForwarding()
        stopReplay()

        replayName = name
        let sleepNanos = UInt64((max(intervalSeconds, 0.1) * 1_000_000_000).rounded())
        print(
            "[location] starting replay '\(name)' (\(points.count) points, interval \(String(format: "%.1f", intervalSeconds))s, loop=\(loop))"
        )

        replayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.replayTask = nil
                self.replayName = nil
            }

            var index = 0
            while !Task.isCancelled {
                let point = points[index]
                sendSimulatedLocation(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    horizontalAccuracy: point.horizontalAccuracy,
                    verticalAccuracy: point.verticalAccuracy,
                    speed: point.speed,
                    course: point.course
                )

                index += 1
                if index >= points.count {
                    if loop {
                        index = 0
                    } else {
                        break
                    }
                }

                try? await Task.sleep(nanoseconds: sleepNanos)
            }

            if Task.isCancelled {
                print("[location] replay cancelled: \(name)")
            } else {
                print("[location] replay finished: \(name)")
            }
        }
    }

    /// Stop an active replay task.
    func stopReplay() {
        guard let replayTask else { return }
        replayTask.cancel()
        self.replayTask = nil
        if let replayName {
            print("[location] stopped replay: \(replayName)")
        }
        replayName = nil
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

    private func sendSimulatedLocation(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        speed: Double,
        course: Double
    ) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        lastLocation = CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            timestamp: Date()
        )

        guard control.isConnected else {
            print("[location] simulate: not connected, cached for later")
            return
        }

        control.sendLocation(
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            speed: speed,
            course: course
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
        let c = location.coordinate
        print(
            "[location] got location: \(String(format: "%.6f,%.6f", c.latitude, c.longitude)) (+/-\(String(format: "%.0f", location.horizontalAccuracy))m)"
        )
        handler(location)
    }

    func locationManager(_: CLLocationManager, didFailWithError error: any Error) {
        let clErr = (error as NSError).code
        // kCLErrorLocationUnknown (0) = transient, just waiting for fix
        if clErr == 0 { return }
        print("[location] CLLocationManager error: \(error.localizedDescription) (code \(clErr))")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        print("[location] authorization status: \(status.rawValue)")
        if status == .authorized || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}
