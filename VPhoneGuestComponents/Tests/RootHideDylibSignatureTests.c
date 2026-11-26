#include "../Shared/RootHideDylibSignature.h"
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libkern/OSByteOrder.h>
#include <limits.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CS_MAGIC_SUPERBLOB 0xFADE0CC0u
#define CS_MAGIC_CODEDIRECTORY 0xFADE0C02u
#define CS_MAGIC_BLOBWRAPPER 0xFADE0B01u
#define CS_ADHOC 0x00000002u

static void putBE32(uint8_t *dst, uint32_t value) {
    uint32_t be = OSSwapHostToBigInt32(value);
    memcpy(dst, &be, sizeof(be));
}

static uint32_t getBE32(const uint8_t *src) {
    uint32_t be = 0;
    memcpy(&be, src, sizeof(be));
    return OSSwapBigToHostInt32(be);
}

static void makeDir(const char *path) { assert(mkdir(path, 0700) == 0); }

static ino_t fileInode(const char *path) {
    struct stat info;
    assert(stat(path, &info) == 0);
    return info.st_ino;
}

static mode_t fileMode(const char *path) {
    struct stat info;
    assert(stat(path, &info) == 0);
    return info.st_mode & 07777;
}

// Build one 64-bit ARM64 Mach-O slice into a malloc'd buffer.
// `hasCodeSig`: include LC_CODE_SIGNATURE.
// `cdFlags`: CodeDirectory.flags (0 for ldid, 2 for CS_ADHOC).
// `cmsPayloadLen`: <0 = omit slot 0x10000, 0 = empty 8-byte wrapper, >0 = real CMS payload.
static uint8_t *buildSlice(uint32_t cpuSubtype, uint32_t fileType, const char *rpath,
                           const char *dep, int hasCodeSig, uint32_t cdFlags,
                           int cmsPayloadLen, size_t *outSize) {
    uint8_t cmds[1024] = {0};
    uint32_t cmdSize = 0;
    uint32_t cmdCount = 0;

    if (rpath) {
        struct rpath_command *cmd = (struct rpath_command *)(cmds + cmdSize);
        uint32_t len = (uint32_t)((sizeof(*cmd) + strlen(rpath) + 8) & ~7ul);
        cmd->cmd = LC_RPATH;
        cmd->cmdsize = len;
        cmd->path.offset = sizeof(*cmd);
        strcpy((char *)cmd + sizeof(*cmd), rpath);
        cmdSize += len;
        cmdCount++;
    }
    if (dep) {
        struct dylib_command *cmd = (struct dylib_command *)(cmds + cmdSize);
        uint32_t len = (uint32_t)((sizeof(*cmd) + strlen(dep) + 8) & ~7ul);
        cmd->cmd = LC_LOAD_DYLIB;
        cmd->cmdsize = len;
        cmd->dylib.name.offset = sizeof(*cmd);
        strcpy((char *)cmd + sizeof(*cmd), dep);
        cmdSize += len;
        cmdCount++;
    }

    uint32_t codeLimit = 0x1000;
    uint8_t superBlob[512] = {0};
    uint32_t sbSize = 0;

    if (hasCodeSig) {
        uint32_t blobCount = (cmsPayloadLen >= 0) ? 2u : 1u;
        uint32_t indexEnd = 12u + blobCount * 8u;
        uint32_t cdLen = 64u;
        uint32_t cdOff = indexEnd;
        uint32_t cmsOff = cdOff + cdLen;
        uint32_t cmsLen = (cmsPayloadLen >= 0) ? (8u + (uint32_t)cmsPayloadLen) : 0u;
        sbSize = cmsOff + cmsLen;

        putBE32(superBlob + 0, CS_MAGIC_SUPERBLOB);
        putBE32(superBlob + 4, sbSize);
        putBE32(superBlob + 8, blobCount);

        putBE32(superBlob + 12, 0u);
        putBE32(superBlob + 16, cdOff);
        if (cmsPayloadLen >= 0) {
            putBE32(superBlob + 20, 0x10000u);
            putBE32(superBlob + 24, cmsOff);
        }

        uint8_t *cd = superBlob + cdOff;
        putBE32(cd + 0, CS_MAGIC_CODEDIRECTORY);
        putBE32(cd + 4, cdLen);
        putBE32(cd + 8, 0x20400u);
        putBE32(cd + 12, cdFlags);
        putBE32(cd + 16, 44u);
        putBE32(cd + 20, 44u);
        putBE32(cd + 24, 0u);
        putBE32(cd + 28, 0u);
        putBE32(cd + 32, codeLimit);
        cd[36] = 32;
        cd[37] = 2;
        cd[38] = 0;
        cd[39] = 12;

        if (cmsPayloadLen >= 0) {
            uint8_t *cms = superBlob + cmsOff;
            putBE32(cms + 0, CS_MAGIC_BLOBWRAPPER);
            putBE32(cms + 4, cmsLen);
            if (cmsPayloadLen > 0)
                memset(cms + 8, 0x30, (size_t)cmsPayloadLen);
        }

        struct linkedit_data_command *cs = (struct linkedit_data_command *)(cmds + cmdSize);
        cs->cmd = LC_CODE_SIGNATURE;
        cs->cmdsize = sizeof(*cs);
        cs->dataoff = codeLimit;
        cs->datasize = sbSize;
        cmdSize += sizeof(*cs);
        cmdCount++;
    }

    size_t total = (size_t)codeLimit + (size_t)sbSize;
    uint8_t *buf = calloc(1, total);
    assert(buf != NULL);

    struct mach_header_64 header = {
        .magic = MH_MAGIC_64,
        .cputype = CPU_TYPE_ARM64,
        .cpusubtype = (cpu_subtype_t)cpuSubtype,
        .filetype = fileType,
        .ncmds = cmdCount,
        .sizeofcmds = cmdSize,
    };
    memcpy(buf, &header, sizeof(header));
    memcpy(buf + sizeof(header), cmds, cmdSize);
    if (hasCodeSig)
        memcpy(buf + codeLimit, superBlob, sbSize);
    *outSize = total;
    return buf;
}

static void writeFile(const char *path, const uint8_t *data, size_t size, mode_t mode) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
    assert(fd >= 0);
    assert(write(fd, data, size) == (ssize_t)size);
    assert(fchmod(fd, mode) == 0);
    assert(close(fd) == 0);
}

static void writeThin(const char *path, uint32_t fileType, const char *rpath, const char *dep,
                      int hasCodeSig, uint32_t cdFlags, int cmsPayloadLen, mode_t mode) {
    size_t size = 0;
    uint8_t *slice = buildSlice(CPU_SUBTYPE_ARM64E | 0x80000000u, fileType, rpath, dep,
                                hasCodeSig, cdFlags, cmsPayloadLen, &size);
    writeFile(path, slice, size, mode);
    free(slice);
}

static void writeFatArm64AndArm64e(const char *path, uint32_t fileType, const char *dep,
                                   uint32_t flags0, uint32_t flags1, mode_t mode) {
    size_t size0 = 0, size1 = 0;
    uint8_t *slice0 = buildSlice(CPU_SUBTYPE_ARM64_ALL, fileType, NULL, dep, 1, flags0, -1, &size0);
    uint8_t *slice1 = buildSlice(CPU_SUBTYPE_ARM64E | 0x80000000u, fileType, NULL, dep, 1, flags1, -1, &size1);

    uint32_t off0 = 0x4000;
    uint32_t off1 = (uint32_t)((off0 + size0 + 0x3fff) & ~0x3fffu);
    size_t total = (size_t)off1 + size1;
    uint8_t *buf = calloc(1, total);
    assert(buf != NULL);

    putBE32(buf + 0, FAT_MAGIC);
    putBE32(buf + 4, 2u);

    putBE32(buf + 8, (uint32_t)CPU_TYPE_ARM64);
    putBE32(buf + 12, CPU_SUBTYPE_ARM64_ALL);
    putBE32(buf + 16, off0);
    putBE32(buf + 20, (uint32_t)size0);
    putBE32(buf + 24, 14u);

    putBE32(buf + 28, (uint32_t)CPU_TYPE_ARM64);
    putBE32(buf + 32, CPU_SUBTYPE_ARM64E | 0x80000000u);
    putBE32(buf + 36, off1);
    putBE32(buf + 40, (uint32_t)size1);
    putBE32(buf + 44, 14u);

    memcpy(buf + off0, slice0, size0);
    memcpy(buf + off1, slice1, size1);
    writeFile(path, buf, total, mode);
    free(slice0);
    free(slice1);
    free(buf);
}

static uint32_t readSliceCDFlags(const char *path, size_t sliceIndex) {
    int fd = open(path, O_RDONLY);
    assert(fd >= 0);
    struct stat info;
    assert(fstat(fd, &info) == 0);
    uint8_t *buf = malloc((size_t)info.st_size);
    assert(buf != NULL);
    assert(read(fd, buf, (size_t)info.st_size) == info.st_size);
    close(fd);

    size_t sliceOff = 0;
    uint32_t magic = 0;
    memcpy(&magic, buf, 4);
    if (magic == FAT_CIGAM) {
        sliceOff = getBE32(buf + 8 + sliceIndex * 20 + 8);
    } else {
        assert(sliceIndex == 0);
    }

    struct mach_header_64 header;
    memcpy(&header, buf + sliceOff, sizeof(header));
    assert(header.magic == MH_MAGIC_64);
    uint32_t pos = sizeof(header);
    uint32_t csOff = 0;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        struct load_command lc;
        memcpy(&lc, buf + sliceOff + pos, sizeof(lc));
        if (lc.cmd == LC_CODE_SIGNATURE) {
            struct linkedit_data_command cs;
            memcpy(&cs, buf + sliceOff + pos, sizeof(cs));
            csOff = cs.dataoff;
            break;
        }
        pos += lc.cmdsize;
    }
    assert(csOff != 0);
    uint32_t cdOff = getBE32(buf + sliceOff + csOff + 16);
    uint32_t flags = getBE32(buf + sliceOff + csOff + cdOff + 12);
    free(buf);
    return flags;
}

static int countTempFiles(const char *dirPath) {
    DIR *dir = opendir(dirPath);
    assert(dir != NULL);
    int found = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strstr(entry->d_name, ".vphone-adhoc."))
            found++;
    }
    closedir(dir);
    return found;
}

static void removeTree(const char *path) {
    struct stat info;
    if (lstat(path, &info) != 0)
        return;
    if (S_ISDIR(info.st_mode)) {
        chmod(path, 0700);
        DIR *dir = opendir(path);
        if (dir) {
            struct dirent *entry;
            char child[PATH_MAX];
            while ((entry = readdir(dir)) != NULL) {
                if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
                    continue;
                snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
                removeTree(child);
            }
            closedir(dir);
        }
        rmdir(path);
    } else {
        unlink(path);
    }
}

int main(void) {
    char scratch[] = "/tmp/vphone-dylib-sig.XXXXXX";
    assert(mkdtemp(scratch));

    char root[PATH_MAX];
    snprintf(root, sizeof(root), "%s/.jbroot-000114514191980C", scratch);
    makeDir(root);

    const char *dirs[] = {
        "usr", "usr/lib", "usr/lib/ellekit", "usr/lib/TweakInject",
        "usr/lib/deep", "usr/bin", "Library", "Library/dpkg"
    };
    char path[PATH_MAX];
    for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
        snprintf(path, sizeof(path), "%s/%s", root, dirs[i]);
        makeDir(path);
    }

    // 1. FAT (arm64 + arm64e) ldid-signed libinjector.dylib behind TweakLoader.dylib symlink,
    //    depending on @loader_path/.jbroot/usr/lib/libdep.dylib (thin ldid) which depends on @rpath/libdeep.dylib.
    char injector[PATH_MAX], loader[PATH_MAX], dep[PATH_MAX], deep[PATH_MAX];
    snprintf(injector, sizeof(injector), "%s/usr/lib/ellekit/libinjector.dylib", root);
    snprintf(loader, sizeof(loader), "%s/usr/lib/TweakLoader.dylib", root);
    snprintf(dep, sizeof(dep), "%s/usr/lib/libdep.dylib", root);
    snprintf(deep, sizeof(deep), "%s/usr/lib/deep/libdeep.dylib", root);

    writeFatArm64AndArm64e(injector, MH_DYLIB, "@loader_path/.jbroot/usr/lib/libdep.dylib", 0, 0, 0644);
    assert(symlink("ellekit/libinjector.dylib", loader) == 0);
    writeThin(dep, MH_DYLIB, "@loader_path/.jbroot/usr/lib/deep", "@rpath/libdeep.dylib", 1, 0, -1, 0755);
    writeThin(deep, MH_DYLIB, NULL, NULL, 1, 0, 0, 0644); // empty 8-byte CMS wrapper + flags=0

    ino_t oldInjectorIno = fileInode(injector);
    ino_t oldDepIno = fileInode(dep);
    ino_t oldDeepIno = fileInode(deep);

    char failed[PATH_MAX];
    assert(vpPrepareRootHideDylib(loader, root, failed, sizeof(failed)) == 0);
    assert(failed[0] == '\0');
    assert(readSliceCDFlags(injector, 0) == CS_ADHOC);
    assert(readSliceCDFlags(injector, 1) == CS_ADHOC);
    assert(readSliceCDFlags(dep, 0) == CS_ADHOC);
    assert(readSliceCDFlags(deep, 0) == CS_ADHOC);
    // Fresh inodes (atomic rename) and preserved modes, no leftover temps.
    assert(fileInode(injector) != oldInjectorIno);
    assert(fileInode(dep) != oldDepIno);
    assert(fileInode(deep) != oldDeepIno);
    assert(fileMode(injector) == 0644);
    assert(fileMode(dep) == 0755);
    assert(fileMode(deep) == 0644);
    snprintf(path, sizeof(path), "%s/usr/lib/ellekit", root);
    assert(countTempFiles(path) == 0);

    // 2. Second pass on already-CS_ADHOC dylibs is a no-op (same inodes).
    ino_t fixedInjectorIno = fileInode(injector);
    assert(vpPrepareRootHideDylib(loader, root, failed, sizeof(failed)) == 0);
    assert(fileInode(injector) == fixedInjectorIno);

    // 3. Real CMS-signed dylib (flags == 0, non-empty CMS blob) is left untouched.
    char cmsDylib[PATH_MAX];
    snprintf(cmsDylib, sizeof(cmsDylib), "%s/usr/lib/libcms.dylib", root);
    writeThin(cmsDylib, MH_DYLIB, NULL, NULL, 1, 0, 64, 0644);
    ino_t cmsIno = fileInode(cmsDylib);
    assert(vpPrepareRootHideDylib(cmsDylib, root, failed, sizeof(failed)) == 0);
    assert(fileInode(cmsDylib) == cmsIno);
    assert(readSliceCDFlags(cmsDylib, 0) == 0);

    // 4. MH_EXECUTE with flags == 0 is left untouched.
    char exe[PATH_MAX];
    snprintf(exe, sizeof(exe), "%s/usr/bin/tool", root);
    writeThin(exe, MH_EXECUTE, NULL, NULL, 1, 0, -1, 0755);
    ino_t exeIno = fileInode(exe);
    assert(vpPrepareRootHideDylib(exe, root, failed, sizeof(failed)) == 0);
    assert(fileInode(exe) == exeIno);
    assert(readSliceCDFlags(exe, 0) == 0);

    // 5. Completely unsigned MH_DYLIB is refused with EFTYPE and reports failedPath.
    char unsignedDylib[PATH_MAX];
    snprintf(unsignedDylib, sizeof(unsignedDylib), "%s/usr/lib/libunsigned.dylib", root);
    writeThin(unsignedDylib, MH_DYLIB, NULL, NULL, 0, 0, -1, 0644);
    assert(vpPrepareRootHideDylib(unsignedDylib, root, failed, sizeof(failed)) == EFTYPE);
    assert(strstr(failed, "libunsigned.dylib") != NULL);

    // 6. Read-only directory holding a flags=0 dylib cannot be rewritten -> refused with EACCES.
    char roDir[PATH_MAX], roDylib[PATH_MAX];
    snprintf(roDir, sizeof(roDir), "%s/usr/lib/readonly", root);
    makeDir(roDir);
    snprintf(roDylib, sizeof(roDylib), "%s/libblocked.dylib", roDir);
    writeThin(roDylib, MH_DYLIB, NULL, NULL, 1, 0, -1, 0644);
    if (geteuid() != 0) {
        assert(chmod(roDir, 0500) == 0);
        int status = vpPrepareRootHideDylib(roDylib, root, failed, sizeof(failed));
        assert(status == EACCES || status == EPERM);
        assert(strstr(failed, "libblocked.dylib") != NULL);
        assert(readSliceCDFlags(roDylib, 0) == 0);
        assert(chmod(roDir, 0700) == 0);
    }

    // 7. Non-RootHide root is ignored.
    char otherRoot[PATH_MAX], otherDylib[PATH_MAX];
    snprintf(otherRoot, sizeof(otherRoot), "%s/var_jb", scratch);
    makeDir(otherRoot);
    snprintf(otherDylib, sizeof(otherDylib), "%s/libother.dylib", otherRoot);
    writeThin(otherDylib, MH_DYLIB, NULL, NULL, 1, 0, -1, 0644);
    assert(vpPrepareRootHideDylib(otherDylib, otherRoot, failed, sizeof(failed)) == 0);
    assert(readSliceCDFlags(otherDylib, 0) == 0);

    // 8. vpEnsureRootHideTweakSignatures repairs ellekit + TweakInject + transitive deps (like libprefs.dylib),
    //    caches when unchanged, and re-runs when a new tweak arrives.
    char ellekit[PATH_MAX], safety[PATH_MAX], prefLoader[PATH_MAX], libprefs[PATH_MAX];
    snprintf(ellekit, sizeof(ellekit), "%s/usr/lib/libellekit.dylib", root);
    snprintf(safety, sizeof(safety), "%s/usr/lib/ellekit/MobileSafety.dylib", root);
    snprintf(prefLoader, sizeof(prefLoader), "%s/usr/lib/TweakInject/PreferenceLoader.dylib", root);
    snprintf(libprefs, sizeof(libprefs), "%s/usr/lib/libprefs.dylib", root);

    writeFatArm64AndArm64e(ellekit, MH_DYLIB, NULL, 0, 0, 0644);
    writeThin(safety, MH_DYLIB, NULL, NULL, 1, 0, -1, 0644);
    writeThin(prefLoader, MH_DYLIB, NULL, "@loader_path/.jbroot/usr/lib/libprefs.dylib", 1, 0, -1, 0755);
    writeThin(libprefs, MH_DYLIB, NULL, NULL, 1, 0, -1, 0755);

    vpEnsureRootHideTweakSignatures(root);
    assert(readSliceCDFlags(ellekit, 0) == CS_ADHOC);
    assert(readSliceCDFlags(ellekit, 1) == CS_ADHOC);
    assert(readSliceCDFlags(safety, 0) == CS_ADHOC);
    assert(readSliceCDFlags(prefLoader, 0) == CS_ADHOC);
    assert(readSliceCDFlags(libprefs, 0) == CS_ADHOC);

    // Cache hit leaves inodes untouched.
    ino_t prefIno = fileInode(prefLoader);
    vpEnsureRootHideTweakSignatures(root);
    assert(fileInode(prefLoader) == prefIno);

    // Adding a new tweak invalidates TweakInject directory mtime and repairs it.
    char newTweak[PATH_MAX];
    snprintf(newTweak, sizeof(newTweak), "%s/usr/lib/TweakInject/SecondTweak.dylib", root);
    writeThin(newTweak, MH_DYLIB, NULL, NULL, 1, 0, -1, 0644);
    vpEnsureRootHideTweakSignatures(root);
    assert(readSliceCDFlags(newTweak, 0) == CS_ADHOC);

    removeTree(scratch);
    puts("RootHide dylib signature tests passed");
    return 0;
}
