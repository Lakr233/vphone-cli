// Equivalence tests for the Swift port of the two Python heredocs that used to
// live inside scripts/fw_prepare.sh (`list_firmwares`,
// `resolve_selector_from_downloads`).
//
// The golden strings below are not hand-written. They are the bytes the Python
// produced when the two heredocs were lifted out of fw_prepare.sh verbatim
// (`diff <(sed -n '167,246p' scripts/fw_prepare.sh) ref_list_firmwares.py`
// reports no difference) and run under .venv/bin/python3 over the same fixture
// this file freezes:
//
//   DOWNLOADABLE_IPSW_URLS="$(cat fixture_urls.txt)" \
//     .venv/bin/python3 ref_list_firmwares.py iPhone17,3 fixture_readme.md
//
// Colour was compared in three conditions, each running both implementations
// through the identical wrapper: a pipe, a real pty via script(1), and NO_COLOR
// set. Those runs also covered the repository's compatibility guide against a live
// `ipsw download ipsw --device iPhone17,3 --urls` capture.
//
// Trailing spaces are written as `\u{20}` on purpose: the Python padded the
// status column to 11 *inside* the colour escape, so those spaces are real
// output bytes, and a literal trailing space is the first thing an editor or a
// formatter silently eats.
//
// One deliberate divergence, and the only one found: `version_key` built a
// tuple of mixed ints and strs, so a list holding both `27.0` and `27.beta`
// made CPython raise
// `TypeError: '<' not supported between instances of 'str' and 'int'`
// and exit 1 mid-listing. Nothing Apple serves produces that. The port orders
// numbers before text instead of crashing; `nonNumericComponentsStillOrder`
// below pins that choice down.

@testable import VPhoneCore
import Foundation
import Testing

// MARK: - Frozen fixture

private enum Fixture {
    /// A verbatim slice of the real README's table, plus two decoys: a
    /// `17,3_…` cell before the section and another after it, neither of which
    /// may count, and a `16,1_…` row for a different device.
    static let readme = """
    ## Prerequisites

    Some prose with a `17,3_99.9_99Z99` cell that must NOT count, because it is
    outside the section.

    ## Tested Environments

    | Host            | iPhone                | CloudOS         |
    | --------------- | --------------------- | --------------- |
    | Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
    | Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
    | Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
    | Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
    | Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
    | Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
    | Mac16,6 26.6.1  | `17,3_27.0_24A435`    | `26.4-23E5207q` |
    | Mac16,3 26.0    | `16,1_26.1_23B85`     | `26.1-23B85`    |

    ## FAQ

    A later section with `17,3_88.8_88Z88`, which must NOT count either.
    """

    /// Real Apple restore URLs, plus one exact duplicate and four lines that
    /// look close enough to matter: another device, an extra `_Custom`
    /// segment, and a log line with no leading slash.
    static let urls = """
    https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-20738/98758B5A-311E-4538-B365-FEE3D8792CDF/iPhone17,3_18.6.2_22G100_Restore.ipsw
    https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-40775/B7282E74-76C1-4D0A-8FAE-CE97FC2330C2/iPhone17,3_26.0_23A341_Restore.ipsw
    https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-39165/E8E603F3-A2E2-4638-8067-394754896386/iPhone17,3_26.3_23D127_Restore.ipsw
    https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-90312/17B5C7BE-C560-43BD-BA9A-7DD1E5C2FC23/iPhone17,3_26.3.1_23D8133_Restore.ipsw
    https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-06082/FE21226A-B87F-4FC7-9D4B-B97A9EAF5C20/iPhone17,3_26.4_23E246_Restore.ipsw
    https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-28526/10E1E3EC-6A3E-4620-A569-8E0C4361AB77/iPhone17,3_26.4.1_23E254_Restore.ipsw
    https://updates.cdn-apple.com/2026SpringSeed/fullrestores/140-57108/5E816D0E-89BB-4B95-8825-6A3EDF22E509/iPhone17,3_27.0_24A5390f_Restore.ipsw
    https://updates.cdn-apple.com/2026SpringSeed/2d03d580-843b-4b2a-b09d-976b31c10744/iPhone17,3_27.0_24A5430a_Restore.ipsw
    https://updates.cdn-apple.com/2026FallFCS/2d0cd01d-b4f9-4a20-a1e8-f3be54570da7/iPhone17,3_27.0_24A435_Restore.ipsw
    https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-39165/E8E603F3-A2E2-4638-8067-394754896386/iPhone17,3_26.3_23D127_Restore.ipsw
    https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPad16,3_26.1_23B85_Restore.ipsw
    https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Custom_Restore.ipsw
    · Downloading iPhone17,3_26.1_23B85_Restore.ipsw
    """

    static let d = "iPhone17,3"
    static let url263 = "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-39165/E8E603F3-A2E2-4638-8067-394754896386/iPhone17,3_26.3_23D127_Restore.ipsw"

    static func lines(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    static let plain = VPhoneStatusStyle(isColored: false)
    static let colored = VPhoneStatusStyle(isColored: true)

    /// Writes `readme` to a scratch file, because the command-line half takes a
    /// path (that is what the shell hands it).
    static func withReadmeFile<T>(_ body: (String) throws -> T) rethrows -> T {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vphone-fwmatrix-\(UUID().uuidString).md")
        try? readme.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url.path)
    }
}

// MARK: - Goldens

private enum Golden {
    static let listPlain = Fixture.lines([
        "Available downloadable IPSWs for iPhone17,3:",
        "",
        "Status: Supported   Not Tested  Unsupported",
        "",
        "VERSION      BUILD      STATUS",
        "27.0         24A5430a   Not Tested\u{20}",
        "27.0         24A5390f   Supported\u{20}\u{20}",
        "27.0         24A435     Supported\u{20}\u{20}",
        "26.4.1       23E254     Not Tested\u{20}",
        "26.4         23E246     Supported\u{20}\u{20}",
        "26.3.1       23D8133    Supported\u{20}\u{20}",
        "26.3         23D127     Supported\u{20}\u{20}",
        "26.0         23A341     Supported\u{20}\u{20}",
        "18.6.2       22G100     Supported\u{20}\u{20}",
    ])

    static let listColored = Fixture.lines([
        "Available downloadable IPSWs for iPhone17,3:",
        "",
        "Status: \u{1B}[32mSupported  \u{1B}[0m \u{1B}[33mNot Tested \u{1B}[0m \u{1B}[31mUnsupported\u{1B}[0m",
        "",
        "VERSION      BUILD      STATUS",
        "27.0         24A5430a   \u{1B}[33mNot Tested \u{1B}[0m",
        "27.0         24A5390f   \u{1B}[32mSupported  \u{1B}[0m",
        "27.0         24A435     \u{1B}[32mSupported  \u{1B}[0m",
        "26.4.1       23E254     \u{1B}[33mNot Tested \u{1B}[0m",
        "26.4         23E246     \u{1B}[32mSupported  \u{1B}[0m",
        "26.3.1       23D8133    \u{1B}[32mSupported  \u{1B}[0m",
        "26.3         23D127     \u{1B}[32mSupported  \u{1B}[0m",
        "26.0         23A341     \u{1B}[32mSupported  \u{1B}[0m",
        "18.6.2       22G100     \u{1B}[32mSupported  \u{1B}[0m",
    ])

    /// The selector's status column is *not* padded — a real asymmetry between
    /// the two heredocs that the port has to keep.
    static let ambiguousColored = Fixture.lines([
        "Version 27.0 is ambiguous for iPhone17,3; specify one of these builds:",
        "BUILD      STATUS",
        "24A5430a   \u{1B}[33mNot Tested\u{1B}[0m",
        "24A5390f   \u{1B}[32mSupported\u{1B}[0m",
        "24A435     \u{1B}[32mSupported\u{1B}[0m",
    ])

    static let ambiguousPlain = Fixture.lines([
        "Version 27.0 is ambiguous for iPhone17,3; specify one of these builds:",
        "BUILD      STATUS",
        "24A5430a   Not Tested",
        "24A5390f   Supported",
        "24A435     Supported",
    ])

    static let hit = "26.3\t23D127\t\(Fixture.url263)\tSupported\n"
}

// MARK: - Byte-for-byte equivalence with the Python

struct FirmwareMatrixGoldenTests {
    @Test func listingMatchesPythonPlain() {
        let out = VPhoneFirmwareMatrix.listing(
            device: Fixture.d, readme: Fixture.readme,
            downloadURLs: Fixture.urls, style: Fixture.plain
        )
        #expect(out == .matrix(Golden.listPlain))
    }

    @Test func listingMatchesPythonColored() {
        let out = VPhoneFirmwareMatrix.listing(
            device: Fixture.d, readme: Fixture.readme,
            downloadURLs: Fixture.urls, style: Fixture.colored
        )
        #expect(out == .matrix(Golden.listColored))
    }

    @Test func ambiguousVersionMatchesPython() {
        for (style, golden) in [
            (Fixture.plain, Golden.ambiguousPlain),
            (Fixture.colored, Golden.ambiguousColored),
        ] {
            let out = VPhoneFirmwareMatrix.selection(
                device: Fixture.d, version: "27.0", build: "",
                readme: Fixture.readme, downloadURLs: Fixture.urls, style: style
            )
            #expect(out == .ambiguous(golden))
        }
    }

    @Test func resolvedSelectorMatchesPython() {
        let out = VPhoneFirmwareMatrix.selection(
            device: Fixture.d, version: "26.3", build: "",
            readme: Fixture.readme, downloadURLs: Fixture.urls, style: Fixture.colored
        )
        guard case let .selected(release, support) = out else {
            Issue.record("expected a selection, got \(out)")
            return
        }
        // The resolved line is plain even under colour — the shell reads it
        // back through `IFS=$'\t' read`, and an escape in field 4 would end up
        // in the "Status:" line it echoes.
        #expect(out.resolvedLine == Golden.hit)
        #expect(release.build == "23D127")
        #expect(support == .supported)
        // Only a hit has a line; the failure cases have nothing to hand back.
        #expect(VPhoneFirmwareMatrix.selection(
            device: Fixture.d, version: "99.9", build: "",
            readme: Fixture.readme, downloadURLs: Fixture.urls, style: Fixture.plain
        ).resolvedLine == nil)
    }

    @Test(arguments: [
        ("99.9", "", "Unsupported: no downloadable IPSW matched device=iPhone17,3 version=99.9\n"),
        ("", "99Z99", "Unsupported: no downloadable IPSW matched device=iPhone17,3 build=99Z99\n"),
        ("99.9", "99Z99", "Unsupported: no downloadable IPSW matched device=iPhone17,3 version=99.9 build=99Z99\n"),
    ])
    func missMatchesPython(version: String, build: String, expected: String) {
        let out = VPhoneFirmwareMatrix.selection(
            device: Fixture.d, version: version, build: build,
            readme: Fixture.readme, downloadURLs: Fixture.urls, style: Fixture.plain
        )
        #expect(out == .unmatched(expected))
        let colored = VPhoneFirmwareMatrix.selection(
            device: Fixture.d, version: version, build: build,
            readme: Fixture.readme, downloadURLs: Fixture.urls, style: Fixture.colored
        )
        #expect(colored == .unmatched("\u{1B}[31mUnsupported\u{1B}[0m" + expected.dropFirst("Unsupported".count)))
    }

    @Test func emptyDownloadListIsAnError() {
        let out = VPhoneFirmwareMatrix.listing(
            device: "iPhone99,9", readme: Fixture.readme,
            downloadURLs: Fixture.urls, style: Fixture.colored
        )
        // Plain even in colour, exactly as the Python printed it.
        #expect(out == .nothingDownloadable("No downloadable IPSWs found for iPhone99,9\n"))
    }
}

// MARK: - Parsing

struct FirmwareMatrixParsingTests {
    @Test func readsOnlyTheTestedEnvironmentsSectionAndOnlyThisDevice() {
        let tested = VPhoneFirmwareMatrix.testedBuilds(readme: Fixture.readme, device: Fixture.d)
        #expect(tested.count == 7)
        #expect(tested.contains(VPhoneFirmwareBuildID(version: "26.3.1", build: "23D8133")))
        // Before the heading.
        #expect(!tested.contains(VPhoneFirmwareBuildID(version: "99.9", build: "99Z99")))
        // After the next `## ` heading.
        #expect(!tested.contains(VPhoneFirmwareBuildID(version: "88.8", build: "88Z88")))
        // A different device's row inside the section.
        #expect(!tested.contains(VPhoneFirmwareBuildID(version: "26.1", build: "23B85")))
    }

    @Test func aMissingReadmeMeansNothingIsTested() {
        #expect(VPhoneFirmwareMatrix.testedBuilds(readme: nil, device: Fixture.d).isEmpty)
        let out = VPhoneFirmwareMatrix.listing(
            device: Fixture.d, readme: nil,
            downloadURLs: Fixture.urls, style: Fixture.plain
        )
        guard case let .matrix(text) = out else {
            Issue.record("expected a matrix")
            return
        }
        #expect(!text.contains("Supported\u{20}\u{20}\n"))
        #expect(text.components(separatedBy: "Not Tested").count == 1 + 9 + 1)
    }

    @Test func rejectsLookalikeURLs() {
        let found = VPhoneFirmwareMatrix.releases(downloadURLs: Fixture.urls, device: Fixture.d)
        // 9 real lines, 1 exact duplicate dropped, 3 lookalikes rejected.
        #expect(found.count == 9)
        #expect(!found.contains { $0.url.contains("iPad16,3") })
        #expect(!found.contains { $0.url.contains("_Custom_") })
        #expect(!found.contains { $0.build == "23B85" })
    }

    @Test func toleratesSurroundingWhitespaceAndBlankLines() {
        let urls = "\n   \(Fixture.url263)   \n\n"
        let found = VPhoneFirmwareMatrix.releases(downloadURLs: urls, device: Fixture.d)
        #expect(found.count == 1)
        // The URL is stored stripped, so the shell gets something it can fetch.
        #expect(found.first?.url == Fixture.url263)
    }

    @Test func parsesTheRepositoryCompatibilityGuide() throws {
        let tested = VPhoneFirmwareMatrix.testedBuilds(
            readme: try RealData.repositoryCompatibilityGuide(),
            device: Fixture.d
        )
        #expect(tested.count == 2)
        #expect(tested.contains(VPhoneFirmwareBuildID(version: "26.6.2", build: "23G90")))
        #expect(tested.contains(VPhoneFirmwareBuildID(version: "27.0", build: "24A435")))
        #expect(tested.allSatisfy { !$0.version.isEmpty && !$0.build.isEmpty })
        #expect(tested.allSatisfy { !$0.version.contains("`") && !$0.build.contains("`") })
    }
}

// MARK: - Real data

/// The repository's compatibility table joined against a real `ipsw download ipsw
/// --device iPhone17,3 --urls` capture — the two inputs the shell actually fed
/// the Python, rather than anything shaped to suit the parser.
///
/// The guide is read live, so these assert invariants rather than a golden: a
/// row added to the table must not turn the suite red for the agent who added
/// it. The cross-check is against a second parser written here on purpose in a
/// different style — column splitting instead of a regex — so a regex that
/// drifts has something independent to disagree with.
private enum RealData {
    static func repositoryCompatibilityGuide() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/guides/compatibility.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Captured 2026-09-23. 31 restore images, one build per version — which is
    /// why the selector's ambiguity branch cannot be reached from live data and
    /// is exercised from `Fixture` instead.
    static let liveURLs = """
    https://updates.cdn-apple.com/2026FallFCS/5130b3f9-3b4e-469a-b60e-93f6b310cdd9/iPhone17,3_27.0_24A437_Restore.ipsw
    https://updates.cdn-apple.com/2026SummerFCS/29d685ce-f70d-45a0-9823-b1cd115f3927/iPhone17,3_26.6.2_23G90_Restore.ipsw
    https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-93817/B5362BAA-F3EE-49C8-BA43-309F0DAD1362/iPhone17,3_26.6.1_23G83_Restore.ipsw
    https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-58193/1F477C3E-934B-43C0-B428-753B9E005EC0/iPhone17,3_26.6_23G71_Restore.ipsw
    https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-25549/1AFB1F72-E48E-476A-9C21-42B27C846C01/iPhone17,3_26.5.2_23F84_Restore.ipsw
    https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-63074/5E6B4A05-BDBC-45FE-9606-22B8F4315989/iPhone17,3_26.5_23F77_Restore.ipsw
    https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-60828/A4082066-CCC4-4903-89E6-FF4801EA609C/iPhone17,3_26.4.2_23E261_Restore.ipsw
    https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-28526/10E1E3EC-6A3E-4620-A569-8E0C4361AB77/iPhone17,3_26.4.1_23E254_Restore.ipsw
    https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-06082/FE21226A-B87F-4FC7-9D4B-B97A9EAF5C20/iPhone17,3_26.4_23E246_Restore.ipsw
    https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-90312/17B5C7BE-C560-43BD-BA9A-7DD1E5C2FC23/iPhone17,3_26.3.1_23D8133_Restore.ipsw
    https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-39165/E8E603F3-A2E2-4638-8067-394754896386/iPhone17,3_26.3_23D127_Restore.ipsw
    https://updates.cdn-apple.com/2025FallFCS/fullrestores/047-34150/D14FB1F1-B8C5-4A20-9250-8DD35EF19BF5/iPhone17,3_26.2.1_23C71_Restore.ipsw
    https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-90760/1214478F-8ED8-4AE0-B693-2F63CE0259A9/iPhone17,3_26.2_23C55_Restore.ipsw
    https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipsw
    https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-46329/C1717B2A-9E58-4131-A398-75D9B1D01A89/iPhone17,3_26.0.1_23A355_Restore.ipsw
    https://updates.cdn-apple.com/2025FallFCS/fullrestores/093-40775/B7282E74-76C1-4D0A-8FAE-CE97FC2330C2/iPhone17,3_26.0_23A341_Restore.ipsw
    https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-20738/98758B5A-311E-4538-B365-FEE3D8792CDF/iPhone17,3_18.6.2_22G100_Restore.ipsw
    https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-07229/D567EFF0-6D62-461A-9F66-B2EAE22C2DD8/iPhone17,3_18.6.1_22G90_Restore.ipsw
    https://updates.cdn-apple.com/2025SummerFCS/fullrestores/082-98952/853D36FA-A5F4-4B75-B5F3-8D38430F6132/iPhone17,3_18.6_22G86_Restore.ipsw
    https://updates.cdn-apple.com/2025SpringFCS/fullrestores/082-46019/A46C805A-4915-4552-BFD4-EFD1C7BE665E/iPhone17,3_18.5_22F76_Restore.ipsw
    https://updates.cdn-apple.com/2025SpringFCS/fullrestores/082-30380/AD76C77E-51AA-4D55-A074-9C0E7545D784/iPhone17,3_18.4.1_22E252_Restore.ipsw
    https://updates.cdn-apple.com/2025SpringFCS/fullrestores/082-14688/8DC47FED-F5B6-4BE6-B75F-8E36BCC5A484/iPhone17,3_18.4_22E240_Restore.ipsw
    https://updates.cdn-apple.com/2025WinterFCS/fullrestores/082-03679/DA16409C-A02F-46E9-ADE9-ED32BDD47539/iPhone17,3_18.3.2_22D82_Restore.ipsw
    https://updates.cdn-apple.com/2025WinterFCS/fullrestores/072-85742/283FD833-D2EF-4A97-AE6F-406E1DD998DA/iPhone17,3_18.3.1_22D72_Restore.ipsw
    https://updates.cdn-apple.com/2025WinterFCS/fullrestores/072-68251/8CC707F3-9926-4ECC-B7F6-3497FE282048/iPhone17,3_18.3_22D63_Restore.ipsw
    https://updates.cdn-apple.com/2024FallFCS/fullrestores/072-55500/A62CEE9F-875F-4E53-9C9D-D4172E30BE88/iPhone17,3_18.2.1_22C161_Restore.ipsw
    https://updates.cdn-apple.com/2024FallFCS/fullrestores/072-42011/88CB7A92-6959-4FB4-A87E-77CE7CB8BB82/iPhone17,3_18.2_22C152_Restore.ipsw
    https://updates.cdn-apple.com/2024FallFCS/fullrestores/072-31863/D2DE541A-DC63-4016-9B22-0EED8A753FB9/iPhone17,3_18.1.1_22B91_Restore.ipsw
    https://updates.cdn-apple.com/2024FallFCS/fullrestores/072-12560/4A88CBAB-2F24-4173-BCFD-210325515BCA/iPhone17,3_18.1_22B83_Restore.ipsw
    https://updates.cdn-apple.com/2024FallFCS/fullrestores/072-02193/DD4AADB5-492C-442E-8E79-42D72EDAF958/iPhone17,3_18.0.1_22A3370_Restore.ipsw
    https://updates.cdn-apple.com/2024FallFCS/fullrestores/062-77769/2A2DBD27-47A6-40DB-AEF5-E283454A67E8/iPhone17,3_18.0_22A3354_Restore.ipsw
    """

    /// The same table, read by splitting on `|` and `_` instead of by regex.
    static func testedBuildsByColumnSplitting(
        in readme: String,
        deviceSuffix: String
    ) -> Set<VPhoneFirmwareBuildID> {
        // A different way to find the section too: cut the document at its `## `
        // headings rather than scanning line by line for them.
        let sections = readme.components(separatedBy: "\n## ")
        guard let table = sections.first(where: { $0.hasPrefix("Tested Environments") })
        else { return [] }

        var tested: Set<VPhoneFirmwareBuildID> = []
        for row in table.components(separatedBy: "\n") {
            for cell in row.components(separatedBy: "|") {
                let trimmed = cell.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("`"), trimmed.hasSuffix("`"), trimmed.count > 2
                else { continue }
                let fields = trimmed.dropFirst().dropLast().components(separatedBy: "_")
                guard fields.count == 3, fields[0] == deviceSuffix else { continue }
                tested.insert(VPhoneFirmwareBuildID(version: fields[1], build: fields[2]))
            }
        }
        return tested
    }
}

struct FirmwareMatrixRealDataTests {
    @Test func theCompatibilityParserAgreesWithAnIndependentColumnSplitter() throws {
        let readme = try RealData.repositoryCompatibilityGuide()
        let byRegex = VPhoneFirmwareMatrix.testedBuilds(readme: readme, device: Fixture.d)
        let bySplitting = RealData.testedBuildsByColumnSplitting(in: readme, deviceSuffix: "17,3")
        #expect(!bySplitting.isEmpty, "the compatibility table moved — fix the test, not the parser")
        #expect(byRegex == bySplitting)
    }

    @Test func aLiveDownloadCaptureParsesWholeAndJoinsAgainstTheGuide() throws {
        let releases = VPhoneFirmwareMatrix.releases(
            downloadURLs: RealData.liveURLs,
            device: Fixture.d
        )
        // Every line of the capture is a restore image for this device, so the
        // URL parser has to claim all 31 — a silent drop is the failure mode
        // that would quietly hide a firmware from `--list`.
        #expect(releases.count == RealData.liveURLs.components(separatedBy: "\n").count)
        #expect(releases.count == 31)
        #expect(Set(releases.map(\.build)).count == 31)

        let tested = VPhoneFirmwareMatrix.testedBuilds(readme: try RealData.repositoryCompatibilityGuide(), device: Fixture.d)
        var supported = 0, notTested = 0
        for release in releases {
            let id = VPhoneFirmwareBuildID(version: release.version, build: release.build)
            switch VPhoneFirmwareMatrix.support(of: release, tested: tested) {
            case .supported:
                #expect(tested.contains(id))
                supported += 1
            case .notTested:
                #expect(!tested.contains(id))
                notTested += 1
            case .unsupported:
                Issue.record("a listing row must never be Unsupported")
            }
        }
        // Neither count may be zero, or the loop above proved nothing.
        #expect(supported > 0)
        #expect(notTested > 0)
    }

    /// Apple serves one build per version, so `--list` over live data is fully
    /// ordered by version alone. This is the property the shell's `sorted(…,
    /// reverse=True)` was there to produce.
    @Test func theLiveCaptureListsNewestFirst() {
        let out = VPhoneFirmwareMatrix.listing(
            device: Fixture.d, readme: nil,
            downloadURLs: RealData.liveURLs, style: Fixture.plain
        )
        guard case let .matrix(text) = out else {
            Issue.record("expected a matrix")
            return
        }
        let versions = text.components(separatedBy: "\n")
            .dropFirst(5)
            .compactMap { $0.split(separator: " ").first.map(String.init) }
        #expect(versions.first == "27.0")
        #expect(versions.last == "18.0")
        // 26.6.2 above 26.6, and 26.2.1 above 26.2: a plain string sort puts
        // both the other way round.
        let index = { (v: String) in versions.firstIndex(of: v) ?? -1 }
        #expect(index("26.6.2") < index("26.6"))
        #expect(index("26.2.1") < index("26.2"))
        #expect(index("26.0.1") < index("26.0"))
        #expect(index("26.0") < index("18.6.2"))
    }
}

// MARK: - Ordering

struct FirmwareMatrixOrderingTests {
    private func release(_ version: String, _ build: String) -> VPhoneFirmwareRelease {
        VPhoneFirmwareRelease(version: version, build: build, url: "/\(version)_\(build)")
    }

    @Test func sortsVersionsNewestFirstWithNumericComponents() {
        // Lexically "18.6.2" > "26.0" and "26.4.1" > "26.4"; numerically neither.
        let sorted = [
            release("26.4", "a"), release("18.6.2", "a"), release("26.4.1", "a"),
            release("27.0", "a"), release("26.0", "a"), release("26.10", "a"),
        ].sorted { VPhoneFirmwareMatrix.isNewer($0, than: $1) }
        #expect(sorted.map(\.version) == ["27.0", "26.10", "26.4.1", "26.4", "26.0", "18.6.2"])
    }

    @Test func sortsBuildsByCodePointDescending() {
        // 24A435 vs 24A5430a is the case that separates a string sort from a
        // "looks numeric" one: '4' < '5' at index 3, so 24A5430a wins.
        let sorted = [
            release("27.0", "24A435"), release("27.0", "24A5430a"), release("27.0", "24A5390f"),
        ].sorted { VPhoneFirmwareMatrix.hasHigherBuild($0, than: $1) }
        #expect(sorted.map(\.build) == ["24A5430a", "24A5390f", "24A435"])
    }

    @Test func aShorterVersionSortsBelowItsOwnPrefixExtension() {
        #expect(VPhoneFirmwareMatrix.isNewer(release("26.4.1", "a"), than: release("26.4", "a")))
        #expect(!VPhoneFirmwareMatrix.isNewer(release("26.4", "a"), than: release("26.4.1", "a")))
    }

    @Test func nonNumericComponentsStillOrder() {
        #expect(VPhoneFirmwareMatrix.versionKey("26.beta") == [.number(26), .text("beta")])
        #expect(VPhoneFirmwareMatrix.versionKey("") == [.text("")])
        #expect(VPhoneFirmwareMatrix.VersionPart.number(9) < .text("0"))
    }
}

// MARK: - Column padding

struct FirmwareMatrixPaddingTests {
    @Test func leftJustifyingNeverTruncates() {
        // `String.padding(toLength:)` would cut this to 12 and lose the build.
        #expect(VPhoneFirmwareMatrix.leftJustified("27.0.1.2.3.4.5", 12) == "27.0.1.2.3.4.5")
        #expect(VPhoneFirmwareMatrix.leftJustified("26.3", 12) == "26.3        ")
        #expect(VPhoneFirmwareMatrix.leftJustified("", 3) == "   ")
    }

    @Test func paddingGoesInsideTheColourEscape() {
        // Outside the escape the text would be the same width on screen but a
        // different byte string, and every golden above would break.
        #expect(Fixture.colored.render(.supported, width: 11) == "\u{1B}[32mSupported  \u{1B}[0m")
        #expect(Fixture.colored.render(.supported) == "\u{1B}[32mSupported\u{1B}[0m")
        #expect(Fixture.plain.render(.supported, width: 11) == "Supported  ")
    }

    @Test func anOverlongVersionStillLeavesOneSpaceBeforeTheNextColumn() {
        let urls = "/iPhone17,3_26.4.10.20.30_23E246_Restore.ipsw"
        let out = VPhoneFirmwareMatrix.listing(
            device: Fixture.d, readme: nil, downloadURLs: urls, style: Fixture.plain
        )
        guard case let .matrix(text) = out else {
            Issue.record("expected a matrix")
            return
        }
        #expect(text.contains("26.4.10.20.30 23E246     Not Tested\u{20}\n"))
    }
}

// MARK: - Colour policy

struct FirmwareMatrixColorPolicyTests {
    /// A pty master is a terminal; a pipe is not. Both are real file
    /// descriptors, so `isatty` is answering for real here.
    private func withTTY<T>(_ body: (Int32) throws -> T) rethrows -> T {
        let fd = posix_openpt(O_RDWR | O_NOCTTY)
        defer { if fd >= 0 { close(fd) } }
        return try body(fd)
    }

    @Test func honoursNoColorClicolorForceAndIsattyPerStream() throws {
        let pipe = Pipe()
        let pipeFD = pipe.fileHandleForWriting.fileDescriptor
        try withTTY { ttyFD in
            try #require(isatty(ttyFD) != 0, "expected a pty master to be a terminal")
            #expect(isatty(pipeFD) == 0)

            func colored(_ fd: Int32, _ env: [String: String]) -> Bool {
                VPhoneStatusStyle.forStream(fd, environment: env).isColored
            }

            // A terminal colours by default; a pipe does not.
            #expect(colored(ttyFD, [:]))
            #expect(!colored(pipeFD, [:]))

            // CLICOLOR_FORCE=1 colours a pipe; any other value does not.
            #expect(colored(pipeFD, ["CLICOLOR_FORCE": "1"]))
            #expect(!colored(pipeFD, ["CLICOLOR_FORCE": "0"]))
            #expect(!colored(pipeFD, ["CLICOLOR_FORCE": "true"]))
            #expect(!colored(pipeFD, ["CLICOLOR_FORCE": ""]))

            // NO_COLOR wins over both the terminal and CLICOLOR_FORCE …
            #expect(!colored(ttyFD, ["NO_COLOR": "1"]))
            #expect(!colored(pipeFD, ["NO_COLOR": "1", "CLICOLOR_FORCE": "1"]))
            // … but only when it is set to something. Empty is "not set", which
            // is how both the shell (`-z`) and the Python (falsy) read it.
            #expect(colored(ttyFD, ["NO_COLOR": ""]))
            #expect(!colored(pipeFD, ["NO_COLOR": ""]))
        }
        try pipe.fileHandleForWriting.close()
        try pipe.fileHandleForReading.close()
    }
}

// MARK: - Exit codes and stream routing

struct FirmwareMatrixCommandLineTests {
    private func capture(
        _ body: (FileHandle, FileHandle) -> Int32
    ) -> (code: Int32, out: String, err: String) {
        let outPipe = Pipe(), errPipe = Pipe()
        let code = body(outPipe.fileHandleForWriting, errPipe.fileHandleForWriting)
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (code, out, err)
    }

    @Test func listGoesToStdoutAndExitsZero() {
        let r = Fixture.withReadmeFile { path in
            capture { out, err in
                VPhoneFirmwareMatrixCommandLine.list(
                    device: Fixture.d, readmePath: path, downloadURLs: Fixture.urls,
                    environment: [:], stdout: out, stderr: err
                )
            }
        }
        #expect(r.code == 0)
        #expect(r.out == Golden.listPlain)
        #expect(r.err.isEmpty)
    }

    @Test func anEmptyDeviceListGoesToStderrAndExitsOne() {
        let r = Fixture.withReadmeFile { path in
            capture { out, err in
                VPhoneFirmwareMatrixCommandLine.list(
                    device: "iPhone99,9", readmePath: path, downloadURLs: Fixture.urls,
                    environment: [:], stdout: out, stderr: err
                )
            }
        }
        #expect(r.code == 1)
        #expect(r.out.isEmpty)
        #expect(r.err == "No downloadable IPSWs found for iPhone99,9\n")
    }

    @Test func aResolvedSelectorGoesToStdoutAndExitsZero() {
        let r = Fixture.withReadmeFile { path in
            capture { out, err in
                VPhoneFirmwareMatrixCommandLine.resolve(
                    device: Fixture.d, version: "26.3", build: "", readmePath: path,
                    downloadURLs: Fixture.urls, environment: [:], stdout: out, stderr: err
                )
            }
        }
        #expect(r.code == 0)
        #expect(r.out == Golden.hit)
        #expect(r.err.isEmpty)
    }

    /// 2, not 1. `fw_prepare.sh` forwards this status verbatim so a caller can
    /// tell "pick a build" from "there is no such firmware".
    @Test func anAmbiguousVersionGoesToStderrAndExitsTwo() {
        let r = Fixture.withReadmeFile { path in
            capture { out, err in
                VPhoneFirmwareMatrixCommandLine.resolve(
                    device: Fixture.d, version: "27.0", build: "", readmePath: path,
                    downloadURLs: Fixture.urls, environment: [:], stdout: out, stderr: err
                )
            }
        }
        #expect(r.code == 2)
        #expect(r.out.isEmpty)
        #expect(r.err == Golden.ambiguousPlain)
    }

    @Test func aMissGoesToStderrAndExitsOne() {
        let r = Fixture.withReadmeFile { path in
            capture { out, err in
                VPhoneFirmwareMatrixCommandLine.resolve(
                    device: Fixture.d, version: "99.9", build: "", readmePath: path,
                    downloadURLs: Fixture.urls, environment: [:],
                    stdout: out, stderr: err
                )
            }
        }
        #expect(r.code == 1)
        #expect(r.out.isEmpty)
        #expect(r.err == "Unsupported: no downloadable IPSW matched device=iPhone17,3 version=99.9\n")
    }

    @Test func anUnreadableReadmePathIsNotAnError() {
        let r = capture { out, err in
            VPhoneFirmwareMatrixCommandLine.list(
                device: Fixture.d, readmePath: "/nonexistent/README.md",
                downloadURLs: Fixture.urls, environment: [:], stdout: out, stderr: err
            )
        }
        #expect(r.code == 0)
        #expect(r.out.contains("Not Tested"))
        #expect(!r.out.contains("Supported\u{20}\u{20}\n"))
    }

    /// The half that is easy to get wrong: each command styles the stream it
    /// writes to, not the process. `list` writes its table to stdout, so a
    /// terminal on stderr must not colour it.
    @Test func listStylesStdoutNotStderr() throws {
        let fd = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(fd >= 0)
        defer { close(fd) }
        let tty = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let outPipe = Pipe()
        let code = Fixture.withReadmeFile { path in
            VPhoneFirmwareMatrixCommandLine.list(
                device: Fixture.d, readmePath: path, downloadURLs: Fixture.urls,
                environment: [:], stdout: outPipe.fileHandleForWriting, stderr: tty
            )
        }
        try outPipe.fileHandleForWriting.close()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(code == 0)
        #expect(out == Golden.listPlain)
        #expect(!out.contains("\u{1B}["))
    }

    /// And the mirror image: the selector's failures are stderr's, so a
    /// terminal on stdout must not colour them. This is the case that keeps
    /// escapes out of `selection="$(resolve_selector_from_downloads …)"`.
    @Test func resolveStylesStderrNotStdout() throws {
        let fd = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(fd >= 0)
        defer { close(fd) }
        let tty = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let errPipe = Pipe()
        let code = Fixture.withReadmeFile { path in
            VPhoneFirmwareMatrixCommandLine.resolve(
                device: Fixture.d, version: "99.9", build: "", readmePath: path,
                downloadURLs: Fixture.urls, environment: [:],
                stdout: tty, stderr: errPipe.fileHandleForWriting
            )
        }
        try errPipe.fileHandleForWriting.close()
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(code == 1)
        #expect(err == "Unsupported: no downloadable IPSW matched device=iPhone17,3 version=99.9\n")
        #expect(!err.contains("\u{1B}["))
    }
}
