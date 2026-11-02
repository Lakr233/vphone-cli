// Loads the host's libLLVM and libGPUCompiler globally, then the GLES AIR test
// dylib, whose plugin code resolves their symbols by flat lookup, as
// MTLCompilerService provides them to the plugin in the guest.

#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <GLESAIRTests.dylib> <fixtures directory>\n", argv[0]);
        return 2;
    }
    const char *libraries[] = {
        "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib",
        "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libGPUCompiler.dylib",
    };
    for (int i = 0; i < 2; i++) {
        if (!dlopen(libraries[i], RTLD_NOW | RTLD_GLOBAL)) {
            fprintf(stderr, "%s\n", dlerror());
            return 1;
        }
    }
    void *tests = dlopen(argv[1], RTLD_NOW);
    if (!tests) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    int (*run)(const char *) = (int (*)(const char *))dlsym(tests, "GLESAIRRunTests");
    return run ? run(argv[2]) : 1;
}
