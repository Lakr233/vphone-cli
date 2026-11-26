import Foundation

// MARK: - Steps

/// One step of New Machine's pipeline, in the order they run.
nonisolated enum VPhoneLaunchpadCreationStep: Int, CaseIterable, Identifiable, Comparable, Sendable {
    /// `vm template find`: is there a template for these options already?
    case findTemplate
    case create
    case prepare
    case patch
    case bootDFU
    case waitDFU
    case restore
    case stopDFU
    case installCFW
    /// `vm template trim` on the stopped template build, or on the machine
    /// itself when it is slimmed without a template.
    case trimTemplate
    /// `vm template setup`: the template's one boot, headless; or the
    /// machine's, slimming it without a template.
    case setUpTemplate
    /// `vm template adopt`: the build becomes the frozen template.
    case adoptTemplate
    /// `vm create --template`: the new machine, cloned in a second.
    case cloneTemplate
    /// `fw set-patches` and `cfw update-environment` on the clone: the guest
    /// patch overrides, which a template does not carry.
    case applyGuestPatches
    case firstBoot
    /// vphoned's `bootstrap.install`: Irisin in the booted machine.
    case installBootstrap
    /// vphoned's `bootstrap.packages`: `owngoal-bootstrap-vphone` through
    /// Irisin's own irisin-cli.
    case installBootstrapPackages

    var id: Int {
        rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .findTemplate: String(localized: "Find template")
        case .create: String(localized: "Create machine")
        case .prepare: String(localized: "Download and prepare firmware")
        case .patch: String(localized: "Patch boot chain")
        case .bootDFU: String(localized: "Boot into DFU")
        case .waitDFU: String(localized: "Wait for DFU")
        case .restore: String(localized: "Restore")
        case .stopDFU: String(localized: "Stop machine")
        case .installCFW: String(localized: "Install custom firmware")
        case .trimTemplate: String(localized: "Trim system files")
        case .setUpTemplate: String(localized: "Set up and slim system")
        case .adoptTemplate: String(localized: "Save template")
        case .cloneTemplate: String(localized: "Create machine from template")
        case .applyGuestPatches: String(localized: "Apply guest patches")
        case .firstBoot: String(localized: "First boot")
        case .installBootstrap: String(localized: "Install bootstrap")
        case .installBootstrapPackages: String(localized: "Install bootstrap packages")
        }
    }

    var needsRoot: Bool {
        self == .installCFW || self == .applyGuestPatches
    }

    /// The step moves a build into `.templates` or clones a template, and
    /// the clone refuses a template another process holds open. The disk
    /// meter leaves templates alone meanwhile (`VPhoneLaunchpadDiskAccess`).
    var needsTemplatesToItself: Bool {
        self == .adoptTemplate || self == .cloneTemplate
    }
}

// MARK: - Bootstrap

/// What New Machine installs in the finished machine: Irisin, and the first
/// packages through its irisin-cli.
///
/// Both toggles keep what they were set to even while a preset or a device
/// forbids them, so changing either back restores the choice. ``resolved(…)``
/// is what the pipeline runs.
nonisolated struct VPhoneLaunchpadBootstrapChoice: Hashable, Sendable {
    var wantsBootstrap = false
    var wantsPackages = false

    /// The Irisin layout vphoned installs. A visionOS guest runs the iOS agent
    /// through the iPad compatibility environment and serves only rootless,
    /// which it advertises as `bootstrap_rootless_only` and `bootstrap.install`
    /// enforces; every other guest takes roothide, as `vm create --bootstrap
    /// roothide` does.
    static func layout(device: String?) -> String {
        device?.hasPrefix("RealityDevice") == true ? "rootless" : "roothide"
    }

    /// Irisin's Apple TV package carries no irisin-cli, so a tvOS guest takes
    /// the bootstrap but none of its packages (`GuestBootstrapPlatform`).
    static func allowsPackages(device: String?) -> Bool {
        !VPhoneLaunchpadMachine.usesTVOS(device)
    }

    /// What the creation actually installs. `presetAllows` is false for a
    /// preset that customises the system before the restore (`minimal`,
    /// `watchos`): it patches no kernel and reseals the system, so Irisin has
    /// nothing to install into. Packages need the bootstrap.
    func resolved(presetAllows: Bool, device: String?) -> (bootstrap: Bool, packages: Bool) {
        let bootstrap = wantsBootstrap && presetAllows
        return (bootstrap, bootstrap && wantsPackages && Self.allowsPackages(device: device))
    }
}

// MARK: - Plan

/// Which steps a creation runs, and on which machine.
///
/// Without a template every step works on the new machine itself, as
/// `vm create --no-template` does. With one, Find Template asks the bundle
/// whether a template for these options exists. If it does, the machine is
/// cloned from it and booted. If not, the template is built first under a
/// temporary machine name in the same library: restored, custom firmware
/// installed through the helper, trimmed, set up headless and adopted, which
/// moves it into `.templates`. Then the clone and its first boot follow.
///
/// A template is built with the boot-chain patch overrides only, the ones its
/// key holds. Guest patch overrides go to the clone before its first boot, so
/// a template never hands them to a creation that did not ask for them.
nonisolated struct VPhoneLaunchpadCreationPlan: Hashable, Sendable {
    /// The machine New Machine was asked for.
    var name: String
    /// The temporary machine a template is built in; nil without a template.
    var buildName: String?
    var slimming: VPhoneLaunchpadSlimming
    /// Whether the clone gets guest patch overrides of its own. Only a
    /// template-backed creation has the step: without a template, `cfw
    /// install` applies them to the machine itself.
    var appliesGuestPatches = false
    /// Nil until Find Template answers; then whether it found a template
    /// this creation clones from as it is.
    var foundTemplate: Bool?
    /// Whether the booted machine gets the Irisin bootstrap, and its first
    /// packages, as the last steps.
    var installsBootstrap = false
    var installsBootstrapPackages = false

    var usesTemplate: Bool {
        buildName != nil
    }

    /// The temporary machine once Find Template has decided to build in it;
    /// nil before that, when a template was found, and without a template.
    var buildingName: String? {
        foundTemplate == false ? buildName : nil
    }

    /// Every step this creation runs, in order. Until Find Template has
    /// answered, a template-backed creation lists the build too.
    var steps: [VPhoneLaunchpadCreationStep] {
        let restore: [VPhoneLaunchpadCreationStep] = [.create, .prepare, .patch, .bootDFU, .waitDFU, .restore, .stopDFU, .installCFW]
        // The machine is running after its first boot, which is what vphoned
        // needs to install them.
        let bootstrap: [VPhoneLaunchpadCreationStep] = (installsBootstrap ? [.installBootstrap] : [])
            + (installsBootstrapPackages ? [.installBootstrapPackages] : [])
        guard usesTemplate else {
            // Slimmed on its own: the same trim and setup boot a template
            // build runs, on the machine itself, which is then not adopted.
            guard slimming.slim else {
                return restore + [.firstBoot] + bootstrap
            }
            return restore + (slimming.trimArguments != nil ? [.trimTemplate] : []) + [.setUpTemplate, .firstBoot] + bootstrap
        }
        let machine: [VPhoneLaunchpadCreationStep] = [.cloneTemplate] + (appliesGuestPatches ? [.applyGuestPatches] : []) + [.firstBoot] + bootstrap
        if foundTemplate == true {
            return [.findTemplate] + machine
        }
        var steps: [VPhoneLaunchpadCreationStep] = [.findTemplate] + restore
        if slimming.trimArguments != nil {
            steps.append(.trimTemplate)
        }
        return steps + [.setUpTemplate, .adoptTemplate] + machine
    }

    /// The step after `step`, or nil after the last.
    func step(after step: VPhoneLaunchpadCreationStep) -> VPhoneLaunchpadCreationStep? {
        steps.first { $0 > step }
    }

    /// Whether `step` builds the template rather than the machine asked for.
    func buildsTemplate(_ step: VPhoneLaunchpadCreationStep) -> Bool {
        guard usesTemplate else {
            return false
        }
        switch step {
        case .findTemplate, .cloneTemplate, .applyGuestPatches, .firstBoot,
             .installBootstrap, .installBootstrapPackages: return false
        default: return true
        }
    }

    /// The machine `step` works on.
    func machineName(for step: VPhoneLaunchpadCreationStep) -> String {
        buildsTemplate(step) ? buildName ?? name : name
    }

    /// A short machine name no library is likely to hold: `template-`
    /// and eight hex digits. It stays in the library only while the
    /// template is built.
    static func newBuildName() -> String {
        "template-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}
