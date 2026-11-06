#include "../FlutterRemapFix/FlutterRemapPolicy.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    const char *app = "/private/var/containers/Bundle/Application/id/Probe.app/Probe";
    const char *src = "/private/var/containers/Bundle/Application/id/Probe.app/Frameworks/App.framework/App";
    const char *caller = "/private/var/containers/Bundle/Application/id/Probe.app/Frameworks/Flutter.framework/Flutter";
    assert(vpFlutterRemapCandidate(app, src, caller, 16384, 32768, 0x4000, 1, true));
    assert(vpFlutterBundleImages("/Applications/Other.app/Runner", "/Applications/Other.app/Frameworks/App.framework/App", "/Applications/Other.app/Frameworks/Flutter.framework/Flutter"));
    assert(!vpFlutterBundleImages(app, "/Applications/Other.app/Frameworks/App.framework/App", caller));
    assert(!vpFlutterBundleImages(app, src, "/Applications/Other.app/Frameworks/Flutter.framework/Flutter"));
    assert(!vpFlutterBundleImages("/tmp/Probe", src, caller));
    assert(!vpFlutterBundleImages("/tmp/not.appx/Probe", src, caller));
    assert(!vpFlutterBundleImages("/tmp/.app/", src, caller));
    assert(!vpFlutterBundleImages("Probe", src, caller));
    assert(!vpFlutterBundleImages(app, "/tmp/App", caller));
    assert(!vpFlutterBundleImages(NULL, src, caller));
    assert(!vpFlutterBundleImages(app, NULL, caller));
    assert(!vpFlutterBundleImages(app, src, NULL));
    // Policy receives canonical paths; a different/unresolved root is rejected.
    assert(!vpFlutterBundleImages("/var/containers/Bundle/Application/id/Probe.app/Probe", src, caller));
    assert(!vpFlutterRemapCandidate(app, src, caller, 0, 32768, 0x4000, 1, true));
    assert(!vpFlutterRemapCandidate(app, src, caller, 16384, 65536, 0x4000, 1, true));
    assert(!vpFlutterRemapCandidate(app, src, caller, 16384, 32768, 1, 1, true));
    assert(!vpFlutterRemapCandidate(app, src, caller, 16384, 32768, 0x4000, 0, true));
    assert(!vpFlutterRemapCandidate(app, src, caller, 16384, 32768, 0x4000, 1, false));
    // Shorebird Flutter 3.41.9 uses the same 32 KiB callback template at 0x8000.
    assert(vpFlutterRemapCandidate(app, src, caller, 32768, 32768, 0x4000, 1, true));
    assert(!vpFlutterRemapCandidate(app, src, caller, 24576, 32768, 0x4000, 1, true));
    assert(!vpFlutterRemapCandidate(app, src, caller, 49152, 32768, 0x4000, 1, true));
    assert(!vpFlutterRemapCandidate(app, src, caller, 32768, 16384, 0x4000, 1, true));
    assert(!vpFlutterRemapCandidate(app, src, caller, 32768, 32768, 1, 1, true));
    assert(!vpFlutterRemapCandidate(app, src, caller, 32768, 32768, 0x4000, 0, true));
    assert(!vpFlutterRemapCandidate(app, src, caller, 32768, 32768, 0x4000, 1, false));
    assert(!vpFlutterRemapCandidate(app, "/Applications/Other.app/Frameworks/App.framework/App", caller, 32768, 32768, 0x4000, 1, true));
    assert(!vpFlutterRemapCandidate(app, src, "/Applications/Other.app/Frameworks/Flutter.framework/Flutter", 32768, 32768, 0x4000, 1, true));
    puts("FlutterRemapPolicyTests: bundle isolation and remap boundaries passed");
}
