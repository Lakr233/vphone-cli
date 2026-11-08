import Foundation

/// Methods beyond the original surface live in one file per area. Each area
/// returns nil for a method it does not own, so the first match answers.
extension GuestAPI {
    static var areas: [GuestMethodArea] {
        [
            .make(CoreMethod.self, executeCore),
            .make(DeviceMethod.self, executeDevice),
            .make(InputMethod.self, executeInput),
            .make(InterfaceMethod.self, executeInterface),
            .make(ProcessMethod.self, executeProcess),
            .make(ServiceMethod.self, executeService),
            .make(LogMethod.self, executeLog),
            .make(AppDetailMethod.self, executeAppDetail),
            .make(SystemAppsMethod.self, executeSystemApps),
            .make(FileToolMethod.self, executeFileTool),
            .make(StorageMethod.self, executeStorage),
            .make(EnvironmentMethod.self, executeEnvironment),
            .make(DeviceIdentityMethod.self, executeDeviceIdentity),
            .make(SetupAssistantMethod.self, executeSetupAssistant),
            .make(FirstBootMethod.self, executeFirstBoot),
            .make(TimeZoneMethod.self, executeTimeZone),
            .make(ClockMethod.self, executeClock),
            .make(AudioLatencyMethod.self, executeAudioLatency),
            .make(GyroscopeMethod.self, executeGyroscope),
            .make(AttitudeMethod.self, executeAttitude),
            .make(HomePodDisplayMethod.self, executeHomePodDisplay),
            .make(HomePodDebugMethod.self, executeHomePodDebug),
            .make(HomeViewDistanceMethod.self, executeHomeViewDistance),
            .make(VisionOSImmersionMethod.self, executeVisionOSImmersion),
            .make(ScriptMethod.self, executeScript),
        ]
    }
}
