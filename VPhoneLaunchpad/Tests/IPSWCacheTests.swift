import Foundation

/// The Downloaded IPSWs sheet's IPSW reading, cache listing, deletion rules
/// and safe removal, against fixtures made in a temporary folder.
@main
struct IPSWCacheTests {
    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        precondition(condition, "line \(line): \(message())")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipsw-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The shared IPSW cache is looked up under VPHONE_ROOT; keep it in the fixture.
        setenv("VPHONE_ROOT", root.appendingPathComponent("data").path, 1)

        fileNames()
        try zips(in: root)
        try await listing(in: root)
        try await removal(in: root)
        uses()
        deletion()
        rows()
        print("IPSWCacheTests passed")
    }

    // MARK: - IPSW names

    static func fileNames() {
        let cached = VPhoneLaunchpadIPSW(fileName: "iPhone17_3_27.0_24A435_Restore-3c6d6dc0803d.ipsw")
        expect(cached?.productTypes == ["iPhone17,3"], "\(String(describing: cached?.productTypes))")
        expect(cached?.version == "27.0" && cached?.build == "24A435", "cached version and build")
        expect(cached?.kind == .iPhone && cached?.title == "iOS 27.0 (24A435)", "cached kind and title")
        expect(cached?.fromManifest == false, "name facts are guesses")

        let pad = VPhoneLaunchpadIPSW(fileName: "iPad16,1,iPad16,2_26.6.2_23G90_Restore.ipsw")
        expect(pad?.productTypes == ["iPad16,1", "iPad16,2"], "\(String(describing: pad?.productTypes))")
        expect(pad?.kind == .iPad && pad?.title == "iPadOS 26.6.2 (23G90)", "iPad title")

        let cachedPad = VPhoneLaunchpadIPSW(fileName: "iPad16_1_iPad16_2_26.6.2_23G90_Restore-0123456789ab.ipsw")
        expect(cachedPad?.productTypes == ["iPad16,1", "iPad16,2"], "\(String(describing: cachedPad?.productTypes))")

        expect(VPhoneLaunchpadIPSW(fileName: "c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ad-b80d96a0b616.ipsw") == nil, "hash name")
        expect(VPhoneLaunchpadIPSW(fileName: "notes.txt") == nil, "not an IPSW")
        expect(VPhoneLaunchpadIPSW.productTypes(in: "iPhoneOS_iPad16,1") == ["iPad16,1"], "tree name products")

        let beta = VPhoneLaunchpadIPSW(version: "26.4", build: "23E5207q", productTypes: [], deviceClasses: ["vresearch101ap"], fromManifest: true)
        expect(beta.kind == .cloudOS, "cloudOS beta")

        // The names `fw prepare` gave two real downloads (`VPhoneIPSWCache.cacheName`).
        let rc = URL(string: "https://updates.cdn-apple.com/2026FallFCS/2d0cd01d-b4f9-4a20-a1e8-f3be54570da7/iPhone17,3_27.0_24A435_Restore.ipsw")!
        expect(VPhoneLaunchpadIPSW.cacheName(for: rc) == "iPhone17_3_27.0_24A435_Restore-3c6d6dc0803d.ipsw", VPhoneLaunchpadIPSW.cacheName(for: rc))
        let point = URL(string: "https://updates.cdn-apple.com/2026FallFCS/38dca0ee-bb5d-4132-ad13-62d57bcd6d32/iPhone17,3_27.0.1_24A446_Restore.ipsw")!
        expect(VPhoneLaunchpadIPSW.cacheName(for: point) == "iPhone17_3_27.0.1_24A446_Restore-1c2c1e8da8de.ipsw", VPhoneLaunchpadIPSW.cacheName(for: point))

        let uuid = UUID().uuidString
        expect(VPhoneLaunchpadIPSW.finalName(ofPartial: ".a-0123456789ab.ipsw.\(uuid).partial") == "a-0123456789ab.ipsw", "partial name")
        expect(VPhoneLaunchpadIPSW.finalName(ofPartial: ".a.ipsw.partial") == nil, "partial without UUID")
        expect(VPhoneLaunchpadIPSW.finalName(ofPartial: "a.ipsw") == nil, "not partial")
        expect(VPhoneLaunchpadIPSW.finalName(ofPartial: "..\(uuid).partial") == nil, "partial without a final name")
    }

    // MARK: - Zip

    static var cloudManifest: [String: Any] {
        [
            "ProductVersion": "26.4",
            "ProductBuildVersion": "23E5207q",
            "SupportedProductTypes": ["ComputeModule14,1"],
            "BuildIdentities": [
                ["Info": ["DeviceClass": "VRESEARCH101AP"]],
                ["Info": ["DeviceClass": "vphone600ap"]],
            ],
        ]
    }

    static func manifestData(_ plist: [String: Any]) throws -> Data {
        // Padding that deflates well, so the member is really compressed.
        var plist = plist
        plist["Padding"] = String(repeating: "BuildIdentity ", count: 4000)
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func zip(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        expect(process.terminationStatus == 0, "zip \(arguments)")
    }

    static func zips(in root: URL) throws {
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try manifestData(cloudManifest).write(to: source.appendingPathComponent("BuildManifest.plist"))
        try Data(repeating: 7, count: 100_000).write(to: source.appendingPathComponent("Firmware.bin"))

        for (name, level) in [("deflated.ipsw", "-6"), ("stored.ipsw", "-0")] {
            try zip(["-q", level, "../\(name)", "Firmware.bin", "BuildManifest.plist"], in: source)
            let facts = try VPhoneLaunchpadIPSW.read(root.appendingPathComponent(name))
            expect(facts.version == "26.4" && facts.build == "23E5207q", "\(name) version")
            expect(facts.kind == .cloudOS && facts.fromManifest, "\(name) is a cloudOS")
            expect(facts.title == "cloudOS 26.4 (23E5207q)", "\(name) title")
        }

        let zip64 = root.appendingPathComponent("zip64.ipsw")
        let iPhone: [String: Any] = [
            "ProductVersion": "26.6.2", "ProductBuildVersion": "23G90",
            "SupportedProductTypes": ["iPhone17,3"],
            "BuildIdentities": [["Info": ["DeviceClass": "d47ap"]]],
        ]
        try zip64Archive(member: "BuildManifest.plist", contents: manifestData(iPhone)).write(to: zip64)
        let facts = try VPhoneLaunchpadIPSW.read(zip64)
        expect(facts.kind == .iPhone && facts.productTypes == ["iPhone17,3"] && facts.build == "23G90", "ZIP64 manifest")

        let notZip = root.appendingPathComponent("broken.ipsw")
        try Data(repeating: 0, count: 4096).write(to: notZip)
        expect((try? VPhoneLaunchpadIPSW.read(notZip)) == nil, "not a zip")
    }

    /// A one-member stored archive whose entry and end record go through
    /// ZIP64, as an IPSW over 4 GB has them.
    static func zip64Archive(member: String, contents: Data) -> Data {
        var data = Data()
        func le16(_ value: Int) {
            withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) }
        }
        func le32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func le64(_ value: Int) {
            withUnsafeBytes(of: UInt64(value).littleEndian) { data.append(contentsOf: $0) }
        }
        let name = Data(member.utf8)

        le32(0x0403_4B50); le16(45); le16(0); le16(0); le16(0); le16(0); le32(0)
        le32(UInt32(contents.count)); le32(UInt32(contents.count)); le16(name.count); le16(0)
        data.append(name)
        data.append(contents)

        let directory = data.count
        le32(0x0201_4B50); le16(45); le16(45); le16(0); le16(0); le16(0); le16(0); le32(0)
        le32(.max); le32(.max); le16(name.count); le16(4 + 24); le16(0); le16(0); le16(0); le32(0); le32(.max)
        data.append(name)
        le16(1); le16(24); le64(contents.count); le64(contents.count); le64(0)
        let directorySize = data.count - directory

        let record = data.count
        le32(0x0606_4B50); le64(44); le16(45); le16(45); le32(0); le32(0)
        le64(1); le64(1); le64(directorySize); le64(directory)
        le32(0x0706_4B50); le32(0); le64(record); le32(1)
        le32(0x0605_4B50); le16(0); le16(0); le16(0xFFFF); le16(0xFFFF); le32(.max); le32(.max); le16(0)
        return data
    }

    // MARK: - Listing

    static func listing(in root: URL) async throws {
        let manager = FileManager.default
        let shared = VPhoneLaunchpadIPSWCache.sharedDirectory
        expect(shared.path == root.appendingPathComponent("data/ipsws").path, shared.path)
        try manager.createDirectory(at: shared, withIntermediateDirectories: true)

        let cache = root.appendingPathComponent("ipsws", isDirectory: true)
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        try manager.copyItem(at: root.appendingPathComponent("deflated.ipsw"), to: cache.appendingPathComponent("c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ad-b80d96a0b616.ipsw"))
        try Data(repeating: 5, count: 1000).write(to: cache.appendingPathComponent(".iPhone17_3_27.0_24A435_Restore-3c6d6dc0803d.ipsw.\(UUID().uuidString).partial"))
        try Data(repeating: 6, count: 10).write(to: cache.appendingPathComponent("readme.txt"))
        try Data(repeating: 6, count: 10).write(to: cache.appendingPathComponent(".hidden.ipsw"))
        // A link with an IPSW's name is not listed, and its target is not read.
        try manager.createSymbolicLink(at: cache.appendingPathComponent("link.ipsw"), withDestinationURL: root.appendingPathComponent("stored.ipsw"))

        let files = try VPhoneLaunchpadIPSWCache.ipsws(in: cache)
        expect(files.count == 2, "\(files.map(\.name))")
        let cloud = files.first { !$0.isDownloading }
        expect(cloud?.facts?.kind == .cloudOS && cloud?.facts?.fromManifest == true, "cached cloudOS read from its manifest")
        let partial = files.first(where: \.isDownloading)
        expect(partial?.name == "iPhone17_3_27.0_24A435_Restore-3c6d6dc0803d.ipsw" && partial?.facts?.kind == .iPhone, "download in progress")
        expect(partial?.size == 1000, "partial size")

        // The `ipsws` folder beside a library is a cache too, once and only
        // when it exists; the shared cache comes first.
        let library = root.appendingPathComponent("machines", isDirectory: true).path
        let missing = root.appendingPathComponent("elsewhere/machines", isDirectory: true).path
        let sharedLibrary = root.appendingPathComponent("data/machines", isDirectory: true).path
        let directories = VPhoneLaunchpadIPSWCache.cacheDirectories(libraryRoots: [sharedLibrary, library, library, missing])
        expect(directories.map(\.standardizedFileURL.path) == [shared.path, cache.path], "\(directories.map(\.path))")

        // A machine's product type: config.plist first, the restore tree kept
        // in FirmwareOriginals otherwise.
        let pad = root.appendingPathComponent("machines/ipad-lab", isDirectory: true)
        try manager.createDirectory(at: pad, withIntermediateDirectories: true)
        expect((["guestProductType": "iPad16,1"] as NSDictionary).write(to: pad.appendingPathComponent("config.plist"), atomically: true), "config.plist")
        let phone = root.appendingPathComponent("machines/phone", isDirectory: true)
        try manager.createDirectory(at: phone.appendingPathComponent("FirmwareOriginals/iPhone17,3_26.6.2_23G90_Restore", isDirectory: true), withIntermediateDirectories: true)
        expect((["diskImage": "Disk.img"] as NSDictionary).write(to: phone.appendingPathComponent("config.plist"), atomically: true), "config.plist")
        expect(VPhoneLaunchpadIPSWCache.guestProductType(in: pad) == "iPad16,1", "config product type")
        expect(VPhoneLaunchpadIPSWCache.guestProductType(in: phone) == "iPhone17,3", "FirmwareOriginals product type")

        let scan = try await VPhoneLaunchpadIPSWCache.scan(libraryRoots: [library], machineFolders: [pad, phone])
        expect(scan.ipsws.count == 2 && scan.cacheDirectories.count == 2, "\(scan.ipsws.map(\.name))")
        expect(scan.productTypes[pad.path] == "iPad16,1" && scan.productTypes[phone.path] == "iPhone17,3", "\(scan.productTypes)")
    }

    // MARK: - Removal

    /// Only a regular file directly in a cache folder, named as an IPSW or a
    /// partial download, is deleted.
    static func removal(in root: URL) async throws {
        let manager = FileManager.default
        let cache = root.appendingPathComponent("ipsw-delete", isDirectory: true)
        let other = root.appendingPathComponent("ipsw-delete-other", isDirectory: true)
        let nested = cache.appendingPathComponent("nested", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        let ipsw = cache.appendingPathComponent("iPhone17,3_27.0_24A435_Restore.ipsw")
        let partial = cache.appendingPathComponent(".iPad16,1_27.0.1_24A446_Restore.ipsw.\(UUID().uuidString).partial")
        let notes = cache.appendingPathComponent("notes.txt")
        let hidden = cache.appendingPathComponent(".hidden.ipsw")
        let deeper = nested.appendingPathComponent("deeper.ipsw")
        let outside = other.appendingPathComponent("kept.ipsw")
        let target = other.appendingPathComponent("target.ipsw")
        let link = cache.appendingPathComponent("link.ipsw")
        let folder = cache.appendingPathComponent("folder.ipsw", isDirectory: true)
        for file in [ipsw, partial, notes, hidden, deeper, outside, target] {
            try Data("x".utf8).write(to: file)
        }
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        func refused(_ url: URL, _ message: String) async {
            do {
                try await VPhoneLaunchpadIPSWCache.removeIPSW(url, cacheDirectories: [cache])
                expect(false, message)
            } catch is VPhoneLaunchpadIPSWCache.RemovalError {} catch {
                expect(false, "\(message): \(error)")
            }
        }
        await refused(notes, "not an IPSW")
        await refused(hidden, "a hidden file that is not a partial download")
        await refused(deeper, "not directly in the cache")
        await refused(outside, "outside the cache")
        await refused(link, "a symbolic link")
        await refused(folder, "a folder")
        await refused(cache.appendingPathComponent("gone.ipsw"), "missing file")
        await refused(cache.appendingPathComponent("nested/../../ipsw-delete-other/kept.ipsw"), "a path out of the cache")
        // Listed as a regular file, then replaced by a link before the delete.
        let swapped = cache.appendingPathComponent("swapped.ipsw")
        try Data("x".utf8).write(to: swapped)
        let listed = try VPhoneLaunchpadIPSWCache.ipsws(in: cache).first { $0.name == "swapped.ipsw" }
        expect(listed != nil, "swapped listed")
        try manager.removeItem(at: swapped)
        try manager.createSymbolicLink(at: swapped, withDestinationURL: target)
        await refused(listed!.url, "a file replaced by a link since it was listed")

        try await VPhoneLaunchpadIPSWCache.removeIPSW(ipsw, cacheDirectories: [cache])
        try await VPhoneLaunchpadIPSWCache.removeIPSW(partial, cacheDirectories: [cache])
        expect(!manager.fileExists(atPath: ipsw.path) && !manager.fileExists(atPath: partial.path), "IPSW and partial deleted")
        for kept in [notes, hidden, deeper, outside, target, folder] {
            expect(manager.fileExists(atPath: kept.path), "\(kept.lastPathComponent) kept")
        }
        expect((try? manager.destinationOfSymbolicLink(atPath: link.path)) != nil, "link kept")
    }

    // MARK: - Uses

    static func file(_ name: String, _ facts: VPhoneLaunchpadIPSW?, downloading: Bool = false) -> VPhoneLaunchpadIPSWFile {
        VPhoneLaunchpadIPSWFile(
            url: URL(fileURLWithPath: "/cache/\(name)"),
            name: name,
            size: 10_000_000_000,
            facts: facts,
            isDownloading: downloading,
        )
    }

    static let padFile = file("iPad16,1,iPad16,2_26.6.2_23G90_Restore.ipsw", VPhoneLaunchpadIPSW(version: "26.6.2", build: "23G90", productTypes: ["iPad16,1", "iPad16,2"], deviceClasses: ["j717ap"], fromManifest: true))
    static let phoneFile = file("iPhone17_3_27.0_24A435_Restore-3c6d6dc0803d.ipsw", VPhoneLaunchpadIPSW(fileName: "iPhone17_3_27.0_24A435_Restore-3c6d6dc0803d.ipsw"))
    static let cloudFile = file("c0ecdb4b-b80d96a0b616.ipsw", VPhoneLaunchpadIPSW(version: "26.4", build: "23E5207q", productTypes: [], deviceClasses: ["vresearch101ap", "vphone600ap"], fromManifest: true))
    static let unknownFile = file("mystery.ipsw", nil)
    static let rcSource = "https://updates.cdn-apple.com/2026FallFCS/2d0cd01d-b4f9-4a20-a1e8-f3be54570da7/iPhone17,3_27.0_24A435_Restore.ipsw"

    static func uses() {
        let release = VPhoneLaunchpadIPSWUse.Release(version: "26.6.2", build: "23G90")
        let cloud = VPhoneLaunchpadIPSWUse.Release(version: "26.4", build: "23E5207q")
        let pad = VPhoneLaunchpadIPSWUse(machine: "ipad-mini-01", productType: "iPad16,1", ios: release, cloudOS: cloud)
        let otherPad = VPhoneLaunchpadIPSWUse(machine: "ipad-pro-13", productType: "iPad17,3", ios: release, cloudOS: cloud)
        let creating = VPhoneLaunchpadIPSWUse(machine: "phone", sources: [rcSource], isCreating: true)
        expect(pad.uses(padFile) && !otherPad.uses(padFile), "iPad match by product type")
        expect(pad.uses(cloudFile) && otherPad.uses(cloudFile), "cloudOS match by build")
        expect(creating.uses(phoneFile) && !creating.uses(padFile), "creation source match")
        expect(!pad.uses(unknownFile), "unknown file")
        expect(VPhoneLaunchpadIPSWUse.source("/cache/mystery.ipsw", is: unknownFile), "local source match")
        expect(VPhoneLaunchpadIPSWUse.source("file:///cache/mystery.ipsw", is: unknownFile), "file URL source match")
        expect(!VPhoneLaunchpadIPSWUse.source("/elsewhere/mystery.ipsw", is: unknownFile), "another local file")
    }

    // MARK: - Deletion rules

    /// A restored machine does not need its IPSW; a creation that has not
    /// finished does, and a partial file is in use while any creation runs.
    /// Neither refuses the deletion: the confirmation says what it breaks.
    static func deletion() {
        let url = "https://updates.cdn-apple.com/x/iPhone17,3_27.0_24A435_Restore.ipsw"
        let cached = VPhoneLaunchpadIPSW.cacheName(for: URL(string: url)!)
        let phone = file(cached, VPhoneLaunchpadIPSW(fileName: cached))
        let partial = file(cached, nil, downloading: true)
        let restored = VPhoneLaunchpadIPSWUse(machine: "done", productType: "iPhone17,3", ios: .init(version: "27.0", build: "24A435"))
        let running = VPhoneLaunchpadIPSWUse(machine: "new", sources: [url], isCreating: true, needsSources: true)
        let failed = VPhoneLaunchpadIPSWUse(machine: "retry", sources: [url], needsSources: true)
        let finished = VPhoneLaunchpadIPSWUse(machine: "made", sources: [url])
        let otherSource = VPhoneLaunchpadIPSWUse(machine: "other", sources: [rcSource], isCreating: true, needsSources: true)
        typealias Rows = VPhoneLaunchpadIPSWRows
        expect(restored.uses(phone) && Rows.deletionWarning(phone, uses: [restored, finished], isCreating: false) == nil, "restored and finished need nothing")
        expect(Rows.deletionWarning(phone, uses: [otherSource], isCreating: true) == nil, "a creation from another IPSW needs nothing")
        let held = Rows.deletionWarning(phone, uses: [running], isCreating: true)
        expect(held == "Creating new reads this IPSW until the creation finishes.", String(describing: held))
        expect(Rows.deletionWarning(phone, uses: [failed], isCreating: false)?.contains("retry") == true, "an unfinished creation is warned about")
        expect(Rows.deletionWarning(phone, uses: [running, failed], isCreating: true)?.contains("new, retry") == true, "both creations named")
        expect(Rows.deletionWarning(partial, uses: [], isCreating: true) == "This IPSW is still downloading.", "a partial file warns while a creation runs")
        expect(Rows.deletionWarning(partial, uses: [], isCreating: false) == nil, "a stale partial file can go")
        let rows = Rows.rows([phone], catalog: nil, uses: [restored, failed])
        expect(rows[0].deletionWarning != nil && rows[0].usedBy == ["done", "retry"], "\(rows[0])")

        // The confirmation names the file, the machines that keep working and
        // what brings it back.
        var row = Rows.rows([phone], catalog: nil, uses: [restored])[0]
        expect(Rows.deletionMessage(row) == "\(cached) is deleted from the IPSW cache. done keep working without it. Creating a machine from this release downloads it again.", Rows.deletionMessage(row))
        row.usedBy = []
        expect(Rows.deletionMessage(row) == "\(cached) is deleted from the IPSW cache. Creating a machine from this release downloads it again.", Rows.deletionMessage(row))
        let partialRow = Rows.rows([partial], catalog: nil, uses: [])[0]
        expect(Rows.deletionMessage(partialRow) == "The partial download of \(cached) is deleted.", Rows.deletionMessage(partialRow))
        let heldRow = Rows.rows([phone], catalog: nil, uses: [running], isCreating: true)[0]
        expect(Rows.deletionMessage(heldRow).hasSuffix(" Creating new reads this IPSW until the creation finishes."), Rows.deletionMessage(heldRow))
    }

    // MARK: - Rows

    static func rows() {
        let release = VPhoneLaunchpadIPSWUse.Release(version: "26.6.2", build: "23G90")
        let cloud = VPhoneLaunchpadIPSWUse.Release(version: "26.4", build: "23E5207q")
        let pad = VPhoneLaunchpadIPSWUse(machine: "ipad-mini-01", productType: "iPad16,1", ios: release, cloudOS: cloud)
        let otherPad = VPhoneLaunchpadIPSWUse(machine: "ipad-pro-13", productType: "iPad17,3", ios: release, cloudOS: cloud)
        let creating = VPhoneLaunchpadIPSWUse(machine: "phone", sources: [rcSource], isCreating: true, needsSources: true)
        let catalog = VPhoneLaunchpadIPSWCatalogNames(images: [
            (name: "iOS 27.0 RC", url: rcSource),
            (name: "cloudOS 26.4", url: "https://updates.cdn-apple.com/x/c0ecdb4b"),
        ])
        expect(catalog.name(forFile: "iPhone17,3_27.0_24A435_Restore.ipsw") == "iOS 27.0 RC", "a copy kept under the URL's own name")

        let rows = VPhoneLaunchpadIPSWRows.rows([unknownFile, cloudFile, padFile, phoneFile], catalog: catalog, uses: [pad, otherPad, creating])
        expect(rows.map(\.kind) == [.iPhone, .iPad, .cloudOS, .unknown], "\(rows.map(\.kind))")
        expect(rows[0].title == "iOS 27.0 RC (24A435)" && rows[0].usedBy == ["phone (creating)"], "\(rows[0])")
        expect(rows[0].kindLabel == "iPhone" && rows[0].deletionWarning != nil, "\(rows[0])")
        expect(rows[1].title == "iPadOS 26.6.2 (23G90)" && rows[1].usedBy == ["ipad-mini-01"] && rows[1].deletionWarning == nil, "\(rows[1])")
        expect(rows[0].devices == "iPhone17,3" && rows[1].devices == "iPad16,1, iPad16,2" && rows[2].devices.isEmpty, "\(rows.map(\.devices))")
        expect(rows[2].kindLabel == "cloudOS" && rows[2].title == "cloudOS 26.4 (23E5207q)", "\(rows[2])")
        expect(rows[2].usedBy == ["ipad-mini-01", "ipad-pro-13"], "\(rows[2].usedBy)")
        expect(rows[3].title == "mystery.ipsw" && rows[3].kindLabel == "Unknown", "\(rows[3])")

        // Newest first within a kind.
        let older = file("iPhone17,3_26.6.2_23G90_Restore.ipsw", VPhoneLaunchpadIPSW(fileName: "iPhone17,3_26.6.2_23G90_Restore.ipsw"))
        let newer = file("iPhone17,3_27.0.1_24A446_Restore.ipsw", VPhoneLaunchpadIPSW(fileName: "iPhone17,3_27.0.1_24A446_Restore.ipsw"))
        let sorted = VPhoneLaunchpadIPSWRows.rows([older, newer], catalog: nil, uses: [])
        expect(sorted.map(\.title) == ["iOS 27.0.1 (24A446)", "iOS 26.6.2 (23G90)"], "\(sorted.map(\.title))")
    }
}
