@testable import FirmwarePatcher
import Foundation
import Testing

/// Identity selection for the hybrid manifest.
///
/// `FirmwareManifest.generate()` was translated from `scripts/fw_manifest.py`
/// some time ago and then never called, so its equivalence was unknown until
/// it was run. It has now been checked against the Python on a real pair —
/// cloudOS 26.4-23E5207q and iPhone 27.0-24A435 — and produced semantically
/// identical BuildManifest.plist and Restore.plist, down to the picked
/// identity indices.
///
/// That is one build pair. What breaks on a different one is the *selection*:
/// which identity counts as research, which as release, which as the erase
/// identity. Those are pure functions over a build identity, so they can be
/// pinned here without a firmware image, which is what these do.
@Suite("Hybrid manifest identity selection")
struct FirmwareManifestSelectionTests {
    // MARK: - Fixtures

    static func identity(
        deviceClass: String,
        variant: String = "Customer Erase Install (IPSW)",
        llbPath: String? = nil,
    ) -> PlistDict {
        var manifest = PlistDict()
        if let llbPath {
            manifest["LLB"] = ["Info": ["Path": llbPath] as PlistDict] as PlistDict
        }
        return [
            "Info": [
                "DeviceClass": deviceClass,
                "Variant": variant,
            ] as PlistDict,
            "Manifest": manifest,
        ]
    }

    // MARK: - isResearch

    @Test
    func `a four-part LLB filename with RESEARCH in field 3 marks a research identity`() {
        // Firmware/all_flash/LLB.vresearch101.RESEARCH.im4p -> 4 dot-separated
        // parts, and the third says RESEARCH.
        let bi = Self.identity(
            deviceClass: "vresearch101ap",
            llbPath: "Firmware/all_flash/LLB.vresearch101.RESEARCH.im4p",
        )
        #expect(FirmwareManifest.isResearch(bi))
    }

    @Test
    func `the same filename shape with RELEASE does not`() {
        let bi = Self.identity(
            deviceClass: "vresearch101ap",
            llbPath: "Firmware/all_flash/LLB.vresearch101.RELEASE.im4p",
        )
        #expect(!FirmwareManifest.isResearch(bi))
    }

    @Test
    func `with no usable path, the Variant string decides`() {
        #expect(FirmwareManifest.isResearch(
            Self.identity(deviceClass: "vresearch101ap", variant: "Research Erase Install (IPSW)"),
        ))
        #expect(!FirmwareManifest.isResearch(
            Self.identity(deviceClass: "vresearch101ap", variant: "Customer Erase Install (IPSW)"),
        ))
    }

    @Test
    func `the Variant check is case-insensitive`() {
        #expect(FirmwareManifest.isResearch(
            Self.identity(deviceClass: "vresearch101ap", variant: "RESEARCH Erase Install"),
        ))
    }

    @Test
    func `a filename that is not four parts falls through to the Variant`() {
        // "LLB.vresearch101.im4p" is three parts: no RESEARCH field to read,
        // so the decision has to come from Variant instead of defaulting.
        let bi = Self.identity(
            deviceClass: "vresearch101ap",
            variant: "Research Erase Install (IPSW)",
            llbPath: "Firmware/all_flash/LLB.vresearch101.im4p",
        )
        #expect(FirmwareManifest.isResearch(bi))
    }

    // MARK: - findCloudOS

    @Test
    func `picks the first release and the first research for a device class`() throws {
        let identities = [
            Self.identity(deviceClass: "j226cap"),
            Self.identity(deviceClass: "vphone600ap"),
            Self.identity(deviceClass: "vresearch101ap"),
            Self.identity(deviceClass: "vresearch101ap", variant: "Research Erase Install"),
            Self.identity(deviceClass: "vresearch101ap", variant: "Research Erase Install"),
        ]
        let (release, research) = try FirmwareManifest.findCloudOS(
            identities,
            deviceClass: "vresearch101ap",
        )
        #expect(release == 2)
        #expect(research == 3) // the first research one, not the last
    }

    @Test
    func `a device class with no research identity is an error, not a silent fallback`() {
        let identities = [Self.identity(deviceClass: "vresearch101ap")]
        #expect(throws: (any Error).self) {
            try FirmwareManifest.findCloudOS(identities, deviceClass: "vresearch101ap")
        }
    }

    @Test
    func `an unknown device class is an error`() {
        let identities = [Self.identity(deviceClass: "j226cap")]
        #expect(throws: (any Error).self) {
            try FirmwareManifest.findCloudOS(identities, deviceClass: "vphone600ap")
        }
    }

    // MARK: - findIPhoneErase

    @Test
    func `erase is the first identity that is not research, upgrade or recovery`() throws {
        let identities = [
            Self.identity(deviceClass: "d47ap", variant: "Customer Upgrade Install (IPSW)"),
            Self.identity(deviceClass: "d47ap", variant: "Research Erase Install (IPSW)"),
            Self.identity(deviceClass: "d47ap", variant: "Recovery Customer Install"),
            Self.identity(deviceClass: "d47ap", variant: "Customer Erase Install (IPSW)"),
        ]
        #expect(try FirmwareManifest.findIPhoneErase(identities) == 3)
    }

    @Test
    func `the erase match is case-insensitive`() throws {
        let identities = [
            Self.identity(deviceClass: "d47ap", variant: "Customer UPGRADE Install"),
            Self.identity(deviceClass: "d47ap", variant: "Customer Erase Install"),
        ]
        #expect(try FirmwareManifest.findIPhoneErase(identities) == 1)
    }

    @Test
    func `an iPhone manifest with no erase identity is an error`() {
        let identities = [
            Self.identity(deviceClass: "d47ap", variant: "Customer Upgrade Install (IPSW)"),
        ]
        #expect(throws: (any Error).self) {
            try FirmwareManifest.findIPhoneErase(identities)
        }
    }
}
