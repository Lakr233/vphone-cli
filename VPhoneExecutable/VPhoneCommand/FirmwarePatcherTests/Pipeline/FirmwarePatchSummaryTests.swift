// FirmwarePatchSummaryTests.swift — one screen row per patch.

@testable import FirmwarePatcher
import Foundation
import Testing
import VPhoneCoreKit
import VPhonePatchKit

struct FirmwarePatchSummaryTests {
    private func record(
        _ id: String, before: String = "", after: String = "",
        was: [UInt8] = [], now: [UInt8] = [], text: String = "text",
    ) -> PatchRecord {
        PatchRecord(
            patchID: id, component: "LLB", fileOffset: 0,
            originalBytes: Data(was), patchedBytes: Data(now),
            beforeDisasm: before, afterDisasm: after, description: text,
        )
    }

    private func text(_ row: [VPhoneConsoleSpan]) -> String { row.map(\.text).joined() }

    private let callback: (String) -> (identifier: String, title: String)? = { _ in
        ("llb-boot-image4_callback", "LLB image-4 callback")
    }

    private var callbackRecords: [PatchRecord] {
        [
            record("llb-boot-image4_callback.bne", before: "b.ne 0x1a31c", after: "nop"),
            record("llb-boot-image4_callback.mov", before: "mov x0, x22", after: "mov x0, #0"),
        ]
    }

    @Test func `one row per declared patch with a count of the rest`() {
        let rows = FirmwarePatchSummary.rows(component: "LLB", records: callbackRecords, declaration: callback)
        #expect(rows.count == 3)
        #expect(rows[0].isEmpty)
        #expect(rows[1] == [VPhoneConsoleSpan("   LLB", .bold)])
        #expect(text(rows[2]) == "     ~ Image-4 callback" + String(repeating: " ", count: 16)
            + "b.ne 0x1a31c" + String(repeating: " ", count: 16) + "  →  nop   +1")
        #expect(rows[2].first == VPhoneConsoleSpan("     ~ ", .yellow))
    }

    @Test func `marks follow which values exist`() {
        func row(_ r: PatchRecord) -> [VPhoneConsoleSpan] {
            FirmwarePatchSummary.rows(component: "LLB", records: [r]) { _ in ("x", "Title") }[2]
        }
        let after = row(record("a", after: "nop"))
        #expect(after.first == VPhoneConsoleSpan("     + ", .green))
        #expect(text(after) == "     + Title" + String(repeating: " ", count: 27) + "nop")
        let before = row(record("a", before: "nop"))
        #expect(before.first == VPhoneConsoleSpan("     - ", .red))
        #expect(text(before) == "     - Title" + String(repeating: " ", count: 27) + "nop")
        let neither = row(record("a"))
        #expect(neither.count == 2)
        #expect(text(neither) == "     ~ Title")
    }

    @Test func `values are read from disassembly then bytes`() {
        func after(_ r: PatchRecord) -> String {
            let row = FirmwarePatchSummary.rows(component: "LLB", records: [r]) { _ in nil }[2]
            return row.last!.text
        }
        #expect(after(record("a", after: "nop", now: [1, 2, 3])) == "nop")
        #expect(after(record("a", now: Array("Loaded LLB".utf8) + [0])) == "\"Loaded LLB\"")
        #expect(after(record("a", now: [0xfc, 0x09, 0, 0])) == "2556")
        #expect(after(record("a", now: [1, 2, 3])) == "010203")
        #expect(after(record("a", now: [UInt8](repeating: 0xff, count: 9))) == "9 bytes")
    }

    @Test func `undeclared records get their own rows`() {
        let rows = FirmwarePatchSummary.rows(
            component: "LLB",
            records: [record("a", text: "First thing"), record("b", text: "Second thing")],
        ) { _ in nil }
        #expect(rows.count == 4)
        #expect(text(rows[2]) == "     ~ First thing")
        #expect(text(rows[3]) == "     ~ Second thing")
    }

    @Test func `long titles and values are cut`() {
        let long = String(repeating: "a", count: 40)
        let rows = FirmwarePatchSummary.rows(
            component: "LLB", records: [record("a", before: long, after: "x", text: long)],
        ) { _ in nil }
        let spans = rows[2]
        #expect(spans[1].text == String(repeating: "a", count: 29) + "…" + "  ")
        #expect(spans[2].text == String(repeating: "a", count: 27) + "…")
    }

    @Test func `log lines list every record`() {
        let records = callbackRecords
        #expect(FirmwarePatchSummary.logLines(component: "LLB", records: records)
            == ["[patches] LLB"] + records.map(\.description))
    }
}
