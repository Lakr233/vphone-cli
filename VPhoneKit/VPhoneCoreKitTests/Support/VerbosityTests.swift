import Testing
@testable import VPhoneCoreKit

struct VerbosityTests {
    @Test func `count clamps to range`() {
        #expect(VPhoneVerbosity(count: 0) == .quiet)
        #expect(VPhoneVerbosity(count: 1) == .info)
        #expect(VPhoneVerbosity(count: 2) == .debug)
        #expect(VPhoneVerbosity(count: 3) == .trace)
        #expect(VPhoneVerbosity(count: 9) == .trace) // clamp up
        #expect(VPhoneVerbosity(count: -4) == .quiet) // clamp down
    }

    @Test func `gates are monotonic`() {
        #expect(VPhoneVerbosity.quiet.showsToolDetail == false)
        #expect(VPhoneVerbosity.info.showsToolDetail == true)
        #expect(VPhoneVerbosity.debug.tracesInternals == false)
        #expect(VPhoneVerbosity.trace.tracesInternals == true)
        #expect(VPhoneVerbosity.quiet < .info)
        #expect(VPhoneVerbosity.debug < .trace)
    }
}
