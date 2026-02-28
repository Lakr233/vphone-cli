import Dynamic
import Foundation
import Virtualization

/// Creates a PV=3 hardware model via private _VZMacHardwareModelDescriptor.
///
/// The Virtualization.framework checks:
///   default_configuration_for_platform_version(3) validity byte =
///     (entitlements & 0x12) != 0
///   where bit 1 = com.apple.private.virtualization
///         bit 4 = com.apple.private.virtualization.security-research
///
/// Minimum host OS for PV=3: macOS 15.0 (Sequoia)
///
enum VPhoneHardware {
    static func createModel() throws -> VZMacHardwareModel {
        // platformVersion=3, boardID=0x90, ISA=2 matches vresearch101
        let desc = Dynamic._VZMacHardwareModelDescriptor()
        desc.setPlatformVersion(NSNumber(value: UInt32(3)))
        desc.setBoardID(NSNumber(value: UInt32(0x90)))
        desc.setISA(NSNumber(value: Int64(2)))

        let model = Dynamic.VZMacHardwareModel
            ._hardwareModelWithDescriptor(desc.asObject)
            .asObject as! VZMacHardwareModel

        guard model.isSupported else {
            throw VPhoneError.hardwareModelNotSupported
        }
        return model
    }
}
