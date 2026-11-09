// OpenGL ES shader modules from AppleMetalGLRenderer: see GLESAIR.mm.
#pragma once

typedef struct LLVMOpaqueModule *LLVMModuleRef;
typedef struct LLVMOpaqueValue *LLVMValueRef;

// True for GLES shaders ("OpenGL ES GLSL") and ES1 generated fixed-function
// programs ("OpenGL ES Program").
bool isGLESModule(LLVMModuleRef module);

// A copy of the module, in its context, with the argument metadata fields
// GPUCompiler needs added, and GLES fragment point-coordinate Y converted for
// the PV render-pass path. A metadata marker prevents repeated conversion.
// When depthClip is enabled, lower position.z to (z+w)/2. The installer must
// pair this with the renderer viewport correction and compiler cache identity.
// Non-GLES modules are unchanged. Null when no adaptation is needed, or on
// failure with *error set. The input module is never modified.
LLVMModuleRef completedGLESModule(LLVMModuleRef module, const char **error, bool depthClip = false);
