@testable import VPhoneCore
import Testing

struct VerbosityTests {
    @Test func countClampsToRange() {
        #expect(VPhoneVerbosity(count: 0) == .quiet)
        #expect(VPhoneVerbosity(count: 1) == .info)
        #expect(VPhoneVerbosity(count: 2) == .debug)
        #expect(VPhoneVerbosity(count: 3) == .trace)
        #expect(VPhoneVerbosity(count: 9) == .trace)   // clamp up
        #expect(VPhoneVerbosity(count: -4) == .quiet)   // clamp down
    }

    @Test func gatesAreMonotonic() {
        #expect(VPhoneVerbosity.quiet.showsToolDetail == false)
        #expect(VPhoneVerbosity.info.showsToolDetail == true)
        #expect(VPhoneVerbosity.debug.tracesInternals == false)
        #expect(VPhoneVerbosity.trace.tracesInternals == true)
        #expect(VPhoneVerbosity.quiet < .info)
        #expect(VPhoneVerbosity.debug < .trace)
    }
}
