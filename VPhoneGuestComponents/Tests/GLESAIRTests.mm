// Host proof harness for the compiler plugin's OpenGL ES path (GraphicLoader).
//
// The fixtures are AIR modules AppleMetalGLRenderer handed the plugin in an
// iOS 27.0.1 guest, dumped as text: a constant-colour fragment shader, and the
// fragment and vertex shaders of a textured, uniform-driven program. The host
// carries the same GPUCompiler (32023) as the guest, so each module is run
// through the plugin as MTLCompilerService runs it, and the metallib must load
// in the host's Metal as the right kind of function; the vertex and fragment
// functions must link into a render pipeline. Built as a dylib and loaded by
// GLESAIRTestRunner after libLLVM and libGPUCompiler, as the compiler service
// loads the plugin.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>
#include <cstring>
#include <string>

#include "GLESAIR.h"

typedef struct LLVMOpaqueContext *LLVMContextRef;
typedef struct LLVMOpaqueMemoryBuffer *LLVMMemoryBufferRef;

extern "C" {
LLVMContextRef LLVMContextCreate(void);
LLVMMemoryBufferRef LLVMCreateMemoryBufferWithMemoryRangeCopy(const char *InputData, size_t InputDataLength, const char *BufferName);
int LLVMParseIRInContext(LLVMContextRef ContextRef, LLVMMemoryBufferRef MemBuf, LLVMModuleRef *OutM, char **OutMessage);
char *LLVMPrintModuleToString(LLVMModuleRef M);

void *MTLCompilerCreate(void *targetInfo, uint64_t version);
bool MTLCompilerBuildRequestWithOptions(void *compiler, const void *inputData, size_t inputSize, unsigned flags, LLVMModuleRef module,
                                        const void **outCode, size_t *outCodeSize, const void **outReflection, size_t *outReflectionSize,
                                        const void **outDebug, size_t *outDebugSize, const char **outError);
}

static int failures = 0;

static void check(bool condition, const char *what) {
    printf("%s %s\n", condition ? "ok  " : "FAIL", what);
    if (!condition)
        failures++;
}

static LLVMModuleRef parse(const char *directory, const char *name) {
    NSString *path = [NSString stringWithFormat:@"%s/%s", directory, name];
    NSData *text = [NSData dataWithContentsOfFile:path];
    if (!text)
        return nullptr;
    LLVMModuleRef module = nullptr;
    char *error = nullptr;
    if (LLVMParseIRInContext(LLVMContextCreate(), LLVMCreateMemoryBufferWithMemoryRangeCopy((const char *)text.bytes, text.length, name), &module, &error))
        return nullptr;
    return module;
}

static bool contains(const std::string &text, const char *needle) {
    return text.find(needle) != std::string::npos;
}

// The rewritten metadata, checked line by line against what the Metal front end writes.
static void testCompletion(const char *fixtures) {
    LLVMModuleRef fragment = parse(fixtures, "textured-fragment.ll");
    check(fragment && isGLESModule(fragment), "the textured fragment module is an OpenGL ES module");
    const char *error = nullptr;
    LLVMModuleRef completed = completedGLESModule(fragment, &error);
    check(completed && !error, "the textured fragment module is completed");
    if (!completed)
        return;
    std::string text = LLVMPrintModuleToString(completed);
    check(contains(text, "!{i32 2, !\"air.buffer\", !\"air.buffer_size\", i32 112, !\"air.location_index\", i32 12, i32 1, !\"air.read\", "
                         "!\"air.address_space\", i32 2, !\"air.arg_type_size\", i32 16, !\"air.arg_type_align_size\", i32 16, "
                         "!\"air.arg_type_name\", !\"float4\", !\"air.arg_name\", !\"_gles_arg2\"}"),
          "the uniform buffer gains address space, size, alignment, type and name");
    check(contains(text, "!{i32 4, !\"air.sampler\", !\"air.location_index\", i32 0, i32 1, !\"air.arg_type_name\", !\"sampler\", !\"air.arg_name\", !\"_gles_arg4\"}"),
          "the sampler gains its type and name");
    check(contains(text, "!\"air.sample\", !\"air.arg_type_name\", !\"texture2d<float, sample>\", !\"air.arg_name\", !\"_gles_arg3\"}"),
          "the texture keeps its own type name and gains a name");
    check(contains(text, "!{!\"air.render_target\", i32 0, i32 0, !\"air.arg_type_name\", !\"half4\"}"),
          "the render target gains a type and no name, as the front end writes it");

    LLVMModuleRef vertex = parse(fixtures, "textured-vertex.ll");
    completed = vertex ? completedGLESModule(vertex, &error) : nullptr;
    text = completed ? LLVMPrintModuleToString(completed) : "";
    check(contains(text, "!{i32 1, !\"air.buffer\", !\"air.location_index\", i32 15, i32 1, !\"air.read\", !\"air.arg_type_name\", !\"void\", "
                         "!\"air.arg_name\", !\".hidden\", !\"air.address_space\", i32 1, !\"air.arg_type_size\", i32 16, !\"air.arg_type_align_size\", i32 1}"),
          "the vertex fetch buffer GLEngine already described is left as it is");
    check(contains(text, "!{!\"air.position\", !\"air.arg_type_name\", !\"float4\", !\"air.arg_name\", !\"_gles_out1\"}"),
          "the position output gains its type from the return struct");
}

// Each module through the plugin, then into the host's Metal.
static void testMetallibs(const char *fixtures) {
    struct { uint64_t target; } info = {0x700000002}; // AIR 2.7, as MTLCompilerService passes it
    void *compiler = MTLCompilerCreate(&info, 8);
    check(compiler != nullptr, "the plugin creates a compiler");
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLFunction> vertexFunction = nil, fragmentFunction = nil;
    struct { const char *file; MTLFunctionType type; } cases[] = {
        {"constant-fragment.ll", MTLFunctionTypeFragment},
        {"textured-fragment.ll", MTLFunctionTypeFragment},
        {"textured-vertex.ll", MTLFunctionTypeVertex},
    };
    for (auto &c : cases) {
        LLVMModuleRef module = parse(fixtures, c.file);
        const void *code = nullptr, *reflection = nullptr, *debug = nullptr;
        size_t codeSize = 0, reflectionSize = 0, debugSize = 0;
        const char *error = nullptr;
        bool failed = !module || MTLCompilerBuildRequestWithOptions(compiler, nullptr, 0, 0, module, &code, &codeSize, &reflection, &reflectionSize, &debug, &debugSize, &error);
        std::string what = std::string(c.file) + " builds a metallib" + (error ? std::string(": ") + error : "");
        check(!failed && code && codeSize > 0, what.c_str());
        if (failed || !code)
            continue;
        NSError *libraryError = nil;
        id<MTLLibrary> library = [device newLibraryWithData:dispatch_data_create(code, codeSize, nil, nil) error:&libraryError];
        id<MTLFunction> function = library.functionNames.count == 1 ? [library newFunctionWithName:library.functionNames.firstObject] : nil;
        what = std::string(c.file) + " loads in the host's Metal as one function of its stage";
        check(function && function.functionType == c.type, what.c_str());
        if (!strcmp(c.file, "textured-vertex.ll"))
            vertexFunction = function;
        if (!strcmp(c.file, "textured-fragment.ll"))
            fragmentFunction = function;
    }
    if (vertexFunction && fragmentFunction) {
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertexFunction;
        descriptor.fragmentFunction = fragmentFunction;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        NSError *pipelineError = nil;
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&pipelineError];
        check(pipeline != nil, "the textured program's vertex and fragment functions link into a render pipeline");
    }
}

extern "C" int GLESAIRRunTests(const char *fixtures) {
    @autoreleasepool {
        testCompletion(fixtures);
        testMetallibs(fixtures);
    }
    printf("%s\n", failures ? "GLES AIR tests FAILED" : "GLES AIR tests passed");
    return failures ? 1 : 0;
}
