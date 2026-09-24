// InPlaceRewrite.swift — the one file read in this module that is NOT mapped.
//
// Everything else opens a file with `Data(contentsOf:options:.mappedIfSafe)`,
// because the files this project opens run to gigabytes and reading them whole
// is how a test run used to take the machine down.
//
// The patchers are the exception, and it is not a matter of taste:
//
//     var data = try Data(contentsOf: url, options: .mappedIfSafe)
//     patch(&data)
//     try data.write(to: url)          // <- the file `data` is mapped from
//
// `Data.write(to:)` replaces the destination, and the destination is the file
// the source buffer is mapped from. The mapping is invalidated underneath the
// write that is reading through it, and the next page fault is a SIGBUS — a
// killed process with no failed assertion and nothing in the log, which is
// exactly how this presented.
//
// So a buffer that will be mutated and written back over its own file is READ.
// Nothing that comes through here is large: these are single Mach-Os out of a
// guest filesystem — launchd is 639 KB, the biggest is mobileactivationd at
// 4.6 MB — so the copy costs nothing worth having, and `scripts/check_aux.sh` knows
// this spelling is the deliberate one.

import Foundation

extension Data {
    /// Read a file that is about to be mutated and written back over itself.
    ///
    /// Not `Data(contentsOf:)` underneath, deliberately: the admission gate
    /// bans that spelling outright so nobody reintroduces an unbounded read by
    /// habit, and this is the one place allowed to say "a copy is what I want".
    init(contentsOfFileToRewrite url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        self = try handle.readToEnd() ?? Data()
    }
}
