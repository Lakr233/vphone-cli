// Host proof harness for the compiler plugin's OpenGL ES path (GraphicLoader).
//
// The original fixtures are iOS 27.0.1 guest captures; the point fixtures'
// headers identify their iOS 26.6.2 captures and metadata completion state.
// Each module is run through the plugin as MTLCompilerService runs it, and its
// metallib must load into host Metal as the right function stage. The tests
// check linkage and pixels, while native guest probes separately exercise PV
// transport and draw submission. Built as a dylib and loaded by
// GLESAIRTestRunner after libLLVM and libGPUCompiler, as the compiler service
// loads the plugin.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <cmath>

#include "GLESAIR.h"

typedef struct LLVMOpaqueContext *LLVMContextRef;
typedef struct LLVMOpaqueMemoryBuffer *LLVMMemoryBufferRef;

extern "C" {
LLVMContextRef LLVMContextCreate(void);
LLVMMemoryBufferRef LLVMCreateMemoryBufferWithMemoryRangeCopy(const char *InputData, size_t InputDataLength, const char *BufferName);
int LLVMParseIRInContext(LLVMContextRef ContextRef, LLVMMemoryBufferRef MemBuf, LLVMModuleRef *OutM, char **OutMessage);
char *LLVMPrintModuleToString(LLVMModuleRef M);
void LLVMDisposeMessage(char *Message);

void *MTLCompilerCreate(void *targetInfo, uint64_t version);
bool MTLCompilerBuildRequestWithOptions(void *compiler, const void *inputData, size_t inputSize, unsigned flags, LLVMModuleRef module,
                                        const void **outCode, size_t *outCodeSize, const void **outReflection, size_t *outReflectionSize,
                                        const void **outDebug, size_t *outDebugSize, const char **outError);
}

static int failures = 0;

static void check(bool condition, const char *what) {
    printf("%s %s\n", condition ? "ok  " : "FAIL", what);
    fflush(stdout);
    if (!condition)
        failures++;
}

static LLVMModuleRef parseText(const char *text, size_t size, const char *name) {
    LLVMModuleRef module = nullptr;
    char *error = nullptr;
    if (LLVMParseIRInContext(LLVMContextCreate(), LLVMCreateMemoryBufferWithMemoryRangeCopy(text, size, name), &module, &error)) {
        if (error)
            LLVMDisposeMessage(error);
        return nullptr;
    }
    return module;
}

static LLVMModuleRef parse(const char *directory, const char *name) {
    NSString *path = [NSString stringWithFormat:@"%s/%s", directory, name];
    NSData *text = [NSData dataWithContentsOfFile:path];
    return text ? parseText((const char *)text.bytes, text.length, name) : nullptr;
}

static std::string moduleText(LLVMModuleRef module) {
    char *printed = LLVMPrintModuleToString(module);
    std::string text = printed ? printed : "";
    if (printed)
        LLVMDisposeMessage(printed);
    return text;
}

static bool contains(const std::string &text, const char *needle) {
    return text.find(needle) != std::string::npos;
}

static size_t occurrences(const std::string &text, const std::string &needle) {
    size_t count = 0, offset = 0;
    while ((offset = text.find(needle, offset)) != std::string::npos) {
        count++;
        offset += needle.size();
    }
    return count;
}

// A float4 uniform lives in address space 2; the fixture data layout gives it
// size/alignment 16. Exercise every subset of preexisting layout fields, not
// just the all-missing layout of the originally captured module. Derive an
// ES1 language control from the same IR to exercise its legacy metadata too.
static void testPartialBufferCompletion(const char *fixtures) {
    LLVMModuleRef original = parse(fixtures, "textured-fragment.ll");
    check(original != nullptr, "the partial-buffer source fixture parses");
    if (!original)
        return;
    const std::string source = moduleText(original);
    const std::string bufferNode = "!{i32 2, !\"air.buffer\", !\"air.buffer_size\", i32 112, !\"air.location_index\", i32 12, i32 1, !\"air.read\"}";
    const size_t location = source.find(bufferNode);
    const size_t languageOffset = source.find("OpenGL ES GLSL");
    check(location != std::string::npos && languageOffset != std::string::npos,
          "the fixture has the expected GLSL language and legacy uniform-buffer node");
    if (location == std::string::npos || languageOffset == std::string::npos)
        return;
    const char *keys[] = {"air.address_space", "air.arg_type_size", "air.arg_type_align_size"};
    const unsigned derived[] = {2, 16, 16};
    for (const char *language : {"OpenGL ES GLSL", "OpenGL ES Program"}) for (unsigned mask = 0; mask < 8; mask++) {
        std::string input = source;
        std::string additions;
        for (unsigned field = 0; field < 3; field++) {
            if (mask & (1u << field))
                additions += ", !\"" + std::string(keys[field]) + "\", i32 " + std::to_string(derived[field]);
        }
        input.insert(location + bufferNode.size() - 1, additions);
        input.replace(languageOffset, strlen("OpenGL ES GLSL"), language);
        LLVMModuleRef module = parseText(input.data(), input.size(), "partial buffer");
        const char *error = nullptr;
        LLVMModuleRef completed = module ? completedGLESModule(module, &error) : nullptr;
        std::string label = std::string(language) + " partial buffer mask " + std::to_string(mask);
        check(completed && !error, (label + " completes").c_str());
        if (!completed)
            continue;
        const std::string output = moduleText(completed);
        bool fieldsCorrect = true;
        for (unsigned field = 0; field < 3; field++) {
            const std::string key = "!\"" + std::string(keys[field]) + "\"";
            fieldsCorrect &= occurrences(output, key) == 1;
            fieldsCorrect &= contains(output, (key + ", i32 " + std::to_string(derived[field])).c_str());
        }
        check(fieldsCorrect, (label + " has each correct layout field exactly once").c_str());
        error = nullptr;
        check(completedGLESModule(completed, &error) == nullptr && !error && moduleText(completed) == output,
              (label + " is unchanged on a second completion").c_str());
    }

    // Existing producer values are authoritative even when the LLVM pointee's
    // ABI size is smaller than the producer's full logical buffer type.
    std::string preserved = source;
    preserved.insert(location + bufferNode.size() - 1,
                     ", !\"air.address_space\", i32 2, !\"air.arg_type_size\", i32 112, !\"air.arg_type_align_size\", i32 16");
    LLVMModuleRef module = parseText(preserved.data(), preserved.size(), "existing buffer layout");
    const char *error = nullptr;
    LLVMModuleRef completed = module ? completedGLESModule(module, &error) : nullptr;
    const std::string output = completed ? moduleText(completed) : "";
    check(completed && !error && occurrences(output, "!\"air.arg_type_size\"") == 1 &&
          contains(output, "!\"air.arg_type_size\", i32 112"), "an existing buffer type size is preserved");
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

static id<MTLFunction> fixtureFunction(const char *fixtures, const char *file, MTLFunctionType type,
                                      void *compiler, id<MTLDevice> device) {
    LLVMModuleRef module = parse(fixtures, file);
    std::string label(file);
    bool recognized = module && isGLESModule(module);
    check(recognized, (label + " is recognized as GLES").c_str());
    if (!recognized)
        return nil;
    const void *code = nullptr, *reflection = nullptr, *debug = nullptr;
    size_t codeSize = 0, reflectionSize = 0, debugSize = 0;
    const char *error = nullptr;
    bool failed = MTLCompilerBuildRequestWithOptions(compiler, nullptr, 0, 0, module,
        &code, &codeSize, &reflection, &reflectionSize, &debug, &debugSize, &error);
    check(!failed && code && codeSize, (label + " builds a metallib" + (error ? std::string(": ") + error : "")).c_str());
    if (failed || !code || !codeSize)
        return nil;
    NSError *libraryError = nil;
    id<MTLLibrary> library = [device newLibraryWithData:dispatch_data_create(code, codeSize, nil, nil) error:&libraryError];
    id<MTLFunction> value = library.functionNames.count == 1 ? [library newFunctionWithName:library.functionNames.firstObject] : nil;
    check(value && value.functionType == type, (label + " loads as its expected function stage").c_str());
    return value;
}

static void testPointCoordinateAdaptation(const char *fixtures) {
    for (const char *file : {"point-coord-es1-fragment.ll", "point-coord-es3-fragment.ll"}) {
        LLVMModuleRef original = parse(fixtures, file);
        check(original != nullptr, "the captured point-coordinate module parses");
        if (!original)
            continue;
        std::string source = moduleText(original), label(file);
        const char *error = nullptr;
        LLVMModuleRef completed = completedGLESModule(original, &error);
        check(completed && !error, (label + " adapts even though metadata was already complete").c_str());
        check(moduleText(original) == source, (label + " leaves the caller's original module unchanged").c_str());
        if (!completed)
            continue;
        const std::string output = moduleText(completed);
        check(contains(output, "!vphone.gles.point_coord_y_flipped =") &&
              contains(output, "vphone.point.flipped_y = fsub"), (label + " records the typed coordinate conversion").c_str());
        error = nullptr;
        check(completedGLESModule(completed, &error) == nullptr && !error && moduleText(completed) == output,
              (label + " is unchanged on a second module adaptation").c_str());

        std::string nonGLES = source;
        const char *language = contains(source, "OpenGL ES Program") ? "OpenGL ES Program" : "OpenGL ES GLSL";
        nonGLES.replace(nonGLES.find(language), strlen(language), "Metal");
        LLVMModuleRef metal = parseText(nonGLES.data(), nonGLES.size(), "native Metal point coordinate");
        check(metal != nullptr, "the native Metal point-coordinate control parses");
        if (!metal)
            continue;
        const std::string metalBefore = moduleText(metal);
        error = nullptr;
        check(!completedGLESModule(metal, &error) && !error && moduleText(metal) == metalBefore,
              (label + " does not adapt an otherwise identical native Metal module").c_str());

        std::string varying = source;
        const std::string semantic = "!\"air.point_coord\"";
        varying.replace(varying.find(semantic), semantic.size(), "!\"air.fragment_input\", !\"user(point_coord)\", !\"air.perspective\", !\"air.center\"");
        LLVMModuleRef ordinary = parseText(varying.data(), varying.size(), "ordinary varying with point-like name");
        check(ordinary != nullptr, "the ordinary varying control parses");
        if (!ordinary)
            continue;
        const std::string ordinaryBefore = moduleText(ordinary);
        error = nullptr;
        check(!completedGLESModule(ordinary, &error) && !error && moduleText(ordinary) == ordinaryBefore,
              (label + " leaves an ordinary user varying unchanged").c_str());
    }

    // Malformed metadata must produce a recoverable compiler error, without
    // indexing beyond the signature, asserting in APInt, or touching input IR.
    LLVMModuleRef sourceModule = parse(fixtures, "point-coord-es3-fragment.ll");
    if (!sourceModule)
        return;
    const std::string source = moduleText(sourceModule);
    const std::string pointInput = "!{i32 0, !\"air.point_coord\"";
    const size_t inputOffset = source.find(pointInput);
    check(inputOffset != std::string::npos, "the malformed-input fixture has its expected point semantic");
    if (inputOffset == std::string::npos)
        return;
    for (const char *index : {"i32 2", "i32 1", "i128 18446744073709551616", "null"}) {
        std::string malformed = source;
        malformed.replace(inputOffset, pointInput.size(), std::string("!{") + index + ", !\"air.point_coord\"");
        LLVMModuleRef module = parseText(malformed.data(), malformed.size(), "invalid point-coordinate index");
        check(module != nullptr, "the malformed point-coordinate metadata parses as IR");
        if (!module)
            continue;
        std::string before = moduleText(module);
        const char *error = nullptr;
        check(!completedGLESModule(module, &error) && error && moduleText(module) == before,
              "unsupported point-coordinate metadata fails safely without changing the input module");
    }
}

// Replay the actual ES1 float2 texture-coordinate replacement and ES3 half2
// gl_PointCoord programs. The PV path drops Apple's private render-pass Y
// flip; leave that host flag at its default false and require the shader to
// produce the same result as Apple's requested flip. Enabling the host flag
// as well would apply the conversion twice and invalidate this oracle.
// Expected Y follows the upper-left point-coordinate origin:
// t = 1/2 - (yf + 1/2 - yw) / size (OpenGL ES 2.0 section 3.3,
// OpenGL ES 3.0.6 section 3.4.1, and OES_point_sprite). X remains unchanged.
static void testPointCoordinatePixels(const char *fixtures) {
    struct { uint64_t target; } info = {0x700000002};
    void *compiler = MTLCompilerCreate(&info, 8);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    check(compiler && device, "the point-coordinate test has a compiler and device");
    if (!compiler || !device)
        return;
    for (bool es1 : {true, false}) {
        const char *vertexFile = es1 ? "point-coord-es1-vertex.ll" : "point-vertex.ll";
        const char *fragmentFile = es1 ? "point-coord-es1-fragment.ll" : "point-coord-es3-fragment.ll";
        std::string label = es1 ? "ES1 float2 point sprite" : "ES3 half2 point coordinate";
        id<MTLFunction> vertex = fixtureFunction(fixtures, vertexFile, MTLFunctionTypeVertex, compiler, device);
        id<MTLFunction> fragment = fixtureFunction(fixtures, fragmentFile, MTLFunctionTypeFragment, compiler, device);
        if (!vertex || !fragment)
            continue;
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = fragment;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        NSError *error = nil;
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        check(pipeline != nil, (label + " links into a host pipeline").c_str());
        if (!pipeline)
            continue;
        MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
        textureDescriptor.storageMode = MTLStorageModeShared;
        textureDescriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> output = [device newTextureWithDescriptor:textureDescriptor];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = output;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> command = [[device newCommandQueue] commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:pipeline];
        const float position[] = {0.125f, 0.125f}, uniform[] = {3, 0, 0, 0}, zero[] = {0, 0, 0, 0};
        const float currents[] = {1, 1, 1, 1, 0, 0, 0, 1};
        [encoder setVertexBytes:position length:sizeof(position) atIndex:15];
        [encoder setVertexBytes:uniform length:sizeof(uniform) atIndex:12];
        [encoder setVertexBytes:currents length:sizeof(currents) atIndex:14];
        [encoder setFragmentBytes:zero length:sizeof(zero) atIndex:12];
        if (es1) {
            MTLTextureDescriptor *sourceDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
            sourceDescriptor.storageMode = MTLStorageModeShared;
            sourceDescriptor.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> source = [device newTextureWithDescriptor:sourceDescriptor];
            uint8_t texels[64] = {};
            const uint8_t values[] = {43, 43, 128, 213};
            for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
                int i = (y * 4 + x) * 4;
                texels[i] = values[x]; texels[i + 1] = values[y]; texels[i + 2] = texels[i + 3] = 255;
            }
            [source replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:texels bytesPerRow:16];
            MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
            sampler.minFilter = MTLSamplerMinMagFilterNearest;
            sampler.magFilter = MTLSamplerMinMagFilterNearest;
            [encoder setFragmentTexture:source atIndex:0];
            [encoder setFragmentSamplerState:[device newSamplerStateWithDescriptor:sampler] atIndex:0];
        }
        [encoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:1];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        check(command.status == MTLCommandBufferStatusCompleted, (label + " completes its GPU command buffer").c_str());
        uint8_t pixels[256] = {};
        [output getBytes:pixels bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
        bool matches = output != nil;
        const int gradient[] = {43, 128, 213};
        for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) {
            bool covered = x >= 3 && x <= 5 && y >= 2 && y <= 4;
            int expected[] = {covered ? gradient[x - 3] : 0, covered ? gradient[4 - y] : 0, covered ? 255 : 0, 255};
            for (int c = 0; c < 4; c++)
                matches &= abs((int)pixels[(y * 8 + x) * 4 + c] - expected[c]) <= 2;
        }
        check(matches, (label + " renders the full expected XY gradient and footprint").c_str());
    }
}

// Exercise a real captured return aggregate, then a direct-return vertex with
// two return blocks. Only the metadata-identified position may be converted.
static void testDepthAdaptation(const char *fixtures) {
    LLVMModuleRef original = parse(fixtures, "textured-vertex.ll");
    std::string before = moduleText(original);
    const char *error = nullptr;
    LLVMModuleRef converted = completedGLESModule(original, &error, true);
    check(converted && !error && moduleText(original) == before, "captured vertex depth conversion preserves its input module");
    if (!converted) return;
    std::string after = moduleText(converted);
    check(contains(after, "vphone.clip.position") && contains(after, "vphone.gles.depth_clip_zero_to_one"),
          "captured aggregate position is converted and marked");
    check(!completedGLESModule(converted, &error, true) && !error, "depth conversion is idempotent");

    std::string native = before;
    native.replace(native.find("OpenGL ES GLSL"), strlen("OpenGL ES GLSL"), "Metal");
    LLVMModuleRef metal = parseText(native.data(), native.size(), "native depth control");
    check(metal && !completedGLESModule(metal, &error, true) && !error,
          "native Metal bypasses GLES depth conversion");
}

static void testDepthPixels() {
    // AIR's legacy buffer and builtin metadata shapes follow the captured
    // GLES fixtures. The uniform contains three clip-space vertices.
    const char *source = R"(
target datalayout = "e-p:64:64:64-i64:64-f32:32:32-v128:128:128-n8:16:32"
target triple = "air64-apple-ios"
define <4 x float> @depth_vertex(i32 %id, <4 x float> addrspace(2)* %vertices) {
entry:
  %ptr = getelementptr <4 x float>, <4 x float> addrspace(2)* %vertices, i32 %id
  %position = load <4 x float>, <4 x float> addrspace(2)* %ptr, align 16
  %first = icmp eq i32 %id, 0
  br i1 %first, label %left, label %right
left:
  ret <4 x float> %position
right:
  ret <4 x float> %position
}
!air.language_version = !{!0}
!air.vertex = !{!1}
!0 = !{!"OpenGL ES GLSL", i32 3, i32 0, i32 0}
!1 = !{<4 x float> (i32, <4 x float> addrspace(2)*)* @depth_vertex, !2, !4}
!2 = !{!3}
!3 = !{!"air.position"}
!4 = !{!5, !6}
!5 = !{i32 0, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"id"}
!6 = !{i32 1, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read"}
)";
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    NSError *metalError = nil;
    id<MTLLibrary> fragments = [device newLibraryWithSource:
        @"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 depth_fragment(float4 p [[position]]) { return float4(p.z,1,0,1); }"
        options:nil error:&metalError];
    struct { uint64_t target; } info = {0x700000002};
    void *compiler = MTLCompilerCreate(&info, 8);
    for (const char *language : {"OpenGL ES GLSL", "OpenGL ES Program"}) {
        std::string input(source);
        input.replace(input.find("OpenGL ES GLSL"), strlen("OpenGL ES GLSL"), language);
        LLVMModuleRef module = parseText(input.data(), input.size(), language);
        const char *error = nullptr;
        LLVMModuleRef converted = module ? completedGLESModule(module, &error, true) : nullptr;
        check(converted && !error, "direct position with multiple returns converts");
        if (!converted) continue;
        const void *code = nullptr, *reflection = nullptr, *debug = nullptr;
        size_t codeSize = 0, reflectionSize = 0, debugSize = 0;
        bool failed = MTLCompilerBuildRequestWithOptions(compiler, nullptr, 0, 0, converted,
            &code, &codeSize, &reflection, &reflectionSize, &debug, &debugSize, &error);
        check(!failed && code && codeSize, "converted GLES position builds a metallib");
        if (failed || !code) continue;
        id<MTLLibrary> vertex = [device newLibraryWithData:dispatch_data_create(code, codeSize, nil, nil) error:&metalError];
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [vertex newFunctionWithName:@"depth_vertex"];
        descriptor.fragmentFunction = [fragments newFunctionWithName:@"depth_fragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&metalError];
        check(pipeline != nil, "converted depth shader links with fragment window-depth input");
        if (!pipeline) continue;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:16 height:16 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [device newTextureWithDescriptor:td];
        unsigned matches = 0;
        for (NSArray *range in @[@[@0,@1], @[@.1,@.7], @[@.8,@.2], @[@.3,@.3]])
        for (float w : {.5f, 1.f, 2.f, -1.f}) for (float ndc : {-1.2f,-1.f,-.5f,0.f,.5f,1.f,1.2f}) {
            float z = ndc*w;
            float vertices[] = {-.9f*w,-.9f*w,z,w, .9f*w,-.9f*w,z,w, 0,.9f*w,z,w};
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = texture;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(16/255.,32/255.,64/255.,1);
            id<MTLCommandBuffer> command = [queue commandBuffer];
            id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
            double near = [range[0] doubleValue], far = [range[1] doubleValue];
            [encoder setViewport:(MTLViewport){0,0,16,16,near,far}];
            [encoder setRenderPipelineState:pipeline];
            [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
            uint8_t pixel[4] = {};
            [texture getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(8,8,1,1) mipmapLevel:0];
            bool visible = w > 0 && fabs(ndc) <= 1;
            int depth = (int)round(255*(near+(ndc+1)*.5*(far-near)));
            bool correct = visible ? pixel[1] == 255 && abs(pixel[0]-depth) <= 1 : pixel[1] == 32 && pixel[2] == 64;
            matches += correct && command.status == MTLCommandBufferStatusCompleted;
        }
        check(matches == 112, (std::string(language) + " depth pixels match all 112 clip/w/range cases").c_str());
    }
}

extern "C" int GLESAIRRunTests(const char *fixtures) {
    @autoreleasepool {
        testCompletion(fixtures);
        testPartialBufferCompletion(fixtures);
        testMetallibs(fixtures);
        testPointCoordinateAdaptation(fixtures);
        testPointCoordinatePixels(fixtures);
        testDepthAdaptation(fixtures);
        testDepthPixels();
    }
    printf("%s\n", failures ? "GLES AIR tests FAILED" : "GLES AIR tests passed");
    return failures ? 1 : 0;
}
