import Foundation
import VphonedNative

/// Folds and turns an iPhone Duo guest as Xcode's DeviceHub asks
/// (vphoned_devicehub.m decodes its controls). A closed / book / open button
/// animates DeviceHub's hinge from the current angle to the target, sending a
/// value every frame, and DeviceHub then waits for the device's hinge to
/// agree. With CoreMotion's relay, locationd takes those values itself and
/// the virtual hinge follows them. Without it SpringBoard folds itself in one
/// sweep, so a run of values is folded once it settles, to where it ended.
/// The orientation picker sets the device orientation. Both go through the
/// paths `display.posture` uses, so the host window, which polls the fold
/// angle, follows too.
enum GuestDeviceHubControl {
    private final class Pending: @unchecked Sendable {
        /// Owned by `queue`.
        var generation = 0
    }

    private static let pending = Pending()
    private static let queue = DispatchQueue(label: "vphoned.devicehub-fold", qos: .userInitiated)
    private static let wake = DispatchQueue(label: "vphoned.devicehub-wake", qos: .userInitiated)
    /// Longer than DeviceHub's frame interval, short enough to feel direct.
    private static let settle: DispatchTimeInterval = .milliseconds(200)
    /// Apple's DeviceOrientation names, as the picker sends them.
    private static let orientations: [String: Int32] = [
        "portrait": 1, "portraitUpsideDown": 2, "landscapeLeft": 3, "landscapeRight": 4, "faceUp": 5, "faceDown": 6,
    ]

    static func startOnStartup() {
        guard vp_devicehub_controls_start({ control in handle(control) }) else { return }
        NSLog("vphoned: following DeviceHub's fold controls")
    }

    private static func handle(_ control: [AnyHashable: Any]) {
        let value = control["value"]
        switch control["source"] as? String {
        case "hinge-slider-control":
            guard let angle = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init),
                  angle.isFinite
            else { return }
            let reading = min(max(angle, 0), 180)
            if vp_core_motion_hinge() {
                follow(reading)
                return
            }
            // DeviceHub draws a closed or open hinge state at 0 or 180 degrees
            // whatever its own animation shows, so a reading still at the old
            // pose pulled its model back there between the end of the run and
            // the fold. The reading follows the run; the fold then sets the
            // hinge to where it ended, or back if it does not run.
            vp_hinge_reading_publish(reading, Int32(GuestAPI.hingeState(for: reading)))
            queue.async {
                pending.generation &+= 1
                let generation = pending.generation
                queue.asyncAfter(deadline: .now() + settle) {
                    guard pending.generation == generation else { return }
                    do {
                        try GuestAPI.foldFromDeviceHub(angle: reading)
                    } catch {
                        NSLog("vphoned: DeviceHub fold to %.0f° failed: %@", reading, "\(error)")
                        if let held = (vp_hinge_get()["angle"] as? NSNumber)?.doubleValue {
                            vp_hinge_reading_publish(held, Int32(GuestAPI.hingeState(for: held)))
                        }
                    }
                }
            }
        case "orientation-picker-control":
            guard let name = value as? String, let orientation = orientations[name] else { return }
            queue.async {
                do {
                    try GuestAPI.orientFromDeviceHub(orientation)
                } catch {
                    NSLog("vphoned: DeviceHub orientation %@ failed: %@", name, "\(error)")
                }
            }
        default:
            break
        }
    }

    /// locationd's relay takes DeviceHub's controls itself (dtuhidd's
    /// avpCustom service carries the host controls' usage), as on Apple's VM
    /// host, so the guest follows the slider as it moves. The virtual hinge,
    /// which resends its stored angle every few seconds for a restarted
    /// locationd, stores each value too, quietly: a resend of the old angle
    /// in the middle of a run sent the fold back, and sending each value
    /// again reached the relay late, after DeviceHub's own, and swung the
    /// hinge back and forth across the swap. Opening from closed lights the
    /// screen first, as `display.posture` does: SpringBoard's pose provider
    /// commits a moving pose only on display frames, and a sleeping cover
    /// left the inner display black.
    private static func follow(_ angle: Double) {
        if let held = (vp_hinge_get()["angle"] as? NSNumber)?.doubleValue,
           GuestAPI.hingeState(for: held) == 1, GuestAPI.hingeState(for: angle) != 1 {
            wake.async { GuestScreenUnlock.wakeDisplay() }
        }
        _ = vp_hinge_note(angle)
    }
}
