import Foundation
import Testing
@testable import VPhoneRestore

/// The values that cross the C boundary in the other direction: log levels,
/// restore steps and USB modes. Each one is a number the C side chose, so each
/// one is a place where a renumbered enum would go unnoticed.
struct RestoreEventTests {
    // MARK: - Log levels

    @Test func levelsMatchIdevicerestoresEnum() {
        // src/log.h: LL_ERROR = 0 … LL_DEBUG = 5. Lower is more severe.
        #expect(VPhoneRestoreLogLevel.error.rawValue == 0)
        #expect(VPhoneRestoreLogLevel.warning.rawValue == 1)
        #expect(VPhoneRestoreLogLevel.notice.rawValue == 2)
        #expect(VPhoneRestoreLogLevel.info.rawValue == 3)
        #expect(VPhoneRestoreLogLevel.verbose.rawValue == 4)
        #expect(VPhoneRestoreLogLevel.debug.rawValue == 5)
    }

    @Test func severityOrdersTheOtherWayRound() {
        #expect(VPhoneRestoreLogLevel.error < VPhoneRestoreLogLevel.info)
        #expect(VPhoneRestoreLogLevel.info < VPhoneRestoreLogLevel.debug)
        // Which is what the console sink's `messageLevel <= level` relies on:
        // asking for `.info` must let errors through, not filter them out.
        #expect(VPhoneRestoreLogLevel.error <= VPhoneRestoreLogLevel.info)
        #expect(!(VPhoneRestoreLogLevel.debug <= VPhoneRestoreLogLevel.info))
    }

    @Test(arguments: [Int32(-1), 6, 99])
    func anUnknownLevelBecomesInfo(_ raw: Int32) {
        // Rather than dropping the line, which is the one outcome nobody can
        // debug.
        #expect(VPhoneRestoreLogLevel(clamping: raw) == .info)
    }

    @Test func aKnownLevelSurvivesClamping() {
        for level in VPhoneRestoreLogLevel.allCases {
            #expect(VPhoneRestoreLogLevel(clamping: level.rawValue) == level)
        }
    }

    // MARK: - Steps

    @Test func stepsCarryTheCSideNames() {
        // vphone_restore_step_name(), so a renumbered RESTORE_STEP_* shows up
        // here rather than in a user's log.
        #expect(VPhoneRestoreStep.detect.name == "detect")
        #expect(VPhoneRestoreStep.prepare.name == "prepare")
        #expect(VPhoneRestoreStep.uploadFilesystem.name == "upload filesystem")
        #expect(VPhoneRestoreStep.verifyFilesystem.name == "verify filesystem")
        #expect(VPhoneRestoreStep.flashFirmware.name == "flash firmware")
        #expect(VPhoneRestoreStep.flashBaseband.name == "flash baseband")
        #expect(VPhoneRestoreStep.flashFUD.name == "flash FUD")
        #expect(VPhoneRestoreStep.uploadImage.name == "upload image")
    }

    @Test func theStepsAreNumberedZeroUpwards() {
        let ordered: [VPhoneRestoreStep] = [
            .detect, .prepare, .uploadFilesystem, .verifyFilesystem,
            .flashFirmware, .flashBaseband, .flashFUD, .uploadImage,
        ]
        #expect(ordered.map(\.rawValue) == Array(Int32(0)...Int32(7)))
    }

    @Test func anUnknownStepStillRoundTrips() {
        let step = VPhoneRestoreStep(rawValue: 42)
        #expect(step.rawValue == 42)
        #expect(step.name == "unknown")
    }

    // MARK: - Recovery modes

    @Test func onlyTheFourRecoveryProductIDsCountAsRecovery() {
        // pymobiledevice3's `Mode.is_recovery`: everything that is not WTF and
        // not DFU. The probe's --is-recovery filter is this predicate.
        #expect(VPhoneRecoveryMode.recovery1.isRecovery)
        #expect(VPhoneRecoveryMode.recovery2.isRecovery)
        #expect(VPhoneRecoveryMode.recovery3.isRecovery)
        #expect(VPhoneRecoveryMode.recovery4.isRecovery)
        #expect(!VPhoneRecoveryMode.dfu.isRecovery)
        #expect(!VPhoneRecoveryMode.wtf.isRecovery)
        // Port DFU is not in pymobiledevice3's enum at all; it is a DFU
        // variant, so it answers the same way DFU does.
        #expect(!VPhoneRecoveryMode.portDFU.isRecovery)
    }

    @Test func modesMatchLibirecoverysProductIDs() {
        #expect(VPhoneRecoveryMode.recovery1.rawValue == 0x1280)
        #expect(VPhoneRecoveryMode.recovery4.rawValue == 0x1283)
        #expect(VPhoneRecoveryMode.wtf.rawValue == 0x1222)
        #expect(VPhoneRecoveryMode.dfu.rawValue == 0x1227)
        #expect(VPhoneRecoveryMode.portDFU.rawValue == 0xF014)
    }

    @Test func anUnknownModeIsReportableAndNotRecovery() {
        let mode = VPhoneRecoveryMode(rawValue: 0x1234)
        #expect(!mode.isRecovery)
        #expect(mode.description == "mode 0x1234")
    }

    @Test func modesDescribeThemselves() {
        #expect(VPhoneRecoveryMode.recovery3.description == "recovery")
        #expect(VPhoneRecoveryMode.dfu.description == "DFU")
        #expect(VPhoneRecoveryMode.portDFU.description == "port DFU")
    }

    // MARK: - Timeout message

    @Test func aProbeWithAPastDeadlineGivesUpWithoutHanging() {
        // Python's `while time.monotonic() < deadline` never ran the body when
        // the timeout was zero, and neither does this — which is what makes it
        // safe for `vm create` to call it ninety times in a row.
        #expect(throws: VPhoneRestoreBackendError.recoveryProbeTimedOut(mode: "dfu/recovery")) {
            try VPhoneRecoveryProbe.probe(ecid: 0x1122_3344, timeout: 0)
        }
        #expect(throws: VPhoneRestoreBackendError.recoveryProbeTimedOut(mode: "recovery")) {
            try VPhoneRecoveryProbe.probe(ecid: nil, timeout: -5, isRecovery: true)
        }
        // Python's `mode_label` said "dfu/recovery" for False as well as for
        // None; keeping that means the message users grep for is unchanged.
        #expect(throws: VPhoneRestoreBackendError.recoveryProbeTimedOut(mode: "dfu/recovery")) {
            try VPhoneRecoveryProbe.probe(ecid: nil, timeout: 0, isRecovery: false)
        }
    }

    @Test func theTimeoutMessageIsThePythonsWordForWord() {
        let error = VPhoneRestoreBackendError.recoveryProbeTimedOut(mode: "dfu/recovery")
        #expect("\(error)" == "Timed out waiting for dfu/recovery endpoint")
    }

    // MARK: - Error messages

    @Test func theRestoreTreeMessagesAreThePythonsWordForWord() {
        let none = VPhoneRestoreBackendError.noRestoreDirectory(URL(fileURLWithPath: "/tmp/vm"))
        #expect("\(none)" == "No iPhone*_Restore directory found in /tmp/vm")
        let several = VPhoneRestoreBackendError.multipleRestoreDirectories(["a", "b"])
        #expect("\(several)"
            == "Multiple iPhone*_Restore directories found; keep only one active restore tree")
    }
}
