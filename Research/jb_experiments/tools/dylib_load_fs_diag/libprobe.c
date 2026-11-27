#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

__attribute__((constructor))
static void libprobe_ctor(void) {
    const char *exe = _dyld_get_image_name(0);
    Dl_info info;
    const char *lib = dladdr((const void *)&libprobe_ctor, &info) ? info.dli_fname : "?";
    printf("LIBLOADED pid=%d exe=%s lib=%s\n", getpid(), exe ? exe : "?", lib);
    fflush(stdout);
}
