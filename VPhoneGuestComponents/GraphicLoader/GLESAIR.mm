// Complete the argument metadata of the AIR modules AppleMetalGLRenderer builds
// for OpenGL ES shaders, so GPUCompiler can make a metallib of them.
//
// GLEngine writes the older AIR argument layout the AGX backend reads: a buffer
// is `i32 index, "air.buffer", ["air.buffer_size", i32 size,]
// "air.location_index", i32 slot, i32 count, "air.read"` and stops there, and
// most nodes have no type or argument name. llvm::air::Reflection::create
// (MTLMetalFunctionCreate) reads the layout the Metal front end writes, in
// which a buffer goes on with "air.address_space", "air.arg_type_size" and
// "air.arg_type_align_size", and every node ends with "air.arg_type_name" and
// "air.arg_name". It indexes the missing operands without a bounds check and
// crashes the compiler service. Each node gets the fields it lacks, in the
// front end's order, derived from the entry point's own parameter and return
// types; nothing the module already says is changed.
//
// The LLVM C API in the guest's libLLVM can read metadata but not replace a
// node's operand, so the module is printed, its argument lines extended, and
// the text parsed back into a new module in the same context.
//
// AppleMetalGLRenderer also requests pointCoordYFlipEnabled on every render
// pass. The supported PV path does not honor that private flag, so implement
// its effect at metadata-identified GLES fragment point-coordinate inputs. This
// is independent of AGX_GL_VIEWPORT_INVERT_CONFIG. Native Metal modules are
// untouched; a module marker prevents applying the conversion twice.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "GLESAIR.h"

extern "C" {
    typedef struct LLVMOpaqueContext *LLVMContextRef;
    typedef struct LLVMOpaqueType *LLVMTypeRef;
    typedef struct LLVMOpaqueTargetData *LLVMTargetDataRef;
    typedef struct LLVMOpaqueMemoryBuffer *LLVMMemoryBufferRef;
    typedef struct LLVMOpaqueBasicBlock *LLVMBasicBlockRef;
    typedef struct LLVMOpaqueBuilder *LLVMBuilderRef;
    typedef struct LLVMOpaqueUse *LLVMUseRef;

    LLVMContextRef LLVMGetModuleContext(LLVMModuleRef M);
    unsigned LLVMGetNamedMetadataNumOperands(LLVMModuleRef M, const char *Name);
    void LLVMGetNamedMetadataOperands(LLVMModuleRef M, const char *Name, LLVMValueRef *Dest);
    unsigned LLVMGetMDNodeNumOperands(LLVMValueRef V);
    void LLVMGetMDNodeOperands(LLVMValueRef V, LLVMValueRef *Dest);
    const char *LLVMGetMDString(LLVMValueRef V, unsigned *Length);
    LLVMValueRef LLVMIsAMDString(LLVMValueRef Val);
    char *LLVMPrintModuleToString(LLVMModuleRef M);
    void LLVMDisposeMessage(char *Message);
    LLVMMemoryBufferRef LLVMCreateMemoryBufferWithMemoryRangeCopy(const char *InputData, size_t InputDataLength, const char *BufferName);
    int LLVMParseIRInContext(LLVMContextRef ContextRef, LLVMMemoryBufferRef MemBuf, LLVMModuleRef *OutM, char **OutMessage);

    LLVMTypeRef LLVMGlobalGetValueType(LLVMValueRef Global);
    LLVMTypeRef LLVMGetReturnType(LLVMTypeRef FunctionTy);
    unsigned LLVMCountParamTypes(LLVMTypeRef FunctionTy);
    void LLVMGetParamTypes(LLVMTypeRef FunctionTy, LLVMTypeRef *Dest);
    int LLVMGetTypeKind(LLVMTypeRef Ty);
    unsigned LLVMGetIntTypeWidth(LLVMTypeRef IntegerTy);
    unsigned LLVMGetVectorSize(LLVMTypeRef VectorTy);
    LLVMTypeRef LLVMGetElementType(LLVMTypeRef Ty);
    unsigned LLVMGetArrayLength(LLVMTypeRef ArrayTy);
    unsigned LLVMCountStructElementTypes(LLVMTypeRef StructTy);
    LLVMTypeRef LLVMStructGetTypeAtIndex(LLVMTypeRef StructTy, unsigned i);
    const char *LLVMGetStructName(LLVMTypeRef Ty);
    unsigned LLVMGetPointerAddressSpace(LLVMTypeRef PointerTy);
    LLVMTargetDataRef LLVMGetModuleDataLayout(LLVMModuleRef M);
    unsigned long long LLVMABISizeOfType(LLVMTargetDataRef TD, LLVMTypeRef Ty);
    unsigned LLVMABIAlignmentOfType(LLVMTargetDataRef TD, LLVMTypeRef Ty);
    LLVMValueRef LLVMIsAFunction(LLVMValueRef Val);
    LLVMValueRef LLVMIsAConstantInt(LLVMValueRef Val);
    LLVMTypeRef LLVMTypeOf(LLVMValueRef Val);
    unsigned long long LLVMConstIntGetZExtValue(LLVMValueRef ConstantVal);
    LLVMValueRef LLVMGetParam(LLVMValueRef Fn, unsigned Index);
    LLVMUseRef LLVMGetFirstUse(LLVMValueRef Val);
    LLVMBasicBlockRef LLVMGetFirstBasicBlock(LLVMValueRef Fn);
    LLVMBasicBlockRef LLVMGetNextBasicBlock(LLVMBasicBlockRef BB);
    LLVMValueRef LLVMGetFirstInstruction(LLVMBasicBlockRef BB);
    LLVMValueRef LLVMGetNextInstruction(LLVMValueRef Inst);
    LLVMValueRef LLVMIsAPHINode(LLVMValueRef Val);
    LLVMValueRef LLVMIsAReturnInst(LLVMValueRef Val);
    unsigned LLVMGetNumOperands(LLVMValueRef Val);
    LLVMValueRef LLVMGetOperand(LLVMValueRef Val, unsigned Index);
    LLVMBuilderRef LLVMCreateBuilderInContext(LLVMContextRef C);
    void LLVMPositionBuilderBefore(LLVMBuilderRef Builder, LLVMValueRef Instr);
    void LLVMDisposeBuilder(LLVMBuilderRef Builder);
    LLVMTypeRef LLVMInt32TypeInContext(LLVMContextRef C);
    LLVMValueRef LLVMConstInt(LLVMTypeRef IntTy, unsigned long long N, int SignExtend);
    LLVMValueRef LLVMConstReal(LLVMTypeRef RealTy, double N);
    LLVMValueRef LLVMBuildExtractElement(LLVMBuilderRef, LLVMValueRef VecVal, LLVMValueRef Index, const char *Name);
    LLVMValueRef LLVMBuildFSub(LLVMBuilderRef, LLVMValueRef LHS, LLVMValueRef RHS, const char *Name);
    LLVMValueRef LLVMBuildFAdd(LLVMBuilderRef, LLVMValueRef LHS, LLVMValueRef RHS, const char *Name);
    LLVMValueRef LLVMBuildFMul(LLVMBuilderRef, LLVMValueRef LHS, LLVMValueRef RHS, const char *Name);
    LLVMValueRef LLVMBuildExtractValue(LLVMBuilderRef, LLVMValueRef AggVal, unsigned Index, const char *Name);
    LLVMValueRef LLVMBuildInsertValue(LLVMBuilderRef, LLVMValueRef AggVal, LLVMValueRef EltVal, unsigned Index, const char *Name);
    LLVMValueRef LLVMBuildInsertElement(LLVMBuilderRef, LLVMValueRef VecVal, LLVMValueRef EltVal, LLVMValueRef Index, const char *Name);
    void LLVMReplaceAllUsesWith(LLVMValueRef OldVal, LLVMValueRef NewVal);
    void LLVMSetOperand(LLVMValueRef User, unsigned Index, LLVMValueRef Val);
    LLVMValueRef LLVMMDNodeInContext(LLVMContextRef C, LLVMValueRef *Vals, unsigned Count);
    void LLVMAddNamedMetadataOperand(LLVMModuleRef M, const char *Name, LLVMValueRef Val);
    int LLVMVerifyModule(LLVMModuleRef M, int Action, char **OutMessage);
    void LLVMDisposeModule(LLVMModuleRef M);
}

namespace {

// LLVMTypeKind values; stable across the releases that still have typed pointers.
enum { kindHalf = 1, kindFloat = 2, kindDouble = 3, kindInteger = 8, kindStruct = 10, kindArray = 11, kindPointer = 12, kindVector = 13 };

std::vector<LLVMValueRef> operands(LLVMValueRef node) {
    std::vector<LLVMValueRef> ops(LLVMGetMDNodeNumOperands(node));
    if (!ops.empty())
        LLVMGetMDNodeOperands(node, ops.data());
    return ops;
}

std::string stringOf(LLVMValueRef value) {
    if (!value || !LLVMIsAMDString(value))
        return {};
    unsigned length = 0;
    const char *s = LLVMGetMDString(value, &length);
    return s ? std::string(s, length) : std::string();
}

// The Metal spelling of a type, as the front end writes it in air.arg_type_name.
std::string typeName(LLVMTypeRef type) {
    switch (LLVMGetTypeKind(type)) {
    case kindHalf: return "half";
    case kindFloat: return "float";
    case kindDouble: return "double";
    case kindInteger:
        switch (LLVMGetIntTypeWidth(type)) {
        case 1: return "bool";
        case 8: return "char";
        case 16: return "short";
        case 64: return "long";
        default: return "int";
        }
    case kindVector: return typeName(LLVMGetElementType(type)) + std::to_string(LLVMGetVectorSize(type));
    case kindArray: return typeName(LLVMGetElementType(type)) + "[" + std::to_string(LLVMGetArrayLength(type)) + "]";
    case kindPointer: return typeName(LLVMGetElementType(type));
    case kindStruct: {
        const char *name = LLVMGetStructName(type);
        if (name && !strcmp(name, "struct._sampler_t"))
            return "sampler";
        return "struct";
    }
    default: return "void";
    }
}

// The operands of a `!N = !{...}` line, split at top-level commas.
std::vector<std::string> lineOperands(const std::string &line) {
    std::vector<std::string> ops;
    size_t open = line.find("!{");
    size_t close = line.rfind('}');
    if (open == std::string::npos || close == std::string::npos || close < open)
        return ops;
    std::string current;
    int depth = 0;
    bool quoted = false;
    for (size_t i = open + 2; i < close; i++) {
        char c = line[i];
        if (c == '"' && (i == 0 || line[i - 1] != '\\'))
            quoted = !quoted;
        if (!quoted) {
            if (c == '{' || c == '(' || c == '<' || c == '[')
                depth++;
            else if (c == '}' || c == ')' || c == '>' || c == ']')
                depth--;
            else if (c == ',' && depth == 0) {
                ops.push_back(current);
                current.clear();
                continue;
            }
        }
        if (!(current.empty() && c == ' '))
            current += c;
    }
    if (!current.empty())
        ops.push_back(current);
    return ops;
}

bool hasKey(const std::vector<std::string> &ops, const char *key) {
    std::string quoted = std::string("!\"") + key + "\"";
    for (const std::string &op : ops)
        if (op == quoted)
            return true;
    return false;
}

struct Entry {
    std::vector<LLVMTypeRef> params;
    LLVMTypeRef result = nullptr;
};

class Rewriter {
public:
    Rewriter(LLVMModuleRef module, std::string text) : module(module), layout(LLVMGetModuleDataLayout(module)) {
        size_t start = 0;
        while (start < text.size()) {
            size_t end = text.find('\n', start);
            if (end == std::string::npos)
                end = text.size();
            lines.push_back(text.substr(start, end - start));
            start = end + 1;
        }
        for (size_t i = 0; i < lines.size(); i++) {
            const std::string &line = lines[i];
            if (line.size() > 1 && line[0] == '!') {
                size_t eq = line.find(" = ");
                if (eq != std::string::npos)
                    index[line.substr(0, eq)] = i;
            }
        }
    }

    void completeStage(const char *stage) {
        unsigned count = LLVMGetNamedMetadataNumOperands(module, stage);
        if (count == 0)
            return;
        std::vector<LLVMValueRef> nodes(count);
        LLVMGetNamedMetadataOperands(module, stage, nodes.data());
        auto named = index.find(std::string("!") + stage);
        if (named == index.end())
            return;
        std::vector<std::string> ids = lineOperands(lines[named->second]);
        for (size_t e = 0; e < ids.size() && e < nodes.size(); e++) {
            std::vector<LLVMValueRef> ops = operands(nodes[e]);
            if (ops.size() < 3 || !ops[0])
                continue;
            Entry entry;
            LLVMTypeRef function = LLVMGlobalGetValueType(ops[0]);
            entry.params.resize(LLVMCountParamTypes(function));
            if (!entry.params.empty())
                LLVMGetParamTypes(function, entry.params.data());
            entry.result = LLVMGetReturnType(function);
            auto line = index.find(ids[e]);
            if (line == index.end())
                continue;
            std::vector<std::string> fields = lineOperands(lines[line->second]);
            if (fields.size() < 3)
                continue;
            completeList(fields[fields.size() - 2], entry, true);
            completeList(fields[fields.size() - 1], entry, false);
        }
    }

    std::string text() const {
        std::string out;
        for (const std::string &line : lines)
            out += line + "\n";
        return out;
    }

    bool changed = false;

private:
    LLVMModuleRef module;
    LLVMTargetDataRef layout;
    std::vector<std::string> lines;
    std::map<std::string, size_t> index;
    std::set<std::string> done;

    LLVMTypeRef outputType(const Entry &entry, size_t i) {
        if (LLVMGetTypeKind(entry.result) == kindStruct)
            return i < LLVMCountStructElementTypes(entry.result) ? LLVMStructGetTypeAtIndex(entry.result, (unsigned)i) : nullptr;
        return i == 0 ? entry.result : nullptr;
    }

    void completeList(const std::string &id, const Entry &entry, bool outputs) {
        auto list = index.find(id);
        if (list == index.end())
            return;
        std::vector<std::string> nodes = lineOperands(lines[list->second]);
        for (size_t i = 0; i < nodes.size(); i++) {
            auto node = index.find(nodes[i]);
            if (node == index.end() || done.count(nodes[i]))
                continue;
            done.insert(nodes[i]);
            std::vector<std::string> ops = lineOperands(lines[node->second]);
            if (ops.empty())
                continue;
            LLVMTypeRef type = nullptr;
            std::string name;
            if (outputs) {
                type = outputType(entry, i);
                name = "_gles_out" + std::to_string(i);
            } else if (ops[0].rfind("i32 ", 0) == 0) {
                unsigned long p = strtoul(ops[0].c_str() + 4, nullptr, 10);
                type = p < entry.params.size() ? entry.params[p] : nullptr;
                name = "_gles_arg" + std::to_string(p);
            }
            std::string extra = completion(ops, type, name, outputs);
            if (extra.empty())
                continue;
            std::string &line = lines[node->second];
            line.insert(line.rfind('}'), extra);
            changed = true;
        }
    }

    // The fields the front end would have written after the node's own, in
    // its order, as text to insert before the node's closing brace.
    std::string completion(const std::vector<std::string> &ops, LLVMTypeRef type, const std::string &name, bool output) {
        std::string extra;
        auto string = [&](const std::string &s) { extra += ", !\"" + s + "\""; };
        auto integer = [&](unsigned long long n) { extra += ", i32 " + std::to_string(n); };
        bool buffer = !output && ops.size() > 1 && ops[1] == "!\"air.buffer\"";
        if (buffer && type && LLVMGetTypeKind(type) == kindPointer) {
            LLVMTypeRef pointee = LLVMGetElementType(type);
            // Some producers already supply only part of the buffer layout.
            // Complete each field independently without duplicating or
            // replacing the producer's existing values.
            if (!hasKey(ops, "air.address_space")) {
                string("air.address_space");
                integer(LLVMGetPointerAddressSpace(type));
            }
            if (!hasKey(ops, "air.arg_type_size")) {
                string("air.arg_type_size");
                integer(LLVMABISizeOfType(layout, pointee));
            }
            if (!hasKey(ops, "air.arg_type_align_size")) {
                string("air.arg_type_align_size");
                integer(LLVMABIAlignmentOfType(layout, pointee));
            }
        }
        if (!hasKey(ops, "air.arg_type_name")) {
            string("air.arg_type_name");
            string(type ? typeName(type) : "void");
        }
        // The front end names no render target.
        bool renderTarget = output && ops[0] == "!\"air.render_target\"";
        if (!renderTarget && !hasKey(ops, "air.arg_name") && !name.empty()) {
            string("air.arg_name");
            string(name);
        }
        return extra;
    }
};

constexpr const char *pointCoordinateMarker = "vphone.gles.point_coord_y_flipped";
constexpr const char *depthClipMarker = "vphone.gles.depth_clip_zero_to_one";

struct PositionReturn {
    LLVMValueRef instruction;
    int field; // -1 for a direct vector return.
};

// AIR output metadata is ordered by return-aggregate field. Never infer the
// position from field names or from a vector's shape alone.
bool positionReturns(LLVMModuleRef module, std::vector<PositionReturn> &result, const char **error) {
    if (LLVMGetNamedMetadataNumOperands(module, depthClipMarker))
        return true;
    unsigned count = LLVMGetNamedMetadataNumOperands(module, "air.vertex");
    std::vector<LLVMValueRef> entries(count);
    if (count)
        LLVMGetNamedMetadataOperands(module, "air.vertex", entries.data());
    std::set<LLVMValueRef> seen;
    for (LLVMValueRef entry : entries) {
        auto fields = operands(entry);
        if (fields.size() != 3 || !fields[0] || !LLVMIsAFunction(fields[0])) {
            *error = "OpenGL ES vertex entry has no supported AIR signature";
            return false;
        }
        LLVMValueRef function = fields[0];
        if (!seen.insert(function).second)
            continue;
        LLVMTypeRef type = LLVMGetReturnType(LLVMGlobalGetValueType(function));
        bool aggregate = LLVMGetTypeKind(type) == kindStruct;
        auto outputs = operands(fields[1]);
        int position = -1;
        for (size_t i = 0; i < outputs.size(); ++i) {
            auto output = operands(outputs[i]);
            if (output.empty() || stringOf(output[0]) != "air.position")
                continue;
            if (position >= 0) {
                *error = "OpenGL ES vertex entry has multiple position outputs";
                return false;
            }
            position = (int)i;
        }
        if (position < 0 || (aggregate ? outputs.size() != LLVMCountStructElementTypes(type) : outputs.size() != 1)) {
            *error = "OpenGL ES position metadata does not match its return type";
            return false;
        }
        LLVMTypeRef vector = aggregate ? LLVMStructGetTypeAtIndex(type, position) : type;
        if (LLVMGetTypeKind(vector) != kindVector || LLVMGetVectorSize(vector) != 4 ||
            LLVMGetTypeKind(LLVMGetElementType(vector)) != kindFloat) {
            *error = "OpenGL ES position output must be float4";
            return false;
        }
        size_t before = result.size();
        for (LLVMBasicBlockRef block = LLVMGetFirstBasicBlock(function); block; block = LLVMGetNextBasicBlock(block))
            for (LLVMValueRef inst = LLVMGetFirstInstruction(block); inst; inst = LLVMGetNextInstruction(inst))
                if (LLVMIsAReturnInst(inst) && LLVMGetNumOperands(inst) == 1)
                    result.push_back({inst, aggregate ? position : -1});
        if (result.size() == before) {
            *error = "OpenGL ES vertex entry has no value return";
            return false;
        }
    }
    return true;
}

void convertPositions(LLVMModuleRef module, const std::vector<PositionReturn> &returns) {
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMBuilderRef builder = LLVMCreateBuilderInContext(context);
    LLVMValueRef zIndex = LLVMConstInt(LLVMInt32TypeInContext(context), 2, 0);
    LLVMValueRef wIndex = LLVMConstInt(LLVMInt32TypeInContext(context), 3, 0);
    for (const auto &site : returns) {
        LLVMPositionBuilderBefore(builder, site.instruction);
        LLVMValueRef value = LLVMGetOperand(site.instruction, 0);
        LLVMValueRef position = site.field < 0 ? value :
            LLVMBuildExtractValue(builder, value, site.field, "vphone.clip.position");
        LLVMValueRef z = LLVMBuildExtractElement(builder, position, zIndex, "vphone.clip.z");
        LLVMValueRef w = LLVMBuildExtractElement(builder, position, wIndex, "vphone.clip.w");
        LLVMValueRef half = LLVMConstReal(LLVMTypeOf(z), 0.5);
        // Scale separately to avoid overflowing finite z+w. Preserve x,y,w
        // and every other output, including transform-feedback varyings.
        z = LLVMBuildFMul(builder, z, half, "vphone.clip.half_z");
        w = LLVMBuildFMul(builder, w, half, "vphone.clip.half_w");
        z = LLVMBuildFAdd(builder, z, w, "vphone.clip.metal_z");
        position = LLVMBuildInsertElement(builder, position, z, zIndex, "vphone.clip.converted");
        if (site.field >= 0)
            position = LLVMBuildInsertValue(builder, value, position, site.field, "vphone.clip.result");
        LLVMSetOperand(site.instruction, 0, position);
    }
    LLVMDisposeBuilder(builder);
    LLVMValueRef version = LLVMConstInt(LLVMInt32TypeInContext(context), 1, 0);
    LLVMAddNamedMetadataOperand(module, depthClipMarker, LLVMMDNodeInContext(context, &version, 1));
}

struct PointCoordinate {
    LLVMValueRef parameter;
    LLVMTypeRef scalar;
    LLVMValueRef insertion;
};

bool pointCoordinates(LLVMModuleRef module, std::vector<PointCoordinate> &result, const char **error) {
    if (LLVMGetNamedMetadataNumOperands(module, pointCoordinateMarker))
        return true;
    unsigned count = LLVMGetNamedMetadataNumOperands(module, "air.fragment");
    std::vector<LLVMValueRef> entries(count);
    if (count)
        LLVMGetNamedMetadataOperands(module, "air.fragment", entries.data());
    std::set<LLVMValueRef> seen;
    for (LLVMValueRef entry : entries) {
        auto fields = operands(entry);
        if (fields.size() < 3 || !fields[0] || !LLVMIsAFunction(fields[0]))
            continue;
        LLVMValueRef function = fields[0];
        LLVMTypeRef signature = LLVMGlobalGetValueType(function);
        std::vector<LLVMTypeRef> parameters(LLVMCountParamTypes(signature));
        if (!parameters.empty())
            LLVMGetParamTypes(signature, parameters.data());
        for (LLVMValueRef node : operands(fields[2])) {
            auto argument = operands(node);
            if (argument.size() < 2 || stringOf(argument[1]) != "air.point_coord")
                continue;
            if (!argument[0] || !LLVMIsAConstantInt(argument[0]) ||
                LLVMGetIntTypeWidth(LLVMTypeOf(argument[0])) > 64) {
                *error = "OpenGL ES point-coordinate input has no supported integer parameter index";
                return false;
            }
            unsigned long long index = LLVMConstIntGetZExtValue(argument[0]);
            if (index >= parameters.size() || LLVMGetTypeKind(parameters[index]) != kindVector ||
                LLVMGetVectorSize(parameters[index]) != 2) {
                *error = "OpenGL ES point-coordinate input must be a two-component vector";
                return false;
            }
            LLVMTypeRef scalar = LLVMGetElementType(parameters[index]);
            if (LLVMGetTypeKind(scalar) != kindHalf && LLVMGetTypeKind(scalar) != kindFloat) {
                *error = "OpenGL ES point-coordinate input must contain half or float values";
                return false;
            }
            LLVMValueRef parameter = LLVMGetParam(function, (unsigned)index);
            if (!LLVMGetFirstUse(parameter) || !seen.insert(parameter).second)
                continue;
            LLVMBasicBlockRef block = LLVMGetFirstBasicBlock(function);
            LLVMValueRef insertion = block ? LLVMGetFirstInstruction(block) : nullptr;
            while (insertion && LLVMIsAPHINode(insertion))
                insertion = LLVMGetNextInstruction(insertion);
            if (!insertion) {
                *error = "OpenGL ES point-coordinate input has no function body";
                return false;
            }
            result.push_back({parameter, scalar, insertion});
        }
    }
    return true;
}

void flipPointCoordinates(LLVMModuleRef module, const std::vector<PointCoordinate> &inputs) {
    LLVMContextRef context = LLVMGetModuleContext(module);
    LLVMBuilderRef builder = LLVMCreateBuilderInContext(context);
    LLVMValueRef oneIndex = LLVMConstInt(LLVMInt32TypeInContext(context), 1, 0);
    for (const PointCoordinate &input : inputs) {
        LLVMPositionBuilderBefore(builder, input.insertion);
        LLVMValueRef y = LLVMBuildExtractElement(builder, input.parameter, oneIndex, "vphone.point.y");
        LLVMValueRef flipped = LLVMBuildFSub(builder, LLVMConstReal(input.scalar, 1.0), y, "vphone.point.flipped_y");
        LLVMValueRef coordinate = LLVMBuildInsertElement(builder, input.parameter, flipped, oneIndex, "vphone.point.coord");
        LLVMReplaceAllUsesWith(input.parameter, coordinate);
        // RAUW includes the two instructions just created. Restore their
        // source operands to the original parameter; otherwise they form a
        // self-reference. All original uses now see the converted vector.
        LLVMSetOperand(y, 0, input.parameter);
        LLVMSetOperand(coordinate, 0, input.parameter);
    }
    LLVMDisposeBuilder(builder);
    LLVMValueRef version = LLVMConstInt(LLVMInt32TypeInContext(context), 1, 0);
    LLVMAddNamedMetadataOperand(module, pointCoordinateMarker, LLVMMDNodeInContext(context, &version, 1));
}

} // namespace

bool isGLESModule(LLVMModuleRef module) {
    unsigned count = LLVMGetNamedMetadataNumOperands(module, "air.language_version");
    if (count == 0)
        return false;
    std::vector<LLVMValueRef> versions(count);
    LLVMGetNamedMetadataOperands(module, "air.language_version", versions.data());
    std::vector<LLVMValueRef> ops = operands(versions[0]);
    if (ops.empty())
        return false;
    const std::string language = stringOf(ops[0]);
    // ES1's generated fixed-function programs use the same legacy argument
    // layout as GLSL, but identify themselves as "OpenGL ES Program".
    return language == "OpenGL ES GLSL" || language == "OpenGL ES Program";
}

LLVMModuleRef completedGLESModule(LLVMModuleRef module, const char **error, bool depthClip) {
    *error = nullptr;
    if (!module || !isGLESModule(module))
        return nullptr;
    std::vector<PointCoordinate> inputs;
    if (!pointCoordinates(module, inputs, error))
        return nullptr;
    std::vector<PositionReturn> positions;
    if (depthClip && !positionReturns(module, positions, error))
        return nullptr;
    char *printed = LLVMPrintModuleToString(module);
    if (!printed) {
        *error = "cannot print the OpenGL ES module";
        return nullptr;
    }
    Rewriter rewriter(module, printed);
    LLVMDisposeMessage(printed);
    for (const char *stage : {"air.vertex", "air.fragment", "air.kernel"})
        rewriter.completeStage(stage);
    if (!rewriter.changed && inputs.empty() && positions.empty())
        return nullptr;
    std::string text = rewriter.text();
    LLVMMemoryBufferRef buffer = LLVMCreateMemoryBufferWithMemoryRangeCopy(text.data(), text.size(), "OpenGL ES shader");
    LLVMModuleRef completed = nullptr;
    char *message = nullptr;
    if (LLVMParseIRInContext(LLVMGetModuleContext(module), buffer, &completed, &message)) {
        static std::string reason;
        reason = std::string("cannot parse the completed OpenGL ES module: ") + (message ? message : "");
        if (message)
            LLVMDisposeMessage(message);
        *error = reason.c_str();
        return nullptr;
    }
    if (!inputs.empty()) {
        // Resolve parameters in the parsed copy, never mutate the caller's
        // module or retain references to its original function values.
        inputs.clear();
        if (!pointCoordinates(completed, inputs, error)) {
            LLVMDisposeModule(completed);
            return nullptr;
        }
        flipPointCoordinates(completed, inputs);
    }
    if (!positions.empty()) {
        positions.clear();
        if (!positionReturns(completed, positions, error)) {
            LLVMDisposeModule(completed);
            return nullptr;
        }
        convertPositions(completed, positions);
    }
    if (!inputs.empty() || !positions.empty()) {
        if (LLVMVerifyModule(completed, 2 /* LLVMReturnStatusAction */, &message)) {
            static thread_local std::string reason;
            reason = std::string("invalid OpenGL ES coordinate conversion: ") + (message ? message : "");
            if (message)
                LLVMDisposeMessage(message);
            LLVMDisposeModule(completed);
            *error = reason.c_str();
            return nullptr;
        }
        if (message)
            LLVMDisposeMessage(message);
    }
    return completed;
}
