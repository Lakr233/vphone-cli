// FirmwarePatchSummary.swift — a component's patch records as rows for the vm create screen.

import Foundation
import VPhoneCoreKit
import VPhonePatchKit

enum FirmwarePatchSummary {
    // MARK: - Rows

    /// An empty row, a header row with the component's name, then one row per patch.
    static func rows(
        component: String,
        records: [PatchRecord],
        declaration: (String) -> (identifier: String, title: String)?,
    ) -> [[VPhoneConsoleSpan]] {
        var order: [String] = []
        var groups: [String: (title: String, records: [PatchRecord])] = [:]
        for record in records {
            let declared = declaration(record.patchID)
            let key = declared?.identifier ?? record.patchID
            if groups[key] == nil {
                order.append(key)
                groups[key] = (declared?.title ?? record.patchDescription, [])
            }
            groups[key]?.records.append(record)
        }
        let cells = order.compactMap { key in groups[key].map { cell(component: component, title: $0.title, records: $0.records) } }
        // Widths fit this component's rows, so a long value never runs off a narrow terminal.
        let titleWidth = cells.filter { $0.before != nil || $0.after != nil }.map(\.title.count).max() ?? 0
        let beforeWidth = cells.filter { $0.before != nil && $0.after != nil }.compactMap { $0.before?.count }.max() ?? 0
        let body = cells.map { row($0, titleWidth: titleWidth, beforeWidth: beforeWidth) }
        return [[], [VPhoneConsoleSpan("   " + component, .bold)]] + body
    }

    /// "[patches] <component>" followed by each record's `description`.
    static func logLines(component: String, records: [PatchRecord]) -> [String] {
        ["[patches] " + component] + records.map(\.description)
    }

    // MARK: - One row

    private struct Cell {
        var title: String
        var before: String?
        var after: String?
        var more: Int
    }

    private static func cell(component: String, title: String, records: [PatchRecord]) -> Cell {
        let first = records[0]
        var shown = title
        if shown.lowercased().hasPrefix(component.lowercased() + " ") {
            shown = String(shown.dropFirst(component.count + 1))
            shown = shown.prefix(1).uppercased() + shown.dropFirst()
        }
        return Cell(
            title: fit(shown, 30),
            before: value(first.beforeDisasm, first.originalBytes).map { fit($0, 28) },
            after: value(first.afterDisasm, first.patchedBytes),
            more: records.count - 1,
        )
    }

    private static func row(_ cell: Cell, titleWidth: Int, beforeWidth: Int) -> [VPhoneConsoleSpan] {
        let mark: VPhoneConsoleSpan = switch (cell.before, cell.after) {
        case (_?, nil): VPhoneConsoleSpan("     - ", .red)
        case (nil, _?): VPhoneConsoleSpan("     + ", .green)
        default: VPhoneConsoleSpan("     ~ ", .yellow)
        }
        let hasValue = cell.before != nil || cell.after != nil
        var spans = [mark, VPhoneConsoleSpan(hasValue ? fit(cell.title, 30, pad: titleWidth + 2) : cell.title)]
        switch (cell.before, cell.after) {
        case let (before?, after?):
            spans += [
                VPhoneConsoleSpan(fit(before, 28, pad: beforeWidth), .red),
                VPhoneConsoleSpan("  →  ", .dim),
                VPhoneConsoleSpan(after, .green),
            ]
        case let (before?, nil): spans.append(VPhoneConsoleSpan(before, .red))
        case let (nil, after?): spans.append(VPhoneConsoleSpan(after, .green))
        default: break
        }
        if cell.more > 0 { spans.append(VPhoneConsoleSpan("   +\(cell.more)", .dim)) }
        return spans
    }

    /// Cut to `limit` characters (the last one `…` when cut), then pad with spaces.
    private static func fit(_ text: String, _ limit: Int, pad: Int = 0) -> String {
        let cut = text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
        return cut + String(repeating: " ", count: max(0, pad - cut.count))
    }

    private static func value(_ disasm: String, _ bytes: Data) -> String? {
        if !disasm.isEmpty { return disasm }
        guard !bytes.isEmpty else { return nil }
        let trimmed = bytes.last == 0 ? bytes.dropLast() : bytes[...]
        if !trimmed.isEmpty, trimmed.allSatisfy({ (0x20 ... 0x7E).contains($0) }) {
            return "\"" + String(decoding: trimmed, as: UTF8.self) + "\""
        }
        if bytes.count == 4 { return String(bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }) }
        if bytes.count <= 8 { return bytes.map { String(format: "%02x", $0) }.joined() }
        return "\(bytes.count) bytes"
    }
}
