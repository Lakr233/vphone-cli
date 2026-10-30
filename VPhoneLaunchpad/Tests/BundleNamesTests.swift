import Foundation

@main
struct BundleNamesTests {
    struct Expectation {
        let name: String
        let bundleVersion: String
        let isLocalBuild: Bool
        let isCompatible: Bool
        let isValid: Bool
    }

    static func main() throws {
        // MARK: - Store names

        // A store name is the bundle's version plus an optional build suffix:
        // `-local` (legacy), `-local.<8+ lowercase hex>` or `-ci.<7+ hex>`.
        // Anything else is kept whole, so it never parses as a version.
        let expectations: [Expectation] = [
            Expectation(name: "2.15.0", bundleVersion: "2.15.0", isLocalBuild: false, isCompatible: true, isValid: true),
            Expectation(name: "2.15.0-local", bundleVersion: "2.15.0", isLocalBuild: true, isCompatible: true, isValid: true),
            Expectation(name: "2.15.0-local.ab12cd34", bundleVersion: "2.15.0", isLocalBuild: true, isCompatible: true, isValid: true),
            // The build identifier is lowercase hex; uppercase is no build.
            Expectation(name: "2.15.0-local.AB12CD34", bundleVersion: "2.15.0-local.AB12CD34", isLocalBuild: false, isCompatible: false, isValid: true),
            Expectation(name: "2.15.0-local.ab12", bundleVersion: "2.15.0-local.ab12", isLocalBuild: false, isCompatible: false, isValid: true),
            Expectation(name: "2.15.0-ci.abcdef1", bundleVersion: "2.15.0", isLocalBuild: false, isCompatible: true, isValid: true),
            Expectation(name: "2.15.1", bundleVersion: "2.15.1", isLocalBuild: false, isCompatible: true, isValid: true),
            Expectation(name: "2.14.99", bundleVersion: "2.14.99", isLocalBuild: false, isCompatible: false, isValid: true),
            Expectation(name: "2.10.1", bundleVersion: "2.10.1", isLocalBuild: false, isCompatible: false, isValid: true),
            Expectation(name: "2.10.1-local.ab12cd34", bundleVersion: "2.10.1", isLocalBuild: true, isCompatible: false, isValid: true),
            Expectation(name: "2.9.5", bundleVersion: "2.9.5", isLocalBuild: false, isCompatible: false, isValid: true),
            Expectation(name: "2.8.9-local.ab12cd34", bundleVersion: "2.8.9", isLocalBuild: true, isCompatible: false, isValid: true),
            Expectation(name: "../x", bundleVersion: "../x", isLocalBuild: false, isCompatible: false, isValid: false),
            Expectation(name: "", bundleVersion: "", isLocalBuild: false, isCompatible: false, isValid: false),
        ]
        for expected in expectations {
            let name = expected.name
            precondition(VPhoneLaunchpadNames.bundleVersion(of: name) == expected.bundleVersion,
                         "bundleVersion(of: \"\(name)\") is \(VPhoneLaunchpadNames.bundleVersion(of: name))")
            precondition(VPhoneLaunchpadNames.isLocalBuild(name) == expected.isLocalBuild, "isLocalBuild(\"\(name)\")")
            precondition(VPhoneLaunchpadNames.isCompatibleBundleVersion(name) == expected.isCompatible, "isCompatibleBundleVersion(\"\(name)\")")
            precondition(VPhoneLaunchpadNames.isValidVersion(name) == expected.isValid, "isValidVersion(\"\(name)\")")
        }
        print("Bundle name tests passed: \(expectations.count) store names")

        // MARK: - Machine binding

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("bundle-names-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: root.path, name: "research-01")
        try fileManager.createDirectory(at: machine.url, withIntermediateDirectories: true)
        let file = VPhoneLaunchpadMachineBinding.url(for: machine)

        precondition(VPhoneLaunchpadMachineBinding.load(machine) == nil, "A machine without launchpad.json has no binding")

        let binding = VPhoneLaunchpadMachineBinding(bundle: "2.3.2-local.ab12cd34", bootChain: "2.3.1", guestEnvironment: "2.3.1")
        try binding.save(to: machine)
        precondition(VPhoneLaunchpadMachineBinding.load(machine) == binding, "A saved binding loads back unchanged")
        precondition(binding.hasMixedVersions, "A guest environment from another bundle is mixed")

        precondition(!VPhoneLaunchpadMachineBinding(bundle: "2.3.2").hasMixedVersions, "An unknown guest environment is not mixed")
        precondition(!VPhoneLaunchpadMachineBinding(bundle: "2.3.2", guestEnvironment: "2.3.2").hasMixedVersions,
                     "A guest environment from the same bundle is not mixed")

        // Every version in the file becomes a store path, so each is checked.
        for json in [
            #"{"bundle":"../evil"}"#,
            #"{"bundle":"2.3.2","bootChain":"../evil"}"#,
            #"{"bundle":"2.3.2","guestEnvironment":"a/b"}"#,
            #"{"bundle":""}"#,
            #"{"bootChain":"2.3.2"}"#,
            "not json",
        ] {
            try Data(json.utf8).write(to: file)
            precondition(VPhoneLaunchpadMachineBinding.load(machine) == nil, "Rejected binding: \(json)")
        }

        // A symbolic link is not read, even when it points at a valid binding.
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try JSONEncoder().encode(binding).write(to: elsewhere)
        try fileManager.removeItem(at: file)
        try fileManager.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        precondition(VPhoneLaunchpadMachineBinding.load(machine) == nil, "A symbolic link launchpad.json is rejected")

        // Saving replaces the link rather than writing through it.
        let replacement = VPhoneLaunchpadMachineBinding(bundle: "2.3.3")
        try replacement.save(to: machine)
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey])
        precondition(values.isSymbolicLink != true, "Saving replaces a symbolic link")
        precondition(VPhoneLaunchpadMachineBinding.load(machine) == replacement, "The replacement loads back")
        let target = try JSONDecoder().decode(VPhoneLaunchpadMachineBinding.self, from: Data(contentsOf: elsewhere))
        precondition(target == binding, "The link's target is left unchanged")
        print("Machine binding tests passed: round trip, mixed versions, invalid versions, symbolic link")
    }
}
