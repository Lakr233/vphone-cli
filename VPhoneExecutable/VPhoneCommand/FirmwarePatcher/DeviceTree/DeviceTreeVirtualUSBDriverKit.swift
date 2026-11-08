import Foundation
import VPhoneCoreKit
import VPhonePatchKit

extension DeviceTreePatcher {
    static let virtualUSBDriverKitPatch = "devicetree-cfw-virtual_usb_driverkit"

    /// The virtual USB touchscreen is driven by a DriverKit dext, regardless
    /// of the iPhone or iPad board whose userland the runtime tree presents.
    static func enableVirtualUSBDriverKit(in root: DTNode) throws -> (before: Data?, after: Data, delta: Int)? {
        let model = root.properties.first { $0.name == "model" }.map { String(decoding: $0.value.prefix { $0 != 0 }, as: UTF8.self) } ?? ""
        let compatible = root.properties.first { $0.name == "compatible" }?.value.split(separator: 0) ?? []
        guard (model.hasPrefix("iPhone") || model.hasPrefix("iPad")),
              compatible.contains(where: { $0.elementsEqual("VPHONE600AP".utf8) })
        else { throw PatcherError.patchVerificationFailed("DriverKit: expected a virtual iPhone or iPad device tree") }

        guard let product = root.children.first(where: { node in
            node.properties.contains { $0.name == "name" && $0.value.prefix { $0 != 0 }.elementsEqual("product".utf8) }
        }) else { throw PatcherError.patchSiteNotFound("DriverKit: the device tree has no product node") }
        let value = Data([1, 0, 0, 0])
        let property = product.properties.first { $0.name == "supports-driverkit" }
        if let property, property.value == value, property.flags == 0 { return nil }
        let before = property?.value
        let previousSize = before.map { 36 + $0.count + (4 - $0.count % 4) % 4 } ?? 0
        if let property {
            property.value = value
            property.flags = 0
        } else {
            product.properties.append(DTProperty(name: "supports-driverkit", flags: 0, value: value, valueOffset: 0))
        }
        return (before, value, 40 - previousSize)
    }

    func applyVirtualUSBDriverKit(root: DTNode) throws {
        guard role != .restore, [.iPhone, .iPad].contains(device.family),
              gateAllows(Self.virtualUSBDriverKitPatch),
              let change = try Self.enableVirtualUSBDriverKit(in: root)
        else { return }
        patches.append(PatchRecord(
            patchID: Self.virtualUSBDriverKitPatch, component: component, fileOffset: 0, virtualAddress: nil,
            originalBytes: change.before ?? Data(), patchedBytes: change.after,
            description: "Enable DriverKit for the virtual USB touchscreen",
        ))
        if verbose {
            print("  =prop : /product/supports-driverkit \((change.before ?? Data()).hex) → \(change.after.hex)  [\(Self.virtualUSBDriverKitPatch)]")
        }
    }
}
