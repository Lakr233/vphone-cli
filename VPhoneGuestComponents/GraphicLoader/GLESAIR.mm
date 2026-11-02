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
        if (buffer && type && LLVMGetTypeKind(type) == kindPointer && !hasKey(ops, "air.address_space")) {
            LLVMTypeRef pointee = LLVMGetElementType(type);
            string("air.address_space");
            integer(LLVMGetPointerAddressSpace(type));
            string("air.arg_type_size");
            integer(LLVMABISizeOfType(layout, pointee));
            string("air.arg_type_align_size");
            integer(LLVMABIAlignmentOfType(layout, pointee));
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

} // namespace

bool isGLESModule(LLVMModuleRef module) {
    unsigned count = LLVMGetNamedMetadataNumOperands(module, "air.language_version");
    if (count == 0)
        return false;
    std::vector<LLVMValueRef> versions(count);
    LLVMGetNamedMetadataOperands(module, "air.language_version", versions.data());
    std::vector<LLVMValueRef> ops = operands(versions[0]);
    return !ops.empty() && stringOf(ops[0]) == "OpenGL ES GLSL";
}

LLVMModuleRef completedGLESModule(LLVMModuleRef module, const char **error) {
    char *printed = LLVMPrintModuleToString(module);
    if (!printed) {
        *error = "cannot print the OpenGL ES module";
        return nullptr;
    }
    Rewriter rewriter(module, printed);
    LLVMDisposeMessage(printed);
    for (const char *stage : {"air.vertex", "air.fragment", "air.kernel"})
        rewriter.completeStage(stage);
    if (!rewriter.changed)
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
    return completed;
}
