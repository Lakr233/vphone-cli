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
        #expect(text(rows[2]) == "     ~ Image-4 callback  b.ne 0x1a31c  →  nop   +1")
        #expect(rows[2].first == VPhoneConsoleSpan("     ~ ", .yellow))
    }

    @Test func `marks follow which values exist`() {
        func row(_ r: PatchRecord) -> [VPhoneConsoleSpan] {
            FirmwarePatchSummary.rows(component: "LLB", records: [r]) { _ in ("x", "Title") }[2]
        }
        let after = row(record("a", after: "nop"))
        #expect(after.first == VPhoneConsoleSpan("     + ", .green))
        #expect(text(after) == "     + Title  nop")
        let before = row(record("a", before: "nop"))
        #expect(before.first == VPhoneConsoleSpan("     - ", .red))
        #expect(text(before) == "     - Title  nop")
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
        #expect(after(record("a", after: "nop ")) == "nop")
        #expect(after(record("a", after: " ", now: [1, 2, 3])) == "010203")
        #expect(after(record("a", now: Array("Loaded LLB".utf8) + [0])) == "\"Loaded LLB\"")
        #expect(after(record("a", now: [0xfc, 0x09, 0, 0])) == "2556")
        #expect(after(record("a", now: [0x20, 0, 0, 0])) == "32")
        #expect(after(record("a", now: [0x0c, 0, 0, 0])) == "12")
        #expect(after(record("a", now: Array("vphone-1337".utf8) + [0])) == "\"vphone-1337\"")
        #expect(after(record("a", now: Array("sysc".utf8))) == "\"sysc\"")
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

    @Test func `columns fit the rows of one call`() {
        let names = ["s1": "Serial label", "s2": "Bootx precondition", "s3": "Quiet"]
        let rows = FirmwarePatchSummary.rows(
            component: "LLB",
            records: [
                record("s1", before: "b 0x10", after: "nop"),
                record("s2", before: "tbz w0, #0, 0x65408", after: "nop"),
                record("s3"),
            ],
        ) { id in (id, names[id]!) }
        let a = text(rows[2]), b = text(rows[3])
        #expect(a == "     ~ Serial label" + String(repeating: " ", count: 8) + "b 0x10" + String(repeating: " ", count: 13) + "  →  nop")
        #expect(b == "     ~ Bootx precondition  tbz w0, #0, 0x65408  →  nop")
        #expect(a.range(of: "b 0x10")!.lowerBound.utf16Offset(in: a) == b.range(of: "tbz")!.lowerBound.utf16Offset(in: b))
        #expect(a.range(of: "  →  ")!.lowerBound.utf16Offset(in: a) == b.range(of: "  →  ")!.lowerBound.utf16Offset(in: b))
        #expect(rows[4].count == 2)
        #expect(text(rows[4]) == "     ~ Quiet")
    }
}
