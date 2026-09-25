import Darwin
import Foundation
import IcliKit

/// Publishes one location for the app-side CoreLocation bridge. The VM's
/// locationd accepts simulation commands but can fail to deliver a fused fix.
enum GuestLocationSimulation {
    static let path = "/var/mobile/Library/Caches/vphone-location.json"
    private static let backend = LocationDaemonBackend()

    struct Point: Sendable {
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let horizontalAccuracy: Double
        let verticalAccuracy: Double
        let speed: Double
        let course: Double

        var json: [String: Double] {
            [
                "latitude": latitude, "longitude": longitude, "altitude": altitude,
                "horizontal_accuracy": horizontalAccuracy, "vertical_accuracy": verticalAccuracy,
                "speed": speed, "course": course,
            ]
        }
    }

    static func set(_ point: Point) throws -> [String: Any] {
        guard point.latitude.isFinite, (-90 ... 90).contains(point.latitude),
              point.longitude.isFinite, (-180 ... 180).contains(point.longitude),
              point.altitude.isFinite, point.horizontalAccuracy.isFinite, point.horizontalAccuracy >= 0,
              point.verticalAccuracy.isFinite, point.verticalAccuracy >= 0,
              point.speed.isFinite, point.course.isFinite
        else { throw GuestAPIError.invalidRequest("invalid location coordinates or accuracy") }

        let data = try JSONSerialization.data(withJSONObject: point.json)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
        )
        try writeAtomically(data)
        backend.set(point)
        return ["simulating": true, "delivery": "application_override", "location": point.json]
    }

    static func clear() throws -> [String: Any] {
        guard unlink(path) == 0 || errno == ENOENT else {
            throw GuestAPIError.operationFailed("could not clear simulated location: \(String(cString: strerror(errno)))")
        }
        backend.clear()
        return ["simulating": false]
    }

    static func current(timeout: Double) throws -> [String: Any] {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
        {
            var result: [String: Any] = state
            result["simulated"] = true
            result["delivery"] = "application_override"
            return result
        }
        return try currentLocation(timeout: timeout)
    }

    private static func writeAtomically(_ data: Data) throws {
        let temporary = path + "." + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw GuestAPIError.operationFailed("could not open simulated location: \(String(cString: strerror(errno)))")
        }
        var openFD = fd
        defer {
            if openFD >= 0 { close(openFD) }
            unlink(temporary)
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base.advanced(by: offset), buffer.count - offset)
                guard written > 0 else {
                    throw GuestAPIError.operationFailed("could not write simulated location: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
        guard fchmod(fd, 0o644) == 0, close(fd) == 0 else {
            openFD = -1
            throw GuestAPIError.operationFailed("could not finish simulated location: \(String(cString: strerror(errno)))")
        }
        openFD = -1
        guard rename(temporary, path) == 0 else {
            throw GuestAPIError.operationFailed("could not publish simulated location: \(String(cString: strerror(errno)))")
        }
    }
}

/// Best-effort system simulation remains useful on guests whose locationd
/// publishes a fix. It cannot block application updates or route replay.
private final class LocationDaemonBackend: @unchecked Sendable {
    private let queue = DispatchQueue(label: "vphoned.location.simulation")
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func set(_ point: GuestLocationSimulation.Point) {
        lock.lock()
        generation &+= 1
        let submitted = generation
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let current = generation == submitted
            lock.unlock()
            guard current else { return }
            do {
                _ = try simulateLocation(
                    latitude: point.latitude, longitude: point.longitude,
                    altitude: point.altitude, horizontalAccuracy: point.horizontalAccuracy,
                    verticalAccuracy: point.verticalAccuracy,
                    speed: point.speed >= 0 ? point.speed : nil,
                    course: point.course >= 0 ? point.course : nil,
                )
            } catch {
                NSLog("[location] system simulation unavailable: %@", String(describing: error))
            }
        }
    }

    func clear() {
        lock.lock()
        generation &+= 1
        lock.unlock()
        queue.async { _ = try? clearSimulatedLocation() }
    }
}
