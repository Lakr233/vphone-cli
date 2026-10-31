// The iPhone Duo's inner display. A real Duo drives two panels: the cover is
// Main (device tree display0) and the inner panel is a second built-in,
// always-connected display (display1), 2007x2853 mounted at 270 degrees so it
// reads landscape. This guest has one portrait panel. backboardd publishes
// the inner panel as a software render display shaped like the hardware one,
// SpringBoard resolves the fold postures (FoldingDual open, FullyClosed
// closed) for both displays natively, and the lit display is shown on the
// one panel. See
// Research/Guest/iphone_duo_bringup.md.

#import "FoldDisplayPrivate.h"

__attribute__((constructor)) static void vpInstallFoldDisplay(void) {
    char product[128] = {0};
    size_t productLength = sizeof(product);
    if (sysctlbyname("hw.machine", product, &productLength, NULL, 0) != 0 || strcmp(product, "iPhone19,4") != 0)
        return;
    if (strcmp(getprogname(), "backboardd") == 0) {
        vpInstallInnerRenderDisplay();
    } else if (strcmp(getprogname(), "SpringBoard") == 0) {
        vpInstallSharedPanel();
        vpInstallInnerDisplayAdapter();
        vpInstallDualStatusLookup();
    }
}
