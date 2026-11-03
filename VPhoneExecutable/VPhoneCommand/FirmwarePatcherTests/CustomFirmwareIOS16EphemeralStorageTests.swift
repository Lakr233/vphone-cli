import FirmwarePatcher
import Foundation
import Testing

@Suite("iOS 16 lab storage declaration")
struct CustomFirmwareIOS16EphemeralStorageTests {
    private func word(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func node(_ properties: [(String, Data)], children: [Data] = []) -> Data {
        var data = word(UInt32(properties.count)) + word(UInt32(children.count))
        for (name, value) in properties {
            var key = Data(name.utf8); key.append(Data(repeating: 0, count: 32 - key.count))
            data.append(key); data.append(word(UInt32(value.count))); data.append(value)
            data.append(Data(repeating: 0, count: (4 - value.count % 4) % 4))
        }
        for child in children { data.append(child) }
        return data
    }
    private func fixture(chosen: UInt32 = 0, product: UInt32 = 0, productWidth: Int = 8) -> Data {
        node([("name", Data("device-tree\0".utf8)), ("unrelated", Data([9, 8, 7, 6]))], children: [
            node([("name", Data("chosen\0".utf8)), ("ephemeral-storage", word(chosen))]),
            node([("name", Data("product\0".utf8)), ("ephemeral-data-mode", word(product) + Data(repeating: 0, count: productWidth - 4))]),
        ])
    }

    @Test func `Only the two boolean bytes change and a second pass is identical`() throws {
        for width in [4, 8] {
            let original = fixture(productWidth: width)
            let (patched, changes) = try CustomFirmwarePostRestoreDeviceTree.withIOS16EphemeralStorage(original)
            #expect(patched.count == original.count)
            #expect(zip(original, patched).filter { $0.0 != $0.1 }.count == 2)
            #expect(Set(changes.map(\.property)) == ["chosen/ephemeral-storage", "product/ephemeral-data-mode"])
            let (again, repeated) = try CustomFirmwarePostRestoreDeviceTree.withIOS16EphemeralStorage(patched)
            #expect(again == patched && repeated.isEmpty)
        }
    }

    @Test func `Unknown boolean values are refused before writing`() {
        #expect(throws: (any Error).self) {
            try CustomFirmwarePostRestoreDeviceTree.withIOS16EphemeralStorage(fixture(chosen: 2))
        }
        #expect(throws: (any Error).self) {
            try CustomFirmwarePostRestoreDeviceTree.withIOS16EphemeralStorage(fixture(product: 256))
        }
    }
}
