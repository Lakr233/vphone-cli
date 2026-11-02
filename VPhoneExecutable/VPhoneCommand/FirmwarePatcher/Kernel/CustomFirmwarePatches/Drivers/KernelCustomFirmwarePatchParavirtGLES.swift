// KernelCustomFirmwarePatchParavirtGLES.swift — CFW kernel patch: give the
// paravirtual GPU's IOKit personality the OpenGL ES renderer that AGX names.
//
// Background: OpenGLES finds its renderer through the `IOAcceleratorES`
// service. `gfxInitializeLibrary` (libGFXShared) reads `IOGLESBundleName` or
// `IOGLESMetalBundleName` from that service's registry properties and loads
// `/System/Library/Extensions/<name>.bundle`. A service with neither gets no
// renderer, so every `-[EAGLContext initWithAPI:]` returns nil. On real hardware
// the AGX personality carries `IOGLESBundleName = AppleMetalGLRenderer`, GLES
// over Metal. `AppleParavirtGPU`'s personality (AppleParavirtGPUIOGPUFamily)
// names its Metal plugin and nothing for GLES, although the guest ships
// AppleMetalGLRenderer.
//
// A personality's keys become the matched driver's property table, so the key
// goes into the personality in `__PRELINK_INFO`, after `IOClass`, as in AGX's.
// The plist is XML text; the room for the new key is taken from the indentation
// of the lines that follow it, so the record stays small and every byte outside
// it keeps its offset.
//
// Anchor (no offsets): the one personality whose `IOClass` is `AppleParavirtGPU`
// and whose `IOMatchCategory` is `IOAcceleratorES`. The patched plist is parsed
// back and must equal the original with that one key added.

import Foundation
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
    static let paravirtGLESKey = "IOGLESBundleName"
    static let paravirtGLESRenderer = "AppleMetalGLRenderer"

    @discardableResult
    func patchParavirtGLESRenderer() -> Bool {
        log("\n[CFW]AppleParavirtGPU personality: \(Self.paravirtGLESKey) = \(Self.paravirtGLESRenderer)")

        guard let segment = segments.first(where: { $0.name == "__PRELINK_INFO" }), segment.fileSize > 0 else {
            log("  [-] no __PRELINK_INFO")
            return false
        }
        let data = buffer.data
        let segmentRange = Int(segment.fileOffset) ..< min(Int(segment.fileOffset + segment.fileSize), data.count)
        guard let xmlStart = data.range(of: Data("<?xml".utf8), in: segmentRange),
              let xmlEnd = data.range(of: Data("</plist>".utf8), in: xmlStart.lowerBound ..< segmentRange.upperBound)
        else {
            log("  [-] __PRELINK_INFO holds no XML plist")
            return false
        }
        let xml = xmlStart.lowerBound ..< xmlEnd.upperBound

        guard let personality = paravirtGPUPersonality(in: xml) else { return false }
        if data.range(of: Data("<key>\(Self.paravirtGLESKey)</key>".utf8), in: personality.dict) != nil {
            log("  [=] the personality already names a GLES renderer")
            return true
        }

        // The new lines take the indentation of the IOClass key line.
        let insertion = Data((personality.indent + "<key>\(Self.paravirtGLESKey)</key>\n" + personality.indent + "<string>\(Self.paravirtGLESRenderer)</string>\n").utf8)
        guard let replaced = reclaimIndentation(insertion.count, from: personality.insertAt, before: xml.upperBound) else {
            log("  [-] not enough indentation after the personality to make room for \(insertion.count) bytes")
            return false
        }
        let region = personality.insertAt ..< replaced.end
        let patch = insertion + replaced.lines
        guard patch.count == region.count else {
            log("  [-] replacement is \(patch.count) bytes for a \(region.count)-byte region")
            return false
        }

        var patchedXML = Data(data[xml])
        patchedXML.replaceSubrange((region.lowerBound - xml.lowerBound) ..< (region.upperBound - xml.lowerBound), with: patch)
        guard patchedPrelinkInfoAddsOnlyGLESKey(original: Data(data[xml]), patched: patchedXML) else {
            log("  [-] the patched plist does not parse to the original plus \(Self.paravirtGLESKey)")
            return false
        }

        emit(
            region.lowerBound,
            patch,
            patchID: FirmwarePatchSetCatalog.paravirtGLESPatch,
            virtualAddress: fileOffsetToVA(region.lowerBound),
            description: "AppleParavirtGPU personality + \(Self.paravirtGLESKey) = \(Self.paravirtGLESRenderer) [\(region.count) bytes]",
        )
        return true
    }

    /// The personality dict, the indentation of its `IOClass` key and the offset
    /// of the line after that key's value.
    private func paravirtGPUPersonality(in xml: Range<Int>) -> (dict: Range<Int>, indent: String, insertAt: Int)? {
        let data = buffer.data
        let classKey = Data("<key>IOClass</key>".utf8)
        let classValue = Data("<string>AppleParavirtGPU</string>".utf8)

        var hits: [(key: Range<Int>, value: Range<Int>)] = []
        for valueOff in buffer.findAll(classValue, in: xml) {
            var keyEnd = valueOff
            while keyEnd > xml.lowerBound, Self.isXMLSpace(data[keyEnd - 1]) {
                keyEnd -= 1
            }
            guard keyEnd - classKey.count >= xml.lowerBound,
                  data[(keyEnd - classKey.count) ..< keyEnd] == classKey
            else { continue }
            hits.append((keyEnd - classKey.count ..< keyEnd, valueOff ..< valueOff + classValue.count))
        }
        guard hits.count == 1, let hit = hits.first else {
            log("  [-] expected one personality with IOClass AppleParavirtGPU, found \(hits.count)")
            return nil
        }

        guard let open = data.range(of: Data("<dict>".utf8), options: .backwards, in: xml.lowerBound ..< hit.key.lowerBound),
              let close = data.range(of: Data("</dict>".utf8), in: hit.value.upperBound ..< xml.upperBound)
        else {
            log("  [-] the IOClass key is not inside a dict")
            return nil
        }
        let dict = open.lowerBound ..< close.upperBound
        // A nested dict would make `open`/`close` the wrong pair; a personality
        // here holds only strings and arrays.
        guard data.range(of: Data("<dict>".utf8), in: open.upperBound ..< close.lowerBound) == nil else {
            log("  [-] the AppleParavirtGPU personality holds a nested dict")
            return nil
        }
        guard let category = data.range(of: Data("<key>IOMatchCategory</key>".utf8), in: dict),
              let categoryValue = data.range(of: Data("<string>IOAcceleratorES</string>".utf8), in: category.upperBound ..< dict.upperBound),
              data[category.upperBound ..< categoryValue.lowerBound].allSatisfy(Self.isXMLSpace)
        else {
            log("  [-] the AppleParavirtGPU personality does not match IOAcceleratorES")
            return nil
        }

        var lineStart = hit.key.lowerBound
        while lineStart > dict.lowerBound, data[lineStart - 1] == UInt8(ascii: "\t") || data[lineStart - 1] == UInt8(ascii: " ") {
            lineStart -= 1
        }
        guard lineStart > dict.lowerBound, data[lineStart - 1] == UInt8(ascii: "\n"),
              let newline = data[hit.value.upperBound ..< dict.upperBound].firstIndex(of: UInt8(ascii: "\n")),
              data[hit.value.upperBound ..< newline].allSatisfy(Self.isXMLSpace)
        else {
            log("  [-] the IOClass key and value are not one line each")
            return nil
        }
        let indent = String(decoding: data[lineStart ..< hit.key.lowerBound], as: UTF8.self)
        return (dict, indent, newline + 1)
    }

    /// Lines from `start` with `count` bytes of leading indentation removed, and
    /// where they end. Only whitespace between a tag that closes one line and a
    /// tag that opens the next is removed, which the plist parser ignores.
    private func reclaimIndentation(_ count: Int, from start: Int, before end: Int) -> (lines: Data, end: Int)? {
        let data = buffer.data
        var lines = Data()
        var freed = 0
        var lineStart = start
        while freed < count, lineStart < end {
            guard data[lineStart - 1] == UInt8(ascii: "\n"), lineStart - 2 >= 0, data[lineStart - 2] == UInt8(ascii: ">"),
                  let newline = data[lineStart ..< end].firstIndex(of: UInt8(ascii: "\n"))
            else { return nil }
            var tagStart = lineStart
            while tagStart < newline, data[tagStart] == UInt8(ascii: "\t") || data[tagStart] == UInt8(ascii: " ") {
                tagStart += 1
            }
            let removable = data[tagStart] == UInt8(ascii: "<") ? tagStart - lineStart : 0
            let removed = min(removable, count - freed)
            lines.append(data[(lineStart + removed) ... newline])
            freed += removed
            lineStart = newline + 1
        }
        return freed == count ? (lines, lineStart) : nil
    }

    /// True when `patched` parses to `original` with the GLES key added to the
    /// AppleParavirtGPU personality and nothing else changed.
    private func patchedPrelinkInfoAddsOnlyGLESKey(original: Data, patched: Data) -> Bool {
        guard let expected = try? PropertyListSerialization.propertyList(from: original, options: .mutableContainersAndLeaves, format: nil) as? NSMutableDictionary,
              let actual = try? PropertyListSerialization.propertyList(from: patched, format: nil) as? NSDictionary,
              let items = expected["_PrelinkInfoDictionary"] as? [NSMutableDictionary]
        else { return false }

        var added = 0
        for item in items {
            guard let personalities = item["IOKitPersonalities"] as? NSMutableDictionary else { continue }
            for case let personality as NSMutableDictionary in personalities.allValues
                where personality["IOClass"] as? String == "AppleParavirtGPU"
            {
                personality[Self.paravirtGLESKey] = Self.paravirtGLESRenderer
                added += 1
            }
        }
        return added == 1 && actual.isEqual(expected)
    }

    private static func isXMLSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }
}
