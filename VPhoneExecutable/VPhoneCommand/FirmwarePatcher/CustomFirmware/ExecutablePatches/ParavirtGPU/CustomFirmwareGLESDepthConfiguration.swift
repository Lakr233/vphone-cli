import Foundation
import VPhonePatchKit

/// Paired with the renderer's viewport patch. This data byte is part of the
/// installed plugin digest, so both selection transitions invalidate shaders.
public enum CustomFirmwareGLESDepthConfiguration {
    @discardableResult
    public static func configure(_ data: inout Data, enabled: Bool) throws -> Bool {
        let marker = Data("VPHONE_GLES_DEPTH_CLIP_V1:".utf8)
        guard let section = MachOParser.parseSections(from: data)["__DATA,__vphone_gles"],
              section.size == marker.count + 2,
              let start = Int(exactly: section.fileOffset), start >= 0,
              start <= data.count - marker.count - 2,
              data.subdata(in: start ..< start + marker.count) == marker,
              [UInt8(48), 49].contains(data[start + marker.count]),
              data[start + marker.count + 1] == 0
        else { throw PatcherError.patchVerificationFailed("GLES compiler configuration section is missing or malformed") }
        let index = start + marker.count
        let desired: UInt8 = enabled ? 49 : 48
        let changed = data[index] != desired
        data[index] = desired
        return changed
    }
}
