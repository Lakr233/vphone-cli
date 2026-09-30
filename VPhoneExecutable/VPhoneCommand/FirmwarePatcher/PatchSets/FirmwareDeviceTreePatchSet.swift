// FirmwareDeviceTreePatchSet.swift — Manifest for the device tree.
//
// Two kinds of entry. The first four properties make the research board present
// as a phone the guest's own UI can lay out. The rest give it the iPhone17,3
// identity and the camera, audio and SMC nodes that identity implies, which is
// what lets a stock app see a plausible device.
//
// None is boot-essential: a VM with a stock device tree boots, it just looks like
// a research board and has no camera.
//
// The eight Device Identity rewrites came from the former EXP variant and are off
// in `standard` (`FirmwarePatchSetCatalog.experimentalIdentityPatches`). The camera
// geometry and added nodes stay on: the camera needs them, not the identity.

import Foundation
import VPhonePatchKit

public enum FirmwareDeviceTreePatchSet {
    public static let identifier = "com.vphone.patchset.devicetree"

    private static func property(
        _ identifier: String,
        _ title: String,
        _ summary: String,
    ) -> VPhonePatchDeclaration {
        VPhonePatchDeclaration(
            identifier: identifier,
            title: title,
            summary: summary,
            target: .firmware(.deviceTree),
        )
    }

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Device Tree",
        summary: "Display geometry plus the iPhone17,3 identity, camera, audio and SMC nodes",
        patches: [
            // MARK: Board Presentation

            property(
                "devicetree-cfw-serial_number",
                "Serial number",
                "Gives the board a well-formed serial number.",
            ),
            property(
                "devicetree-cfw-home_button_type",
                "Home button type",
                "Declares a gesture-driven device with no home button.",
            ),
            property(
                "devicetree-cfw-artwork_device_subtype",
                "Artwork device subtype",
                "Picks the artwork subtype the guest UI lays out against.",
            ),
            property(
                "devicetree-cfw-island_notch_location",
                "Island notch location",
                "Places the sensor cutout so status bar layout matches the display.",
            ),

            // MARK: Device Identity

            property(
                "devicetree-exp-target_sub_type",
                "Target sub type",
                "Reports the iPhone17,3 target sub type.",
            ),
            property(
                "devicetree-exp-compatible_secondary",
                "Compatible list",
                "Adds the iPhone17,3 entry to the board's compatible list.",
            ),
            property(
                "devicetree-exp-product_fdr_product_type",
                "FDR product type",
                "Reports the iPhone17,3 product type to FDR.",
            ),
            property(
                "devicetree-exp-product_sub_product_type",
                "Sub product type",
                "Reports the iPhone17,3 sub product type.",
            ),
            property(
                "devicetree-exp-product_unique_model",
                "Unique model code",
                "Reports the model code a stock app reads for the device name.",
            ),
            property(
                "devicetree-exp-product_gestalt_variants_rename",
                "Gestalt variants",
                "Renames the gestalt variants node so the identity is consistent.",
            ),
            property(
                "devicetree-exp-arm_io_device_type",
                "SoC device type",
                "Reports the SoC device type the identity implies.",
            ),
            property(
                "devicetree-exp-arm_io_soc_generation",
                "SoC generation",
                "Reports the SoC generation the identity implies.",
            ),

            // MARK: Camera Geometry

            property(
                "devicetree-cfw-product_front_cam_offset",
                "Front camera offset",
                "Places the front camera where the identity's hardware has it.",
            ),
            property(
                "devicetree-cfw-product_rear_cam_offset",
                "Rear camera offset",
                "Places the rear camera where the identity's hardware has it.",
            ),

            // MARK: Added Nodes

            property(
                "devicetree-cfw-product_camera_node",
                "Camera node",
                "Adds the camera node the virtual camera is published under.",
            ),
            property(
                "devicetree-cfw-product_facetime_node",
                "FaceTime node",
                "Adds the FaceTime camera node.",
            ),
            property(
                "devicetree-cfw-product_audio_node",
                "Audio node",
                "Adds the audio topology node so the guest has speakers.",
            ),
            property(
                "devicetree-cfw-product_iopm_node",
                "Power management node",
                "Adds the IOPM node the power stack expects.",
            ),
            property(
                "devicetree-cfw-arm_io_smc_stub",
                "SMC stub",
                "Adds a stub SMC so the power and thermal clients attach.",
            ),
            property(
                "devicetree-cfw-arm_io_smc_iop_smc_nub_stub",
                "SMC nub stub",
                "Adds the SMC nub the IOP driver binds to.",
            ),
            property(
                "devicetree-cfw-arm_io_smc_ext_charger_camera_driver",
                "SMC charger and camera driver",
                "Publishes the charger and camera driver under the stub SMC.",
            ),
            property(
                "devicetree-cfw-arm_io_isp_camera_flags",
                "ISP camera flags",
                "Sets the ISP flags the virtual camera pipeline needs.",
            ),
            property(
                "devicetree-cfw-arm_io_isp_rtb_camera_flags",
                "ISP RTB camera flags",
                "Sets the ISP round-trip buffer flags for the camera pipeline.",
            ),
        ],
        provides: ["vphone.devicetree"],
    )
}
