import Foundation
import Testing
@testable import VPhoneRestore

/// `parse_ecid` and `normalize_udid` from `scripts/pymobiledevice3_bridge.py`,
/// rejection for rejection. These strings come off users' shell histories and
/// out of `udid-prediction.txt`, so "accepts what the Python accepted" is the
/// only thing that makes the port invisible.
struct RestoreIdentityTests {
    // MARK: - Accepted

    @Test func absentECIDIsNotAnError() throws {
        let fromNil = try VPhoneRestoreIdentity.parseECID(nil)
        #expect(fromNil == nil)
        // Python's `if not value: return None` — "" is falsy, so it is "unset",
        // not "empty". The two are different errors downstream.
        let fromEmpty = try VPhoneRestoreIdentity.parseECID("")
        #expect(fromEmpty == nil)
    }

    @Test(arguments: [
        ("1234abcd", UInt64(0x1234_ABCD)),
        ("1234ABCD", UInt64(0x1234_ABCD)),
        ("0x1234abcd", UInt64(0x1234_ABCD)),
        ("0X1234ABCD", UInt64(0x1234_ABCD)),
        ("  0x00000001AABBCCDD  ", UInt64(0x0000_0001_AABB_CCDD)),
        ("0", UInt64(0)),
        ("ffffffffffffffff", UInt64.max),
    ])
    func hexWithOrWithoutPrefix(_ input: String, _ expected: UInt64) throws {
        let parsed = try VPhoneRestoreIdentity.parseECID(input)
        #expect(parsed == expected)
    }

    @Test func formatsAsSixteenUppercaseHexDigits() {
        #expect(VPhoneRestoreIdentity.formatECID(0x1234) == "0000000000001234")
        #expect(VPhoneRestoreIdentity.formatECID(0xAABB_CCDD_EEFF_0011) == "AABBCCDDEEFF0011")
        #expect(VPhoneRestoreIdentity.formatECID(0) == "0000000000000000")
    }

    @Test func roundTripsThroughTheFormattedForm() throws {
        let original: UInt64 = 0x0000_0001_1A2B_3C4D
        let reparsed = try VPhoneRestoreIdentity.parseECID(VPhoneRestoreIdentity.formatECID(original))
        #expect(reparsed == original)
    }

    // MARK: - Rejected

    @Test(arguments: ["   ", "\t", "0x", "0X", "  0x  "])
    func presentButWithoutDigits(_ input: String) {
        #expect(throws: VPhoneRestoreBackendError.ecidEmpty) {
            try VPhoneRestoreIdentity.parseECID(input)
        }
    }

    @Test(arguments: ["ghij", "12 34", "0x12g", "-1", "12.34", "0x0x12", "１２３４"])
    func nonHexIsRejectedAndReportedAsTyped(_ input: String) {
        // The payload is the ORIGINAL string, not the lower-cased,
        // prefix-stripped one — Python's `f"Invalid ECID: {value}"`.
        #expect(throws: VPhoneRestoreBackendError.ecidInvalid(input)) {
            try VPhoneRestoreIdentity.parseECID(input)
        }
    }

    @Test func seventeenHexDigitsDoNotFitAnECID() {
        // Python's ints are unbounded, so this is the one rejection the bridge
        // adds. Truncating silently would target a different device.
        #expect(throws: VPhoneRestoreBackendError.ecidTooLarge("00000000000000001")) {
            try VPhoneRestoreIdentity.parseECID("00000000000000001")
        }
        #expect(throws: VPhoneRestoreBackendError.ecidTooLarge("0xFFFFFFFFFFFFFFFFF")) {
            try VPhoneRestoreIdentity.parseECID("0xFFFFFFFFFFFFFFFFF")
        }
    }

    @Test func invalidECIDCarriesThePythonMessage() {
        #expect("\(VPhoneRestoreBackendError.ecidEmpty)" == "ECID is empty")
        #expect("\(VPhoneRestoreBackendError.ecidInvalid("zz"))" == "Invalid ECID: zz")
    }

    // MARK: - UDID

    @Test func udidIsTrimmedAndUpperCased() {
        // Not cosmetic: usbmuxd and udid-prediction.txt both report upper-case
        // hex, so a lower-case --udid would match nothing.
        #expect(VPhoneRestoreIdentity.normalizeUDID(" abcdef01-0001020304050607 ")
            == "ABCDEF01-0001020304050607")
        #expect(VPhoneRestoreIdentity.normalizeUDID("ABCDEF01-0001020304050607")
            == "ABCDEF01-0001020304050607")
    }

    @Test func absentOrEmptyUDIDMeansMatchAnyDevice() {
        #expect(VPhoneRestoreIdentity.normalizeUDID(nil) == nil)
        // Python kept "" and every call site then treated it as falsy; nil says
        // the same thing once, where it cannot be got wrong.
        #expect(VPhoneRestoreIdentity.normalizeUDID("") == nil)
        #expect(VPhoneRestoreIdentity.normalizeUDID("   ") == nil)
    }
}
