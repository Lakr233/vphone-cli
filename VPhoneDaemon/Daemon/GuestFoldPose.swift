import Foundation
import notify
import VphonedNative

/// Re-applies a foldable guest's saved posture after each boot.
///
/// The posture `display.posture` sets rides two channels: SpringBoard's
/// test-automation pose override — state of the running SpringBoard, gone
/// with it at shutdown — and the virtual hinge preference, which survives
/// but is only read when the provider enumerates. A rebooted guest that had
/// the pose open therefore starts with the hinge reporting open while
/// SpringBoard still holds its default pose, until the pose is set again.
/// Retry until SpringBoard reports the restored hinge state, but cancel
/// immediately when an explicit request supersedes the boot snapshot. A
/// SpringBoard restart drops the override too, so the latest pose is
/// replayed after each SpringBoard startup.
///
/// Only a guest whose hinge was configured is touched. See
/// Research/Guest/iphone_duo_bringup.md.
enum GuestFoldPose {
    private final class RestoreState: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        var generation: UInt64 = 0
        var explicitRequest = false
        var latestPose: [Int32]?
        var observerInstalled = false
    }

    private static let restoration = RestoreState()

    /// A new explicit request supersedes the boot snapshot. Serialize this
    /// with publication so an in-flight retry cannot overwrite the request.
    static func cancelStartupRestore() {
        restoration.lock.withLock {
            restoration.cancelled = true
            restoration.generation &+= 1
            restoration.explicitRequest = true
        }
    }

    /// Capture the actual final state, including a failed request's rollback.
    /// Never retain the requested value as proof that SpringBoard applied it.
    /// The one exception is `settledHinge`, the hinge state of a fold
    /// SpringBoard itself reported finished: the pose readback does not follow
    /// SpringBoard's own sweeps (it kept reading open-flat after a sweep to
    /// closed), so the hinge comes from the request there.
    static func finishExplicitRequest(settledHinge: Int32? = nil) {
        restoration.lock.withLock {
            let actual = vp_device_pose_get()
            restoration.latestPose = poseValues(actual, hinge: settledHinge)
            restoration.explicitRequest = false
            restoration.generation &+= 1
        }
    }

    private static func poseValues(_ actual: [String: Any], hinge settled: Int32? = nil) -> [Int32]? {
        guard actual["available"] as? Bool == true,
              let orientation = actual["device_orientation"] as? Int32,
              let hinge = settled ?? actual["hinge"] as? Int32,
              let tabletop = actual["tabletop"] as? Int32,
              (1...4).contains(orientation), (1...4).contains(hinge)
        else { return nil }
        return [orientation, hinge, tabletop]
    }

    private static let restoreQueue = DispatchQueue(label: "vphoned.fold-pose-replay", qos: .utility)

    private static func observeSpringBoardStartup() {
        let install = restoration.lock.withLock {
            if restoration.observerInstalled { return false }
            restoration.observerInstalled = true
            return true
        }
        guard install else { return }
        var token: Int32 = 0
        let status = notify_register_dispatch("com.apple.springboard.finishedstartup", &token, restoreQueue) { _ in
            let generation = restoration.lock.withLock { restoration.generation }
            for delay in [0.5, 1.5, 3.0] {
                restoreQueue.asyncAfter(deadline: .now() + delay) {
                    restoration.lock.withLock {
                        guard restoration.generation == generation, !restoration.explicitRequest,
                              let pose = restoration.latestPose,
                              vp_hinge_get()["enabled"] as? Bool == true,
                              poseValues(vp_device_pose_get()) != pose else { return }
                        _ = vp_device_pose_set(pose[0], pose[1], pose[2])
                        NSLog("vphoned: replay latest fold pose after SpringBoard startup")
                    }
                }
            }
        }
        if status != 0 {
            NSLog("vphoned: cannot observe SpringBoard pose lifecycle: %u", status)
        }
    }

    /// SpringBoard is up well inside this on a normal boot; a first boot
    /// after a restore takes longer, and the later attempts cover it. The
    /// setter reports only submission, so read the actual pose before
    /// deciding whether another retry is needed.
    private static let attemptDelays: [TimeInterval] = [8, 12, 15, 20, 30, 45, 60, 90]

    static func startOnStartup() {
        let hinge = vp_hinge_get()
        guard hinge["enabled"] as? Bool == true, let angle = hinge["angle"] as? Double else { return }
        // With CoreMotion's relay the hinge provider hands locationd the
        // stored angle and orientation itself, and SpringBoard reads the pose
        // from CoreMotion: there is no override to restore.
        if vp_core_motion_hinge() {
            NSLog("vphoned: fold pose at %.0f° comes through CoreMotion's relay", angle)
            return
        }
        observeSpringBoardStartup()
        NSLog("vphoned: fold pose restore: %.0f° over the boot ladder", angle)
        let expectedHinge = GuestAPI.hingeState(for: angle)
        DispatchQueue.global(qos: .utility).async {
            var waited: TimeInterval = 0
            for delay in attemptDelays {
                Thread.sleep(forTimeInterval: delay - waited)
                waited = delay
                let published = restoration.lock.withLock {
                    guard !restoration.cancelled else { return false }
                    _ = vp_device_pose_set(1, Int32(expectedHinge), 0)
                    _ = vp_hinge_set(angle, 0)
                    restoration.latestPose = poseValues(vp_device_pose_get())
                    return true
                }
                guard published else { return }
                let actual = vp_device_pose_get()
                if actual["available"] as? Bool == true, actual["device_orientation"] as? Int == 1, actual["hinge"] as? Int == expectedHinge { return }
            }
        }
    }
}
