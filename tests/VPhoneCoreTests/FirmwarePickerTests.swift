@testable import VPhoneCore
import Testing

struct FirmwarePickerTests {
    /// A scripted stdin: pops one line per `read()` call.
    private func reader(_ lines: [String?]) -> () -> String? {
        var i = 0
        return { defer { i += 1 }; return i < lines.count ? lines[i] : nil }
    }

    // MARK: - Catalog integrity

    @Test func catalogHasTwentyThreePairings() {
        #expect(VPhoneFirmwareCatalog.pairings.count == 23)
    }

    @Test func everyPairingIsPopulated() {
        for p in VPhoneFirmwareCatalog.pairings {
            #expect(!p.iosName.isEmpty)
            #expect(p.iosURL.hasPrefix("https://"))
            #expect(p.iosURL.hasSuffix(".ipsw"))
            #expect(p.cloudosName.hasPrefix("cloudOS "))
            #expect(p.cloudosURL.contains("/private-cloud-compute/"))
        }
    }

    @Test func cloudOSOptionsAreDistinctInFirstSeenOrder() {
        let opts = VPhoneFirmwareCatalog.cloudOSOptions
        #expect(opts.map(\.name) == ["cloudOS 26.1", "cloudOS 26.2", "cloudOS 26.3", "cloudOS 26.4"])
        #expect(Set(opts.map(\.url)).count == opts.count)   // no dup URLs
    }

    // MARK: - Passthrough

    @Test func bothProvidedPassesThrough() throws {
        let out = try VPhoneFirmwarePicker.resolve(
            iphone: "a.ipsw", cloudos: "b.dmg", isInteractive: true,
            read: { nil }, write: { _ in })
        #expect(out == VPhoneFirmwareSources(iphoneSource: "a.ipsw", cloudosSource: "b.dmg"))
    }

    @Test func nonInteractivePassesThroughEvenWhenIncomplete() throws {
        let out = try VPhoneFirmwarePicker.resolve(
            iphone: nil, cloudos: nil, isInteractive: false,
            read: { nil }, write: { _ in })
        #expect(out == VPhoneFirmwareSources(iphoneSource: nil, cloudosSource: nil))
    }

    @Test func emptyStringsTreatedAsUnset() throws {
        // Non-interactive + empty → passthrough as nil (no prompt), not "".
        let out = try VPhoneFirmwarePicker.resolve(
            iphone: "", cloudos: "", isInteractive: false,
            read: { nil }, write: { _ in })
        #expect(out == VPhoneFirmwareSources(iphoneSource: nil, cloudosSource: nil))
    }

    // MARK: - Prompt: neither provided

    @Test func neitherProvidedPicksFullPairing() throws {
        // "1" → first pairing (iOS 18.6.2 → cloudOS 26.1).
        let first = VPhoneFirmwareCatalog.pairings[0]
        let out = try VPhoneFirmwarePicker.resolve(
            iphone: nil, cloudos: nil, isInteractive: true,
            read: reader(["1"]), write: { _ in })
        #expect(out == VPhoneFirmwareSources(iphoneSource: first.iosURL, cloudosSource: first.cloudosURL))
    }

    @Test func neitherProvidedResolvesBothFromChosenPairing() throws {
        let idx = 8   // iOS 26.4 (menu number 9), paired with cloudOS 26.4
        let p = VPhoneFirmwareCatalog.pairings[idx]
        #expect(p.iosName == "iOS 26.4")
        let out = try VPhoneFirmwarePicker.resolve(
            iphone: nil, cloudos: nil, isInteractive: true,
            read: reader([String(idx + 1)]), write: { _ in })
        #expect(out.iphoneSource == p.iosURL)
        #expect(out.cloudosSource == p.cloudosURL)
    }

    // MARK: - Prompt: only one side missing

    @Test func iPhoneProvidedPromptsForCloudOSOnly() throws {
        // cloudOS menu: [1]26.1 [2]26.2 [3]26.3 [4]26.4 → pick 4.
        let opts = VPhoneFirmwareCatalog.cloudOSOptions
        let out = try VPhoneFirmwarePicker.resolve(
            iphone: "custom.ipsw", cloudos: nil, isInteractive: true,
            read: reader(["4"]), write: { _ in })
        #expect(out.iphoneSource == "custom.ipsw")           // untouched
        #expect(out.cloudosSource == opts[3].url)            // chosen cloudOS 26.4
    }

    @Test func cloudOSProvidedPromptsForIPhoneOnly() throws {
        let p = VPhoneFirmwareCatalog.pairings[3]            // iOS 26.1 (menu 4)
        #expect(p.iosName == "iOS 26.1")
        let out = try VPhoneFirmwarePicker.resolve(
            iphone: nil, cloudos: "custom.dmg", isInteractive: true,
            read: reader(["4"]), write: { _ in })
        #expect(out.iphoneSource == p.iosURL)                // chosen iPhone build
        #expect(out.cloudosSource == "custom.dmg")           // untouched
    }

    // MARK: - Menu formatting

    @Test func pairingMenuIsColumnAligned() throws {
        var lines: [String] = []
        _ = try VPhoneFirmwarePicker.resolve(
            iphone: nil, cloudos: nil, isInteractive: true,
            read: reader(["1"]), write: { lines.append($0) })
        let menu = lines.filter { $0.hasPrefix("  [") }
        #expect(menu.count == 23)
        // Label text starts in one column regardless of 1- vs 2-digit index.
        let labelStarts = Set(menu.map { $0.range(of: "] ")!.upperBound.utf16Offset(in: $0) })
        #expect(labelStarts.count == 1)
        // The "(→ cloudOS …)" arrow lands in one column across every row.
        let arrowCols = Set(menu.map { $0.range(of: "(→")!.lowerBound.utf16Offset(in: $0) })
        #expect(arrowCols.count == 1)
    }

    // MARK: - Retry / abort semantics

    @Test func retriesThenSucceeds() throws {
        let first = VPhoneFirmwareCatalog.pairings[0]
        let out = try VPhoneFirmwarePicker.resolve(
            iphone: nil, cloudos: nil, isInteractive: true,
            read: reader(["", "999", "garbage", "1"]), write: { _ in })
        #expect(out.iphoneSource == first.iosURL)
    }

    @Test func eofAborts() {
        #expect(throws: VPhoneFirmwarePickerError.aborted) {
            _ = try VPhoneFirmwarePicker.resolve(
                iphone: nil, cloudos: nil, isInteractive: true,
                read: { nil }, write: { _ in })
        }
    }

    @Test func tooManyInvalidThrows() {
        #expect(throws: VPhoneFirmwarePickerError.invalidSelection) {
            _ = try VPhoneFirmwarePicker.resolve(
                iphone: nil, cloudos: nil, isInteractive: true,
                maxRetries: 2, read: reader(["x", "y", "z"]), write: { _ in })
        }
    }
}
