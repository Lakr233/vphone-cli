#ifndef VPHONE_INJECTION_ENVIRONMENT_H
#define VPHONE_INJECTION_ENVIRONMENT_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VP_SYSTEM_HOOK "/usr/lib/SystemHook-vphone.dylib"

typedef struct {
    char **values;
    char *hook;
    char *root;
} VPInjectionEnvironment;

static const char *vpEnvValue(char *const env[], const char *name) {
    if (!env)
        return NULL;
    size_t length = strlen(name);
    for (size_t i = 0; env[i]; i++) {
        if (strncmp(env[i], name, length) == 0 && env[i][length] == '=')
            return env[i] + length + 1;
    }
    return NULL;
}

static int vpEnvIsOne(char *const env[], const char *name) {
    const char *value = vpEnvValue(env, name);
    return value && strcmp(value, "1") == 0;
}

static int vpInjectionDisabled(char *const env[]) {
    return vpEnvIsOne(env, "DISABLE_TWEAKS") || vpEnvIsOne(env, "_SafeMode") || vpEnvIsOne(env, "_MSSafeMode");
}

static int vpHasHook(const char *paths) {
    if (!paths)
        return 0;
    const size_t length = strlen(VP_SYSTEM_HOOK);
    for (const char *start = paths; *start;) {
        const char *end = strchr(start, ':');
        size_t count = end ? (size_t)(end - start) : strlen(start);
        if (count == length && strncmp(start, VP_SYSTEM_HOOK, count) == 0)
            return 1;
        if (!end)
            break;
        start = end + 1;
    }
    return 0;
}

// Keep the bootstrap path with the injected hook across xpcproxy's new envp.
static VPInjectionEnvironment vpInsertHook(char *const env[], const char *root) {
    VPInjectionEnvironment result = {0};
    size_t count = 0;
    size_t dyld = (size_t)-1;
    size_t jbRoot = (size_t)-1;
    if (env) {
        while (count < 4096 && env[count]) {
            if (strncmp(env[count], "DYLD_INSERT_LIBRARIES=", 22) == 0)
                dyld = count;
            if (strncmp(env[count], "VPHONE_JB_ROOT=", 15) == 0)
                jbRoot = count;
            count++;
        }
        if (count == 4096)
            return result;
    }
    const char *existing = dyld == (size_t)-1 ? NULL : env[dyld] + 22;
    int addHook = !vpHasHook(existing);
    int addRoot = root && *root &&
                  (jbRoot == (size_t)-1 || strcmp(env[jbRoot] + 15, root) != 0);
    if (!addHook && !addRoot)
        return result;
    if (addHook) {
        size_t size = strlen("DYLD_INSERT_LIBRARIES=") + strlen(VP_SYSTEM_HOOK) + 1;
        if (existing && *existing)
            size += strlen(existing) + 1;
        result.hook = malloc(size);
        if (!result.hook)
            return result;
        if (existing && *existing)
            snprintf(result.hook, size, "DYLD_INSERT_LIBRARIES=%s:%s", VP_SYSTEM_HOOK, existing);
        else
            snprintf(result.hook, size, "DYLD_INSERT_LIBRARIES=%s", VP_SYSTEM_HOOK);
    }
    if (addRoot) {
        size_t size = strlen("VPHONE_JB_ROOT=") + strlen(root) + 1;
        result.root = malloc(size);
        if (!result.root) {
            free(result.hook);
            return (VPInjectionEnvironment){0};
        }
        snprintf(result.root, size, "VPHONE_JB_ROOT=%s", root);
    }
    result.values = calloc(count + (addHook && dyld == (size_t)-1) +
                               (addRoot && jbRoot == (size_t)-1) + 1, sizeof(char *));
    if (!result.values) {
        free(result.hook);
        free(result.root);
        return (VPInjectionEnvironment){0};
    }
    for (size_t i = 0; i < count; i++)
        result.values[i] = addHook && i == dyld ? result.hook :
                           addRoot && i == jbRoot ? result.root : env[i];
    if (addHook && dyld == (size_t)-1)
        result.values[count++] = result.hook;
    if (addRoot && jbRoot == (size_t)-1)
        result.values[count] = result.root;
    return result;
}

static void vpFreeEnvironment(VPInjectionEnvironment *environment) {
    free(environment->values);
    free(environment->hook);
    free(environment->root);
}

#endif
