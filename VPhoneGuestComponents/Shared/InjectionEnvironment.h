#ifndef VPHONE_INJECTION_ENVIRONMENT_H
#define VPHONE_INJECTION_ENVIRONMENT_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VP_SYSTEM_HOOK "/usr/lib/SystemHook-vphone.dylib"

typedef struct {
    char **values;
    char *inserted;
} VPInjectionEnvironment;

static int vpEnvIsOne(char *const env[], const char *name) {
    if (!env)
        return 0;
    size_t length = strlen(name);
    for (size_t i = 0; env[i]; i++) {
        if (strncmp(env[i], name, length) == 0 && env[i][length] == '=') {
            return strcmp(env[i] + length + 1, "1") == 0;
        }
    }
    return 0;
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

// Returns an owned environment only when the hook needs to be added.
static VPInjectionEnvironment vpInsertHook(char *const env[]) {
    VPInjectionEnvironment result = {0};
    size_t count = 0;
    size_t dyld = (size_t)-1;
    if (env) {
        while (count < 4096 && env[count]) {
            if (strncmp(env[count], "DYLD_INSERT_LIBRARIES=", 22) == 0)
                dyld = count;
            count++;
        }
        if (count == 4096)
            return result;
    }
    const char *existing = dyld == (size_t)-1 ? NULL : env[dyld] + 22;
    if (vpHasHook(existing))
        return result;
    size_t size = strlen("DYLD_INSERT_LIBRARIES=") + strlen(VP_SYSTEM_HOOK) + 1;
    if (existing && *existing)
        size += strlen(existing) + 1;
    result.inserted = malloc(size);
    result.values = calloc(count + (dyld == (size_t)-1 ? 2 : 1), sizeof(char *));
    if (!result.inserted || !result.values) {
        free(result.inserted);
        free(result.values);
        return (VPInjectionEnvironment){0};
    }
    if (existing && *existing) {
        snprintf(result.inserted, size, "DYLD_INSERT_LIBRARIES=%s:%s", VP_SYSTEM_HOOK, existing);
    } else {
        snprintf(result.inserted, size, "DYLD_INSERT_LIBRARIES=%s", VP_SYSTEM_HOOK);
    }
    for (size_t i = 0; i < count; i++)
        result.values[i] = i == dyld ? result.inserted : env[i];
    if (dyld == (size_t)-1)
        result.values[count] = result.inserted;
    return result;
}

static void vpFreeEnvironment(VPInjectionEnvironment *environment) {
    free(environment->values);
    free(environment->inserted);
}

#endif
