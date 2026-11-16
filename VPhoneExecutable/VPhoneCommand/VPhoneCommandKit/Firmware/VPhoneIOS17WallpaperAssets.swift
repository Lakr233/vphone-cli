import ArgumentParser
import FirmwarePatcher
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VPhoneCoreKit

enum VPhoneIOS17WallpaperAssets {
    private static let document = "main.caml"
    private static let backup = "main.caml.vphone-original"

    static func update(system: VPhoneConfinedDirectory, enabled: Bool) throws -> Int {
        let path = String(FirmwareGuestSystemPatchSet.ios17WallpaperPath.dropFirst())
        guard try system.isDirectory(path) else { return 0 }
        let wallpapers = try system.directory(path)
        var converted = 0
        for name in try wallpapers.entries() where name.hasPrefix("7565.") && name.hasSuffix(".wallpaper") {
            let variant = try wallpapers.directory(name)
            for animation in try variant.entries() where animation.hasSuffix(".ca") {
                converted += try updateAnimation(variant.directory(animation), enabled: enabled)
            }
        }
        return converted
    }

    private static func updateAnimation(_ animation: VPhoneConfinedDirectory, enabled: Bool) throws -> Int {
        let hasBackup = try animation.isRegularFile(backup)
        guard enabled || hasBackup else { return 0 }
        let original = try animation.readData(hasBackup ? backup : document)
        guard var xml = String(data: original, encoding: .utf8) else {
            throw ValidationError("The stock wallpaper animation is not UTF-8.")
        }
        let references = Set(xml.matches(of: /src="(assets\/[^"\/]+\.HEIC)"/).map { String($0.1) })
        guard !references.isEmpty else { return 0 }
        let assets = try animation.directory("assets")
        for reference in references.sorted() {
            guard let filename = reference.dropFirst("assets/".count).removingPercentEncoding,
                  !filename.contains("/"), !filename.contains("\0")
            else {
                throw ValidationError("Invalid stock wallpaper asset reference: \(reference)")
            }
            let pngName = String(filename.dropLast(".HEIC".count)) + ".vphone.png"
            let pngReference = String(reference.dropLast(".HEIC".count)) + ".vphone.png"
            if enabled {
                if !hasBackup, try assets.exists(pngName) {
                    throw ValidationError("The stock wallpaper asset already exists: \(pngName)")
                }
                try assets.writeFile(pngName, contents: png(from: assets.readData(filename)),
                                     mode: 0o644, owner: (0, 0))
                // Both src and relativePath refer to the same original image.
                xml = xml.replacingOccurrences(of: reference + "\"", with: pngReference + "\"")
            } else {
                try assets.removeItem(pngName)
            }
        }
        if enabled {
            if !hasBackup { try animation.copyFile(from: document, to: backup) }
            try animation.writeFile(document, contents: Data(xml.utf8), mode: 0o644, owner: (0, 0))
        } else {
            try animation.rename(backup, to: document)
        }
        return references.count
    }

    private static func png(from original: Data) throws -> Data {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options)
        else {
            throw ValidationError("The host could not decode a stock wallpaper image.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else {
            throw ValidationError("The host could not create a PNG wallpaper image.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ValidationError("The host could not finish encoding a stock wallpaper image.")
        }
        return output as Data
    }
}
