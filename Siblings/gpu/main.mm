// Reimplementation of libAppleParavirtCompilerPluginIOGPUFamily.dylib
// Metal shader compiler plugin for the paravirtualized GPU.
// Bridges between Metal's compiler interface and the GPUCompiler/LLVM pipeline.
//
// Reverse-engineered from the PCC DSC module.

#include <cstdlib>
#include <cstring>
#include <cstdint>

// --- LLVM C API (from libLLVM.dylib) ---
extern "C" {
    // Opaque types
    typedef struct LLVMOpaqueModule *LLVMModuleRef;
    typedef struct LLVMOpaqueMemoryBuffer *LLVMMemoryBufferRef;
    typedef struct LLVMOpaqueValue *LLVMValueRef;

    // LLVM buffer/module functions (confirmed exported via DSC auth_stubs)
    void LLVMDisposeMemoryBuffer(LLVMMemoryBufferRef MemBuf);
    const char *LLVMGetBufferStart(LLVMMemoryBufferRef MemBuf);
    size_t LLVMGetBufferSize(LLVMMemoryBufferRef MemBuf);
    const char *LLVMGetTarget(LLVMModuleRef M);
    LLVMModuleRef LLVMExtraMakeSharedModule(LLVMModuleRef M);
    void LLVMExtraDisposeSharedModule(LLVMModuleRef M);

    // LLVM metadata access (older C API, available since LLVM 3.x)
    unsigned LLVMGetNamedMetadataNumOperands(LLVMModuleRef M, const char *Name);
    void LLVMGetNamedMetadataOperands(LLVMModuleRef M, const char *Name, LLVMValueRef *Dest);
    unsigned LLVMGetMDNodeNumOperands(LLVMValueRef V);
    void LLVMGetMDNodeOperands(LLVMValueRef V, LLVMValueRef *Dest);
    const char *LLVMGetValueName2(LLVMValueRef Val, size_t *Length);
}

// --- GPUCompiler API (from libGPUCompiler.dylib) ---
extern "C" {
    typedef void *MTLGPUCompilerRef;
    typedef void *MTLMetalLibRef;
    typedef void *MTLMetalFunctionRef;

    MTLGPUCompilerRef MTLGPUCompilerCreate(int version);
    void MTLGPUCompilerDestroy(MTLGPUCompilerRef compiler);
    int MTLDowngradeAIRModule(LLVMModuleRef module, const char *targetTriple, int flags);
    MTLMetalLibRef MTLMetalLibCreateExecutableWithTriple(LLVMModuleRef sharedModule, const char *entryPointData);
    MTLMetalFunctionRef MTLMetalFunctionCreate(LLVMModuleRef sharedModule, const char *entryName);
    void MTLMetalLibInsertFunction(MTLMetalLibRef lib, MTLMetalFunctionRef func);
    LLVMMemoryBufferRef MTLWriteMetalLibToMemoryBuffer(MTLMetalLibRef lib);
}

// --- Compiler target info struct (passed by Metal framework) ---
struct AppleParavirtCompilerTargetInfo {
    const char *targetTriple;
};

// --- AppleParavirtCompiler class ---
class AppleParavirtCompiler {
public:
    virtual ~AppleParavirtCompiler();

    bool init(const AppleParavirtCompilerTargetInfo *info);

    bool buildRequestWithOptions(
        const void *inputData, size_t inputSize, unsigned int flags,
        LLVMModuleRef module,
        const void **outCode, size_t *outCodeSize,
        const void **outReflection, size_t *outReflectionSize,
        const void **outDebug, size_t *outDebugSize,
        const char **outError);

    void deleteCompilerReply();

private:
    LLVMMemoryBufferRef _bufferRef = nullptr;
    MTLGPUCompilerRef _gpuCompiler = nullptr;
    const char *_targetTriple = nullptr;
};

// Entry point metadata names to search in LLVM IR modules
static const char *entryPointsMetadata[] = {
    "air.vertex",
    "air.fragment",
    "air.kernel",
};
static const int numEntryPointsMetadata = 3;

// --- Implementation ---

AppleParavirtCompiler::~AppleParavirtCompiler() {
    if (_gpuCompiler) {
        MTLGPUCompilerDestroy(_gpuCompiler);
        _gpuCompiler = nullptr;
    }
}

bool AppleParavirtCompiler::init(const AppleParavirtCompilerTargetInfo *info) {
    _targetTriple = info->targetTriple;
    _gpuCompiler = MTLGPUCompilerCreate(1);
    return (_gpuCompiler != nullptr);
}

void AppleParavirtCompiler::deleteCompilerReply() {
    if (_bufferRef) {
        LLVMDisposeMemoryBuffer(_bufferRef);
        _bufferRef = nullptr;
    }
}

bool AppleParavirtCompiler::buildRequestWithOptions(
    const void *inputData, size_t inputSize, unsigned int flags,
    LLVMModuleRef module,
    const void **outCode, size_t *outCodeSize,
    const void **outReflection, size_t *outReflectionSize,
    const void **outDebug, size_t *outDebugSize,
    const char **outError)
{
    _bufferRef = nullptr;

    if (!module) {
        *outError = "null module";
        return true; // error
    }

    // Downgrade the AIR module for this target
    int result = MTLDowngradeAIRModule(module, _targetTriple, 0);
    if (!result) {
        // Downgrade returned 0 = success with nothing to do
        *outError = nullptr;
        return false; // success (no error)
    }

    if (!_gpuCompiler) {
        *outError = "no gpu compiler";
        return true;
    }

    // Search for entry point metadata in the module
    const char *entryName = nullptr;
    size_t entryNameLen = 0;

    for (int i = 0; i < numEntryPointsMetadata; i++) {
        unsigned numNamedOps = LLVMGetNamedMetadataNumOperands(module, entryPointsMetadata[i]);
        if (numNamedOps > 0) {
            LLVMValueRef *namedOps = (LLVMValueRef *)alloca(numNamedOps * sizeof(LLVMValueRef));
            LLVMGetNamedMetadataOperands(module, entryPointsMetadata[i], namedOps);
            LLVMValueRef mdNode = namedOps[0];
            if (mdNode) {
                unsigned numOps = LLVMGetMDNodeNumOperands(mdNode);
                if (numOps > 0) {
                    LLVMValueRef *ops = (LLVMValueRef *)alloca(numOps * sizeof(LLVMValueRef));
                    LLVMGetMDNodeOperands(mdNode, ops);
                    if (ops[0]) {
                        entryName = LLVMGetValueName2(ops[0], &entryNameLen);
                        break;
                    }
                }
            }
        }
    }

    // Get the target triple from the module
    const char *triple = LLVMGetTarget(module);

    // Create a metallib executable
    LLVMModuleRef sharedModule = LLVMExtraMakeSharedModule(module);

    // Build the entry point name string (may need null-termination)
    char *entryNameStr = nullptr;
    if (entryName && entryNameLen > 0) {
        entryNameStr = (char *)malloc(entryNameLen + 1);
        memcpy(entryNameStr, entryName, entryNameLen);
        entryNameStr[entryNameLen] = '\0';
    }

    // Create metallib with triple
    MTLMetalLibRef metalLib = MTLMetalLibCreateExecutableWithTriple(sharedModule,
                                                                     entryNameStr ? entryNameStr : "");

    if (entryNameStr) {
        free(entryNameStr);
    }

    if (!metalLib) {
        LLVMExtraDisposeSharedModule(sharedModule);
        *outError = "failed to create metallib";
        return true;
    }

    // Create and insert function
    MTLMetalFunctionRef func = MTLMetalFunctionCreate(sharedModule, entryName);
    MTLMetalLibInsertFunction(metalLib, func);

    // Write to memory buffer
    _bufferRef = MTLWriteMetalLibToMemoryBuffer(metalLib);
    if (!_bufferRef) {
        LLVMExtraDisposeSharedModule(sharedModule);
        *outError = "failed to write metallib";
        return true;
    }

    // Cleanup shared module
    LLVMExtraDisposeSharedModule(sharedModule);

    // Return compiled data
    *outCode = LLVMGetBufferStart(_bufferRef);
    *outCodeSize = LLVMGetBufferSize(_bufferRef);
    *outReflection = nullptr;
    *outReflectionSize = 0;
    *outDebug = nullptr;
    *outDebugSize = 0;
    *outError = nullptr;
    return false; // success (no error)
}

// --- Exported C interface ---

extern "C" {

__attribute__((visibility("default")))
void *MTLCompilerCreate(void *targetInfo, uint64_t version) {
    if (version != 8)
        return nullptr;

    AppleParavirtCompiler *compiler = new AppleParavirtCompiler();
    if (!compiler->init((const AppleParavirtCompilerTargetInfo *)targetInfo)) {
        delete compiler;
        return nullptr;
    }
    return compiler;
}

__attribute__((visibility("default")))
bool MTLCompilerBuildRequestWithOptions(
    void *compilerObj,
    const void *inputData, size_t inputSize, unsigned int flags,
    LLVMModuleRef module,
    const void **outCode, size_t *outCodeSize,
    const void **outReflection, size_t *outReflectionSize,
    const void **outDebug, size_t *outDebugSize,
    const char **outError)
{
    AppleParavirtCompiler *compiler = (AppleParavirtCompiler *)compilerObj;
    return compiler->buildRequestWithOptions(inputData, inputSize, flags, module,
                                             outCode, outCodeSize,
                                             outReflection, outReflectionSize,
                                             outDebug, outDebugSize,
                                             outError);
}

__attribute__((visibility("default")))
void MTLCompilerDelete(void *compilerObj) {
    if (compilerObj) {
        AppleParavirtCompiler *compiler = (AppleParavirtCompiler *)compilerObj;
        delete compiler;
    }
}

__attribute__((visibility("default")))
void MTLCompilerReleaseReply(void *compilerObj) {
    if (compilerObj) {
        AppleParavirtCompiler *compiler = (AppleParavirtCompiler *)compilerObj;
        compiler->deleteCompilerReply();
    }
}

} // extern "C"
