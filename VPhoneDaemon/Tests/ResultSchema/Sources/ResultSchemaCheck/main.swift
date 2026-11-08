import Foundation
import ResultSchemaKit

let usage = """
usage: ResultSchemaCheck --repo <root> --icli <checkout> [--method <prefix>] [--help]
  --repo <root>      repository root (VPhoneDaemon/ lives under it)
  --icli <checkout>  icli SwiftPM checkout (its Sources/ is searched)
  --method <prefix>  check only catalog methods whose name starts with <prefix>
  --help             print this help and exit 0
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n" + usage + "\n").utf8))
    exit(2)
}

var repo: String?
var icli: String?
var method: String?
var args = CommandLine.arguments.dropFirst()[...]
while let arg = args.popFirst() {
    switch arg {
    case "--help":
        print(usage)
        exit(0)
    case "--repo", "--icli", "--method":
        guard let value = args.popFirst(), !value.hasPrefix("--") else { fail("missing \(arg)") }
        switch arg {
        case "--repo": repo = value
        case "--icli": icli = value
        default: method = value
        }
    default:
        fail("unknown argument: \(arg)")
    }
}
guard let repo else { fail("missing --repo") }
guard let icli else { fail("missing --icli") }

let report = DriftCheck.run(repo: URL(fileURLWithPath: repo), icli: URL(fileURLWithPath: icli), method: method)
for line in report.stdout { print(line) }
for line in report.stderr { FileHandle.standardError.write(Data((line + "\n").utf8)) }
exit(report.exitCode)
