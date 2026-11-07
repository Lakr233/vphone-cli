@testable import FirmwarePatcher
import Foundation
import Testing
import VPhoneCoreKit
import VPhonePatchKit

/// A guest system volume with an iPhone-style TextRecognition (hardware
/// binaries only) and a host Resources folder with the same models as MIL.
private struct Fixture {
    typealias Models = CustomFirmwareTextRecognitionModels
    static let detector = "cr_td_model_v3_e5.mlmodelc.bundle"
    static let recognizer = "cr_tr_model_latincyrillic_v3_e5.mlmodelc.bundle"

    let root: URL
    var system: URL { root.appendingPathComponent("system") }
    var host: URL { root.appendingPathComponent("host") }
    var framework: URL { system.appendingPathComponent(Models.guestFramework) }
    var owner: (uid: uid_t, gid: gid_t) { (getuid(), getgid()) }

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try guestModel(Self.detector, names: ["img_input", "region_score"])
        try guestModel(Self.recognizer, names: ["img_input", "output_label_prob_map"])
        try write(Data("code map".utf8), framework.appendingPathComponent("\(Self.recognizer)/codemap.bin"))
        try hostModel(Self.detector, inputs: ["img_input"], outputs: ["region_score"], weights: "detector")
        try hostModel(Self.recognizer, inputs: ["img_input"], outputs: ["output_label_prob_map"], weights: "recognizer")
        try write(Data("code map".utf8), host.appendingPathComponent("\(Self.recognizer)/codemap.bin"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func guestModel(_ name: String, names: [String]) throws {
        let descriptor = names.reduce(Data("E5".utf8)) { $0 + Models.flatBufferString($1) }
        try write(descriptor, framework.appendingPathComponent("\(name)/H18.bundle/H18.e5"))
        try write(Data("hwx".utf8), framework.appendingPathComponent("\(name)/H18.bundle/main/main_ane/model.hwx"))
    }

    func hostModel(_ name: String, inputs: [String], outputs: [String], weights: String) throws {
        let bundle = host.appendingPathComponent(name)
        let mil = """
        program(1.2)
        { func main<ios18>(x) { tensor<fp16, [1]> w = const()[val = tensor<fp16, [1]>(BLOBFILE(path = tensor<string, []>("@model_path/weights/weight.bin"), offset = tensor<uint64, []>(64)))]; } -> (y); }
        """
        try write(Data(mil.utf8), bundle.appendingPathComponent("model.mil"))
        try write(Data(weights.utf8), bundle.appendingPathComponent("weights/weight.bin"))
        let metadata: [[String: Any]] = [[
            "inputSchema": inputs.map { ["name": $0] },
            "outputSchema": outputs.map { ["name": $0] },
        ]]
        try write(JSONSerialization.data(withJSONObject: metadata), bundle.appendingPathComponent("metadata.json"))
        try write(Data("{}".utf8), bundle.appendingPathComponent("coremldata.bin"))
    }

    func directories() throws -> (system: VPhoneConfinedDirectory, host: VPhoneConfinedDirectory) {
        (try VPhoneConfinedDirectory(root: system.path), try VPhoneConfinedDirectory(root: host.path))
    }

    func plan() throws -> Models.Plan {
        let (system, host) = try directories()
        return try Models.plan(system: system, host: host, journal: Models.readJournal(system: system))
    }

    func install() throws -> Models.Plan {
        let (system, host) = try directories()
        let journal = try Models.readJournal(system: system)
        let plan = try Models.plan(system: system, host: host, journal: journal)
        try Models.install(plan, system: system, journal: journal, owner: owner)
        return plan
    }

    func guestFiles() throws -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: system.path)
        return (enumerator?.allObjects as? [String] ?? []).sorted()
    }
}

@Suite("TextRecognition E5 model sources")
struct CustomFirmwareTextRecognitionModelsTests {
    typealias Models = CustomFirmwareTextRecognitionModels

    @Test func `adds only the program and the weights it reads, and removes exactly them`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.guestFiles()

        let plan = try fixture.install()
        #expect(plan.models == [Fixture.detector, Fixture.recognizer])
        let detector = "\(Models.guestFramework)/\(Fixture.detector)"
        #expect(plan.directories == ["\(detector)/weights", "\(Models.guestFramework)/\(Fixture.recognizer)/weights"].sorted())
        #expect(try Data(contentsOf: fixture.system.appendingPathComponent("\(detector)/weights/weight.bin")) == Data("detector".utf8))
        #expect(FileManager.default.fileExists(atPath: fixture.system.appendingPathComponent("\(detector)/model.mil").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.system.appendingPathComponent("\(detector)/metadata.json").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.system.appendingPathComponent("\(detector)/coremldata.bin").path))
        let journal = try #require(try Models.readJournal(system: fixture.directories().system))
        #expect(journal.files == plan.files.keys.sorted())

        // A second run over its own output plans the same and leaves the
        // files themselves in place, so no app's compiled models go stale.
        let installed = try fixture.guestFiles()
        let program = fixture.system.appendingPathComponent("\(detector)/model.mil").path
        let identity = try FileManager.default.attributesOfItem(atPath: program)[.systemFileNumber] as? Int
        let again = try fixture.install()
        #expect(again.files == plan.files)
        #expect(try fixture.guestFiles() == installed)
        #expect(try FileManager.default.attributesOfItem(atPath: program)[.systemFileNumber] as? Int == identity)

        #expect(try Models.uninstall(system: fixture.directories().system))
        // The fixture has no usr/share of its own; the journal's folder goes with the journal.
        #expect(try fixture.guestFiles().filter { !["usr", "usr/share"].contains($0) } == before)
        #expect(!(try Models.uninstall(system: fixture.directories().system)))

        // A journal folder something else uses stays.
        _ = try fixture.install()
        try fixture.write(Data(), fixture.system.appendingPathComponent("usr/share/vphone/Other.plist"))
        #expect(try Models.uninstall(system: fixture.directories().system))
        #expect(FileManager.default.fileExists(atPath: fixture.system.appendingPathComponent("usr/share/vphone/Other.plist").path))
    }

    @Test func `refuses a host model another release ships, before writing anything`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Data("another code map".utf8), fixture.host.appendingPathComponent("\(Fixture.recognizer)/codemap.bin"))
        let before = try fixture.guestFiles()
        #expect(throws: (any Error).self) { try fixture.install() }
        #expect(try fixture.guestFiles() == before)
    }

    @Test func `refuses a host model whose interface the hardware binary does not name`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.hostModel(Fixture.detector, inputs: ["img_input"], outputs: ["table_score"], weights: "detector")
        #expect(throws: (any Error).self) { try fixture.plan() }
    }

    @Test func `refuses a guest without the host's model`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.host.appendingPathComponent(Fixture.detector))
        #expect(throws: (any Error).self) { try fixture.plan() }
    }

    @Test func `leaves a model whose source the firmware ships, and files it did not add`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let program = fixture.framework.appendingPathComponent("\(Fixture.detector)/model.mil")
        try fixture.write(Data("apple".utf8), program)
        let plan = try fixture.install()
        #expect(plan.models == [Fixture.recognizer])
        #expect(try Data(contentsOf: program) == Data("apple".utf8))
        #expect(try Models.uninstall(system: fixture.directories().system))
        #expect(try Data(contentsOf: program) == Data("apple".utf8))

        // A weight file vphone did not add is never replaced.
        try fixture.write(Data("apple".utf8), fixture.framework.appendingPathComponent("\(Fixture.recognizer)/weights/weight.bin"))
        #expect(throws: (any Error).self) { try fixture.plan() }
    }

    @Test func `replaces an earlier run's sources and drops the ones no longer read`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.install()
        let recognizer = "\(Models.guestFramework)/\(Fixture.recognizer)"
        let stale = "\(recognizer)/weights/old.bin"
        let (system, _) = try fixture.directories()
        var journal = try #require(try Models.readJournal(system: system))
        journal.files.append(stale)
        try Models.writeJournal(journal, system: system, owner: fixture.owner)
        try fixture.write(Data("old".utf8), fixture.system.appendingPathComponent(stale))
        try fixture.write(Data("updated".utf8), fixture.host.appendingPathComponent("\(Fixture.recognizer)/weights/weight.bin"))

        _ = try fixture.install()
        #expect(!FileManager.default.fileExists(atPath: fixture.system.appendingPathComponent(stale).path))
        #expect(try Data(contentsOf: fixture.system.appendingPathComponent("\(recognizer)/weights/weight.bin")) == Data("updated".utf8))
        #expect(!(try #require(try Models.readJournal(system: system))).files.contains(stale))
    }

    @Test func `reads the weight paths a program names`() throws {
        let mil = Data(#"a("@model_path/weights/weight.bin") b("@model_path/weights/weight.bin") c("@model_path/extra.bin")"#.utf8)
        #expect(try Models.weightPaths(in: mil, model: "m") == ["extra.bin", "weights/weight.bin"])
        #expect(throws: (any Error).self) { try Models.weightPaths(in: Data(#"("@model_path/../x")"#.utf8), model: "m") }
        #expect(throws: (any Error).self) { try Models.weightPaths(in: Data(#"("@model_path/")"#.utf8), model: "m") }
    }

    @Test func `trusts no journal path outside the E5 bundles`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (system, _) = try fixture.directories()
        for path in ["usr/lib/dyld", "\(Models.guestFramework)/TextRecognition", "\(Models.guestFramework)/\(Fixture.detector)/../x"] {
            try Models.writeJournal(Models.Journal(files: [path], directories: []), system: system, owner: fixture.owner)
            #expect(throws: (any Error).self) { try Models.readJournal(system: system) }
        }
    }
}
