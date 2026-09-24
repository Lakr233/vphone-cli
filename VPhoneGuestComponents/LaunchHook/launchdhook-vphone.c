#include <dlfcn.h>
#include <dirent.h>
#include <ctype.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

// Neither bootstrap exists on the first boot. RootHide is chosen once and
// keeps one randomized root across later boots; ambiguity disables discovery.
static int vpFindJBRoot(char root[PATH_MAX]) {
    struct stat info;
    if (stat("/var/jb/usr/lib", &info) == 0 && S_ISDIR(info.st_mode)) {
        return realpath("/var/jb", root) != NULL;
    }
    const char *parent = "/private/var/containers/Bundle/Application";
    DIR *directory = opendir(parent);
    if (!directory) return 0;
    int matches = 0;
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        if (strncmp(entry->d_name, ".jbroot-", 8) != 0 || strlen(entry->d_name) != 24) continue;
        int valid = 1;
        for (unsigned index = 8; index < 24; index++) {
            if (!isxdigit((unsigned char)entry->d_name[index])) valid = 0;
        }
        if (!valid) continue;
        char candidate[PATH_MAX];
        int length = snprintf(candidate, sizeof(candidate), "%s/%s", parent, entry->d_name);
        if (length < 0 || (size_t)length >= sizeof(candidate)) continue;
        char library[PATH_MAX];
        length = snprintf(library, sizeof(library), "%s/usr/lib", candidate);
        if (length < 0 || (size_t)length >= sizeof(library) ||
            stat(library, &info) != 0 || !S_ISDIR(info.st_mode)) continue;
        if (!realpath(candidate, root)) continue;
        matches++;
    }
    closedir(directory);
    if (matches != 1) root[0] = '\0';
    return matches == 1;
}

// launchd itself uses kernel paths. Bootstrap tools may use vroot paths, but
// plist discovery and ProgramArguments handed to launchd must be physical.
typedef xpc_object_t (*VPGetValue)(xpc_object_t, const char *);
typedef xpc_object_t (*VPPlistDecoder)(const void *, size_t);
typedef int (*VPMemoryStatus)(uint32_t, int32_t, uint32_t, void *, size_t);
extern int memorystatus_control(uint32_t, int32_t, uint32_t, void *, size_t);

enum { VPSetJetsamHighWaterMark = 5, VPSetJetsamTaskLimit = 6 };

static VPGetValue vpOriginalGetValue(void) {
    return (VPGetValue)dlsym(RTLD_NEXT, "xpc_dictionary_get_value");
}

static VPMemoryStatus vpOriginalMemoryStatus(void) {
    return (VPMemoryStatus)dlsym(RTLD_NEXT, "memorystatus_control");
}

static int vpPhysicalProgram(const char *program, const char *root, char physical[PATH_MAX]) {
    if (!program || program[0] != '/') return 0;
    size_t rootLength = strlen(root);
    if (strncmp(program, root, rootLength) == 0 && program[rootLength] == '/') return 0;
    char canonical[PATH_MAX];
    if (realpath(program, canonical) &&
        strncmp(canonical, root, rootLength) == 0 && canonical[rootLength] == '/') return 0;
    int used = strncmp(program, "/rootfs/", 8) == 0
        ? snprintf(physical, PATH_MAX, "%s", program + 7)
        : snprintf(physical, PATH_MAX, "%s%s", root, program);
    return used > 0 && used < PATH_MAX;
}

static void vpPatchProgram(xpc_object_t plist, const char *root) {
    // RootHide's bootstrap paths are relative to jbroot. launchd is outside
    // vroot, so its executable must be passed as a physical kernel path.
    if (access("/var/jb", F_OK) == 0 || xpc_dictionary_get_bool(plist, "__Patched")) return;
    xpc_object_t args = xpc_dictionary_get_value(plist, "ProgramArguments");
    if (args && xpc_get_type(args) == XPC_TYPE_ARRAY && xpc_array_get_count(args) > 0) {
        const char *program = xpc_array_get_string(args, 0);
        char physical[PATH_MAX];
        if (vpPhysicalProgram(program, root, physical)) xpc_array_set_string(args, 0, physical);
    }
    const char *program = xpc_dictionary_get_string(plist, "Program");
    char physical[PATH_MAX];
    if (vpPhysicalProgram(program, root, physical)) xpc_dictionary_set_string(plist, "Program", physical);
}

static void vpAddPlist(xpc_object_t dictionary, const char *path, const char *root) {
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return;
    struct stat info;
    if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0 &&
        info.st_size < 1024 * 1024) {
        void *bytes = mmap(NULL, (size_t)info.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (bytes != MAP_FAILED) {
            VPPlistDecoder decode = (VPPlistDecoder)dlsym(RTLD_DEFAULT, "xpc_create_from_plist");
            if (decode) {
                xpc_object_t plist = decode(bytes, (size_t)info.st_size);
                if (plist && xpc_get_type(plist) == XPC_TYPE_DICTIONARY) {
                    vpPatchProgram(plist, root);
                    xpc_dictionary_set_value(dictionary, path, plist);
                }
                if (plist) xpc_release(plist);
            }
            munmap(bytes, (size_t)info.st_size);
        }
    }
    close(fd);
}

static void vpAddDaemons(xpc_object_t dictionary, const char *directory, const char *root) {
    DIR *stream = opendir(directory);
    if (!stream) return;
    struct dirent *entry;
    while ((entry = readdir(stream))) {
        size_t length = strlen(entry->d_name);
        if (length < 6 || strcmp(entry->d_name + length - 6, ".plist") != 0) continue;
        char path[PATH_MAX];
        int used = snprintf(path, sizeof(path), "%s/%s", directory, entry->d_name);
        if (used > 0 && (size_t)used < sizeof(path)) vpAddPlist(dictionary, path, root);
    }
    closedir(stream);
}

static xpc_object_t vpGetValue(xpc_object_t dictionary, const char *key) {
    VPGetValue original = vpOriginalGetValue();
    if (!original) return NULL;
    xpc_object_t value = original(dictionary, key);
    if (getpid() != 1 || !value || !key ||
        (strcmp(key, "Paths") != 0 && strcmp(key, "LaunchDaemons") != 0)) {
        return value;
    }
    char root[PATH_MAX];
    if (!vpFindJBRoot(root)) return value;
    char path[PATH_MAX];
    int used = snprintf(path, sizeof(path), "%s/Library/LaunchDaemons", root);
    if (used < 0 || (size_t)used >= sizeof(path)) return value;
    if (strcmp(key, "Paths") == 0 && xpc_get_type(value) == XPC_TYPE_ARRAY) {
        xpc_array_set_string(value, XPC_ARRAY_APPEND, path);
        used = snprintf(path, sizeof(path), "%s/basebin/LaunchDaemons", root);
        if (used > 0 && (size_t)used < sizeof(path) && access(path, F_OK) == 0) {
            xpc_array_set_string(value, XPC_ARRAY_APPEND, path);
        }
    } else if (strcmp(key, "LaunchDaemons") == 0 &&
               xpc_get_type(value) == XPC_TYPE_DICTIONARY) {
        vpAddDaemons(value, path, root);
        used = snprintf(path, sizeof(path), "%s/basebin/LaunchDaemons", root);
        if (used > 0 && (size_t)used < sizeof(path)) vpAddDaemons(value, path, root);
    }
    return value;
}

static int vpMemoryStatus(uint32_t command, int32_t pid, uint32_t flags,
                          void *buffer, size_t size) {
    if (getpid() == 1 && command == VPSetJetsamTaskLimit && (pid == 1 || pid == 0)) {
        return 0;
    }
    VPMemoryStatus original = vpOriginalMemoryStatus();
    return original ? original(command, pid, flags, buffer, size) : -1;
}

__attribute__((constructor))
static void vpLaunchHookInit(void) {
    if (getpid() != 1) return;
    VPMemoryStatus original = vpOriginalMemoryStatus();
    if (!original) return;
    // The firmware panic-guard patch does not remove a limit already on PID 1.
    original(VPSetJetsamTaskLimit, 1, (uint32_t)-1, NULL, 0);
    original(VPSetJetsamHighWaterMark, 1, (uint32_t)-1, NULL, 0);
}

// This image is loaded by launchd's LC_LOAD_WEAK_DYLIB. Child injection is
// deliberately deferred until SystemHook has its own process policy.
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *replacee; } vpInterpose[] = {
    {(const void *)vpGetValue, (const void *)xpc_dictionary_get_value},
    {(const void *)vpMemoryStatus, (const void *)memorystatus_control},
};
