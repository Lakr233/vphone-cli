import Foundation

// MARK: - Service Profiles

/// A service profile is a set of launchd jobs vphoned turns off with
/// `launchctl disable`: an override in launchd's database on the data volume
/// (`/private/var/db/com.apple.xpc.launchd/disabled.plist`), so launchd does not
/// load the job at the next boot. Nothing changes until the guest restarts;
/// `launchctl stop` and `unload` return launchd status 144 on the guest.
///
/// `trimmed` is the set measured on an iOS 27.0 iPhone guest (memory −29%,
/// idle host CPU −26%, idle host writes −60%) and mapped onto iOS 26.6.2
/// (memory −30%, idle host CPU −39%, idle host writes −94%), with no vphone
/// feature lost on either.
/// `none` turns back on only what the profile turned off, which it records in
/// `recordPath`; a job somebody else disabled (the OTA block, a user in the
/// Services panel) is never touched. See `Research/Guest/service_trimming.md`.
///
/// Nothing here touches the guest, so `VPhoneDaemon/Tests/run-logic-tests.sh`
/// builds this file on the Mac.
enum GuestServiceProfile {
    /// Raised whenever a label list changes, and kept in the record, so a
    /// guest shows which list its overrides came from.
    static let listVersion = 3
    static let recordPath = "/var/db/vphoned/service-profile.plist"
    static let trimmed = "trimmed"
    static let none = "none"

    struct Group: Sendable {
        let name: String
        /// Part of `trimmed` unless the caller asks otherwise; the rest only
        /// when named in `groups`.
        let byDefault: Bool
        let summary: String
        let labels: [String]
    }

    /// The groups for an iOS major version, nil where no list was measured.
    /// Both lists were measured on iPhone guests.
    static func groups(iosMajor: Int) -> [Group]? {
        switch iosMajor {
        case 26: groups26
        case 27: groups27
        default: nil
        }
    }

    static let supportedMajors = [26, 27]

    /// `base` plus the groups every version shares: the store, sign-in
    /// follow-up and account daemons have the same labels on 26 and 27.
    static func catalog(base: [String]) -> [Group] {
        [
            Group(
                name: "base", byDefault: true,
                summary: "Siri and intelligence, Find My, Wallet/NFC/SE, Watch, Home, health coaching, Maps background, "
                    + "iCloud/iMessage sync, ads and recommendations, telemetry, accessory firmware, OTA",
                labels: base,
            ),
            Group(
                name: "app_store", byDefault: true,
                summary: "App Store and iTunes Store daemons, off with the store apps; appstorecomponentsd is in base",
                labels: ["com.apple.appstored", "com.apple.itunesstored"],
            ),
            Group(
                name: "signin_followup", byDefault: true,
                summary: "Sign-in follow-up and Apple Account setup prompts; apply after first-boot work has settled",
                labels: ["com.apple.appleidsetupd", "com.apple.followupd"],
            ),
            Group(
                name: "accounts", byDefault: false,
                summary: "Apple Account daemons; with these off the guest cannot sign in to an Apple Account",
                labels: ["com.apple.akd", "com.apple.amsaccountsd", "com.apple.appleaccountd"],
            ),
        ]
    }

    // MARK: - iOS 27

    static let groups27 = catalog(base: base27)

    /// Appendix A of the 2026-10-07 measurement on `svctest-a` (iPhone, 27.0
    /// 24A435): the LaunchDaemons that were loaded at boot and stayed unloaded
    /// after the override, with the four traps below already taken out: 137,
    /// less siriactionsd since list version 2 and passd and financed since
    /// list version 3 (see `neverDisable`).
    static let base27: [String] = [
        "com.apple.CallHistorySyncHelper",
        "com.apple.Maps.mapspushd",
        "com.apple.Maps.mapssyncd",
        "com.apple.OTACrashCopier",
        "com.apple.OTATaskingAgent",
        "com.apple.PerfPowerServicesExtended",
        "com.apple.PowerUIAgent",
        "com.apple.SafariBookmarksSyncAgent",
        "com.apple.SensorKitALSHelper",
        "com.apple.SiriTTSTrainingAgent",
        "com.apple.StatusKitAgent",
        "com.apple.ThreadCommissionerService",
        "com.apple.WirelessRadioManager",
        "com.apple.absd",
        "com.apple.accessibility.heard",
        "com.apple.accessoryupdaterd",
        "com.apple.adid",
        "com.apple.amsengagementd",
        "com.apple.analyticsagent",
        "com.apple.analyticsd",
        "com.apple.ap.adprivacyd",
        "com.apple.ap.promotedcontentd",
        "com.apple.appstorecomponentsd",
        "com.apple.askpermissiond",
        "com.apple.assistant_cdmd",
        "com.apple.assistant_service",
        "com.apple.assistantd",
        "com.apple.audioanalyticsd",
        "com.apple.batteryintelligenced",
        "com.apple.biomesyncd",
        "com.apple.bookassetd",
        "com.apple.callintelligenced",
        "com.apple.carkitd",
        "com.apple.cdpd",
        "com.apple.cloudtelemetryd",
        "com.apple.cmfsyncagent",
        "com.apple.coreidvd",
        "com.apple.corespeechd",
        "com.apple.diagnosticextensionsd",
        "com.apple.diagnosticspushd",
        "com.apple.duetexpertd",
        "com.apple.ecosystemanalyticsd",
        "com.apple.email.maild",
        "com.apple.eyereliefd",
        "com.apple.familycircled",
        "com.apple.findmy.findmybeaconingd",
        "com.apple.findmy.findmylocated",
        "com.apple.finhealthd",
        "com.apple.fitnesscoachingd",
        "com.apple.fitnessintelligenced",
        "com.apple.gamed",
        "com.apple.generativeexperiencesd",
        "com.apple.geoanalyticsd",
        "com.apple.hangtelemetryd",
        "com.apple.homed",
        "com.apple.homeeventsd",
        "com.apple.hybridsearchd",
        "com.apple.icloud.findmydeviced",
        "com.apple.icloud.fmflocatord",
        "com.apple.icloud.searchpartyd",
        "com.apple.icloudmailagent",
        "com.apple.identityservicesd",
        "com.apple.imagent",
        "com.apple.imcore.imtransferagent",
        "com.apple.ind",
        "com.apple.inputanalyticsd",
        "com.apple.intelligencecontextd",
        "com.apple.intelligenceflowd",
        "com.apple.intelligenceplatformd",
        "com.apple.intelligencetasksd",
        "com.apple.itunescloudd",
        "com.apple.jetpackassetd",
        "com.apple.knowledgeconstructiond",
        "com.apple.libsqlite3.dbtelemetryd",
        "com.apple.maps.destinationd",
        "com.apple.mediaanalysisd",
        "com.apple.mediaanalysisd.service",
        "com.apple.milod",
        "com.apple.mobile.softwareupdated",
        "com.apple.modelmanagerd",
        "com.apple.nanobackupd",
        "com.apple.nanoprefsyncd.2",
        "com.apple.nanotimekitcompaniond",
        "com.apple.navd",
        "com.apple.ndoagent",
        "com.apple.nearbyd",
        "com.apple.nfcd",
        "com.apple.ospredictiond",
        "com.apple.parsec-fbf",
        "com.apple.peopled",
        "com.apple.perfpowermetricd",
        "com.apple.photoanalysisd",
        "com.apple.photosface",
        "com.apple.powerexperienced",
        "com.apple.remindd",
        "com.apple.replicatord",
        "com.apple.routined",
        "com.apple.rtcreportingd",
        "com.apple.safetyalertsd",
        "com.apple.seld",
        "com.apple.sensorkitd",
        "com.apple.servicesintelligenced",
        "com.apple.seserviced",
        "com.apple.siri.sirireaderd",
        "com.apple.siriinferenced",
        "com.apple.siriknowledged",
        "com.apple.sociallayerd",
        "com.apple.softposreaderd",
        "com.apple.softwareupdateservicesd",
        "com.apple.speechmaintenanced",
        "com.apple.spotlightknowledged",
        "com.apple.spotlightknowledged.updater",
        "com.apple.symptomsd-diag",
        "com.apple.syncdefaultsd",
        "com.apple.systemvoiceassistant",
        "com.apple.terminusd",
        "com.apple.textunderstandingd",
        "com.apple.tipsd",
        "com.apple.triald",
        "com.apple.uarpassetmanagerd",
        "com.apple.uarpd",
        "com.apple.uarphidd",
        "com.apple.uarppersonalizationd",
        "com.apple.usbctelemetryd",
        "com.apple.videosubscriptionsd",
        "com.apple.visioncompaniond",
        "com.apple.visualintelligenced",
        "com.apple.voicebankingd",
        "com.apple.voicemail.vmd",
        "com.apple.watchlistd",
        "com.apple.watchpresenced",
        "com.apple.weatherd",
        "com.apple.wifianalyticsd",
        "com.apple.wirelessinsightsd",
    ]

    // MARK: - iOS 26

    static let groups26 = catalog(base: base26)

    /// The iOS 27 list mapped onto iPhone 26.6.2 (23G90), measured on `t26-a`
    /// (2026-10-09): every label of `base27` that 26 loads at boot, under the
    /// same name. Of the four jobs only 26 has, the one that runs,
    /// `com.apple.timesync.audioclocksyncd`, stays on: off, it saved no host
    /// CPU. The never-disabled set needed nothing new for 26.
    static let base26: [String] = base27.filter { !notLoadedOn26.contains($0) }

    /// `base27` labels 26.6.2 does not load: five its launchd.plist does not
    /// have, and safetyalertsd, which it limits to hardware a guest is not.
    static let notLoadedOn26: Set<String> = [
        "com.apple.cloudtelemetryd", "com.apple.hybridsearchd", "com.apple.libsqlite3.dbtelemetryd",
        "com.apple.speechmaintenanced", "com.apple.visualintelligenced",
        "com.apple.safetyalertsd",
    ]

    // MARK: - Never Disabled

    /// Jobs the profile refuses to disable, whatever list or group names them.
    ///
    /// The first four kinds were measured to make things worse when off: without
    /// sleepd, SpringBoard and mobiletimerd reconnect to it with no back-off
    /// (about 400% host CPU); without CommCenter, SpringBoard reconnects every
    /// second and resets the idle timer, so the screen never sleeps; without
    /// cloudd, transparencyd and ScreenTimeSettingsAgent retry CloudKit and
    /// write more than the untrimmed guest; without NanoRegistry, locationd
    /// waits on it synchronously. The rest are what vphone's own features and
    /// the tools it drives (Xcode, DeviceHub, ideviceinstaller, Frida, crash
    /// logs, camera and audio) rely on.
    static let neverDisable: Set<String> = [
        // Worse when disabled.
        "com.apple.sleepd",
        "com.apple.CommCenter", "com.apple.CommCenterMobileHelper", "com.apple.CommCenterRootHelper",
        "com.apple.cloudd",
        "com.apple.nanoregistryd", "com.apple.nanoregistrylaunchd",
        // Named by the OTA block and the App Store notes.
        "com.apple.mobileassetd", "com.apple.storekitd",
        // vphone features.
        "com.vphone.vphoned",
        "com.apple.SpringBoard", "com.apple.backboardd", "com.apple.runningboardd",
        "com.apple.lsd", "com.apple.lsd.system",
        "com.apple.containermanagerd", "com.apple.containermanagerd.system",
        "com.apple.mobile.installd", "com.apple.misagent", "com.apple.mobile.lockdown",
        "com.apple.remoted", "com.apple.security.cryptexd", "com.apple.dt.remotepairingdeviced",
        "com.apple.avconferenced", "com.apple.diskimagesiod", "com.apple.diskimagesiod.ram",
        "com.apple.locationd", "com.apple.bluetoothd",
        "com.apple.pasteboard.pasted", "com.apple.powerd", "com.apple.MobileFileIntegrity",
        "com.apple.managedconfiguration.profiled", "com.apple.mobile.keybagd",
        "com.apple.cfprefsd.xpc.daemon", "com.apple.cfprefsd.xpc.daemon.system",
        "com.apple.notifyd", "com.apple.mDNSResponder.reloaded", "com.apple.mDNSResponderHelper.reloaded",
        "com.apple.configd", "com.apple.timed", "com.apple.tzlinkd", "com.apple.securityd",
        "com.apple.logd", "com.apple.logd_helper", "com.apple.diagnosticd",
        "com.apple.ReportCrash", "com.apple.osanalytics.osanalyticshelper",
        "com.apple.audiomxd", "com.apple.mediaplaybackd", "com.apple.mediaremoted", "com.apple.cameracaptured",
        "com.apple.mobileactivationd",
        // App Intents: every Control Center control and App Intents widget
        // serializes its intent through siriactionsd's VoiceShortcuts service;
        // without it WidgetKit traps in each extension and the controls draw
        // blank.
        "com.apple.siriactionsd",
        // Wallet: its first screen asks passd synchronously for the pass groups,
        // and passd waits on financed's Core Data store; with either disabled
        // FrontBoard kills Wallet at the scene-create watchdog.
        "com.apple.passd", "com.apple.financed",
    ]

    // MARK: - Selection

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownProfile(String)
        case unsupported(iosMajor: Int)
        case unknownGroup(String)

        var description: String {
            switch self {
            case let .unknownProfile(name):
                "profile must be \(GuestServiceProfile.trimmed) or \(GuestServiceProfile.none), not \(name)"
            case let .unsupported(major):
                "No trimmed service list for iOS \(major); lists exist for iOS "
                    + GuestServiceProfile.supportedMajors.map(String.init).joined(separator: ", ")
            case let .unknownGroup(name):
                "Unknown service group \(name)"
            }
        }
    }

    /// The labels a profile wants disabled.
    struct Selection: Equatable, Sendable {
        var groups: [String] = []
        /// Sorted and unique, without `allow` and `neverDisable`.
        var labels: [String] = []
        /// Catalog labels the caller kept with `allow`.
        var allowed: [String] = []
        /// Catalog labels refused because they are on `neverDisable`.
        var refused: [String] = []
    }

    /// The default groups plus `extraGroups`, minus `allow` and `neverDisable`.
    /// `none` selects nothing on every version.
    static func select(profile: String, iosMajor: Int, extraGroups: [String] = [], allow: [String] = []) throws -> Selection {
        switch profile {
        case none:
            return Selection()
        case trimmed:
            break
        default:
            throw Failure.unknownProfile(profile)
        }
        guard let catalog = groups(iosMajor: iosMajor) else {
            throw Failure.unsupported(iosMajor: iosMajor)
        }
        for name in extraGroups where !catalog.contains(where: { $0.name == name }) {
            throw Failure.unknownGroup(name)
        }
        let chosen = catalog.filter { $0.byDefault || extraGroups.contains($0.name) }
        let wanted = Set(chosen.flatMap(\.labels))
        let kept = Set(allow)
        return Selection(
            groups: chosen.map(\.name),
            labels: wanted.subtracting(kept).subtracting(neverDisable).sorted(),
            allowed: wanted.intersection(kept).sorted(),
            refused: wanted.intersection(neverDisable).subtracting(kept).sorted(),
        )
    }

    // MARK: - Reconciliation

    struct Skip: Equatable, Sendable {
        let label: String
        let reason: String
    }

    /// What applying a selection does, given the labels the profile disabled
    /// before (`owned`) and launchd's overrides now (`overrides`, true =
    /// disabled).
    struct Change: Equatable, Sendable {
        /// Enabled now; the profile disables them and owns them from then on.
        var disable: [String] = []
        /// Owned, no longer selected, still disabled: the profile turns them on.
        var enable: [String] = []
        /// Owned, still selected and still disabled: nothing to do.
        var keep: [String] = []
        /// Left alone: disabled by someone else, refused, or owned but already
        /// back on.
        var skipped: [Skip] = []
    }

    static let disabledElsewhere = "already disabled, not by the profile"
    static let neverDisabledReason = "never disabled"
    static let enabledElsewhere = "already enabled again"

    static func reconcile(target: [String], owned: [String], overrides: [String: Bool]) -> Change {
        var change = Change()
        let ownedSet = Set(owned)
        let targetSet = Set(target)
        for label in targetSet.sorted() {
            if neverDisable.contains(label) {
                change.skipped.append(Skip(label: label, reason: neverDisabledReason))
            } else if overrides[label] == true {
                if ownedSet.contains(label) {
                    change.keep.append(label)
                } else {
                    change.skipped.append(Skip(label: label, reason: disabledElsewhere))
                }
            } else {
                change.disable.append(label)
            }
        }
        for label in ownedSet.subtracting(targetSet).sorted() {
            if overrides[label] == true {
                change.enable.append(label)
            } else {
                change.skipped.append(Skip(label: label, reason: enabledElsewhere))
            }
        }
        return change
    }

    /// The labels the profile owns once `change` ran: what it kept, what it
    /// disabled, and what it failed to turn back on, so a later `none` tries
    /// again.
    static func owned(after change: Change, failedDisable: Set<String>, failedEnable: Set<String>) -> [String] {
        (change.keep + change.disable.filter { !failedDisable.contains($0) }
            + change.enable.filter { failedEnable.contains($0) }).sorted()
    }

    // MARK: - Record

    /// What the profile last did, in `recordPath`.
    struct Record: Equatable, Sendable {
        var profile: String
        var listVersion: Int
        var iosMajor: Int
        var groups: [String]
        var allow: [String]
        /// The labels this profile disabled and still owns.
        var labels: [String]
        var updated: Date

        init(profile: String, listVersion: Int, iosMajor: Int, groups: [String], allow: [String], labels: [String], updated: Date) {
            self.profile = profile
            self.listVersion = listVersion
            self.iosMajor = iosMajor
            self.groups = groups
            self.allow = allow
            self.labels = labels
            self.updated = updated
        }

        init?(propertyList: Any) {
            guard let plist = propertyList as? [String: Any],
                  let profile = plist["Profile"] as? String,
                  let labels = plist["Labels"] as? [String]
            else { return nil }
            self.profile = profile
            listVersion = (plist["ListVersion"] as? NSNumber)?.intValue ?? 0
            iosMajor = (plist["iOSMajor"] as? NSNumber)?.intValue ?? 0
            groups = plist["Groups"] as? [String] ?? []
            allow = plist["Allow"] as? [String] ?? []
            self.labels = labels
            updated = plist["Updated"] as? Date ?? Date(timeIntervalSince1970: 0)
        }

        var propertyList: [String: Any] {
            [
                "Profile": profile, "ListVersion": listVersion, "iOSMajor": iosMajor,
                "Groups": groups, "Allow": allow, "Labels": labels, "Updated": updated,
            ]
        }

        /// The record in JSON terms, for a reply.
        var json: [String: Any] {
            [
                "profile": profile, "list_version": listVersion, "ios_major": iosMajor,
                "groups": groups, "allow": allow, "labels": labels,
                "updated": ISO8601DateFormatter().string(from: updated),
            ]
        }
    }

    static func readRecord(at path: String = recordPath) -> Record? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return Record(propertyList: plist)
    }

    /// Replaces the record in one rename.
    static func writeRecord(_ record: Record, to path: String = recordPath) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755],
        )
        let data = try PropertyListSerialization.data(fromPropertyList: record.propertyList, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
