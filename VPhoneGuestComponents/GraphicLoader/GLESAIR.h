// OpenGL ES shader modules from AppleMetalGLRenderer: see GLESAIR.mm.
#pragma once

typedef struct LLVMOpaqueModule *LLVMModuleRef;
typedef struct LLVMOpaqueValue *LLVMValueRef;

// True for a module whose air.language_version is "OpenGL ES GLSL".
bool isGLESModule(LLVMModuleRef module);

// A copy of the module, in its context, with the argument metadata fields
// GPUCompiler needs added. Null when nothing was missing, or on failure with
// *error set.
LLVMModuleRef completedGLESModule(LLVMModuleRef module, const char **error);
