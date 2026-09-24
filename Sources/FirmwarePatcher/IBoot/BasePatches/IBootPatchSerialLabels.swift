// IBootPatchSerialLabels.swift — iBoot serial banner label patch.
//
// Part of IBootPatcher; see IBootPatcher.swift for the patch schedule by mode.

import Foundation

extension IBootPatcher {
    // MARK: - 1. Serial Labels

    /// Find the two long '====...' banner runs and write the mode label into each.
    /// Python: `patch_serial_labels()`
    func patchSerialLabels() {
        let labelStr = switch mode {
        case .ibss: "Loaded iBSS"
        case .ibec: "Loaded iBEC"
        case .llb: "Loaded LLB"
        }
        guard let labelBytes = labelStr.data(using: .ascii) else { return }

        // Collect all runs of '=' (>=20 chars) — same logic as Python.
        let raw = buffer.original
        var eqRuns: [Int] = []
        var i = raw.startIndex

        while i < raw.endIndex {
            if raw[i] == UInt8(ascii: "=") {
                let start = i
                while i < raw.endIndex, raw[i] == UInt8(ascii: "=") {
                    i = raw.index(after: i)
                }
                let runLen = raw.distance(from: start, to: i)
                if runLen >= 20 {
                    eqRuns.append(raw.distance(from: raw.startIndex, to: start))
                }
            } else {
                i = raw.index(after: i)
            }
        }

        if eqRuns.count < 2 {
            var labelCount = 0
            var searchStart = raw.startIndex
            while let range = raw.range(of: labelBytes, in: searchStart ..< raw.endIndex) {
                labelCount += 1
                searchStart = range.upperBound
            }
            if labelCount >= 2 {
                if verbose {
                    print("  [*] serial labels: already present, skipping")
                }
                return
            }
            if verbose {
                print("  [-] serial labels: <2 banner runs found")
            }
            return
        }

        for runStart in eqRuns.prefix(2) {
            let writeOff = runStart + 1 // Python: run_start + 1
            emitString(writeOff, labelBytes, id: "\(component).serial_label", description: "serial label")
        }
    }
}
