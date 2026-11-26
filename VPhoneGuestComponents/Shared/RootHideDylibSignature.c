#include "RootHideDylibSignature.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libkern/OSByteOrder.h>
#include <limits.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define VP_SIG_MAX_IMAGES 256
#define VP_SIG_MAX_RPATHS 16
#define VP_SIG_MAX_SLICES 16
#define VP_SIG_MAX_PATCHES 32
#define VP_SIG_MAX_COMMANDS (512u * 1024u)
#define VP_SIG_MAX_SUPERBLOB (2u * 1024u * 1024u)

#define VP_CS_MAGIC_EMBEDDED_SIGNATURE 0xFADE0CC0u
#define VP_CS_MAGIC_CODEDIRECTORY 0xFADE0C02u
#define VP_CS_MAGIC_BLOBWRAPPER 0xFADE0B01u

#define VP_CS_SLOT_CODEDIRECTORY 0u
#define VP_CS_SLOT_ALTERNATE_FIRST 0x1000u
#define VP_CS_SLOT_ALTERNATE_LAST 0x1004u
#define VP_CS_SLOT_CMS_SIGNATURE 0x10000u

#define VP_CS_ADHOC 0x00000002u

static const char vpLoaderRootPrefix[] = "@loader_path/.jbroot/";
static const char vpLoaderPrefix[] = "@loader_path/";
static const char vpRPathPrefix[] = "@rpath/";

typedef struct {
    off_t offset;
    uint64_t size;
} VPSigSlice;

typedef struct {
    off_t fileOffset;
    uint32_t newFlagsBE;
} VPFlagsPatch;

typedef struct {
    dev_t dev;
    ino_t ino;
} VPFileID;

typedef struct {
    char root[PATH_MAX];
    VPFileID visited[VP_SIG_MAX_IMAGES];
    size_t visitedCount;
    char rpaths[VP_SIG_MAX_RPATHS][PATH_MAX];
    size_t rpathCount;
    int status;
    char failedPath[PATH_MAX];
} VPSigWalk;

typedef struct {
    int present;
    dev_t dev;
    ino_t ino;
    time_t mtimeSec;
    long mtimeNsec;
} VPPathStamp;

typedef struct {
    char root[PATH_MAX];
    VPPathStamp stamps[5];
} VPTweakSnapshot;

static pthread_mutex_t vpTweakSnapshotLock = PTHREAD_MUTEX_INITIALIZER;
static int vpHasTweakSnapshot;
static VPTweakSnapshot vpLastTweakSnapshot;
static unsigned int vpTempSequence;

static uint32_t vpReadBE32(const uint8_t *bytes) {
    uint32_t value = 0;
    memcpy(&value, bytes, sizeof(value));
    return OSSwapBigToHostInt32(value);
}

static int vpWithinRoot(const char *path, const char *directory) {
    size_t length = strlen(directory);
    return strncmp(path, directory, length) == 0 &&
           (path[length] == '/' || path[length] == '\0');
}

static void vpRecordFailure(VPSigWalk *walk, int status, const char *path) {
    if (!status || walk->status)
        return;
    walk->status = status;
    if (path)
        snprintf(walk->failedPath, sizeof(walk->failedPath), "%s", path);
}

static int vpPReadExact(int fd, void *buffer, size_t count, off_t offset) {
    uint8_t *cursor = (uint8_t *)buffer;
    size_t remaining = count;
    while (remaining > 0) {
        ssize_t got = pread(fd, cursor, remaining, offset);
        if (got < 0) {
            if (errno == EINTR)
                continue;
            return errno ? errno : EIO;
        }
        if (got == 0)
            return EIO;
        cursor += (size_t)got;
        offset += got;
        remaining -= (size_t)got;
    }
    return 0;
}

static int vpWriteAll(int fd, const uint8_t *buffer, size_t count) {
    size_t remaining = count;
    while (remaining > 0) {
        ssize_t written = write(fd, buffer, remaining);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            return errno ? errno : EIO;
        }
        buffer += (size_t)written;
        remaining -= (size_t)written;
    }
    return 0;
}

static int vpPWriteExact(int fd, const void *buffer, size_t count, off_t offset) {
    const uint8_t *cursor = (const uint8_t *)buffer;
    size_t remaining = count;
    while (remaining > 0) {
        ssize_t written = pwrite(fd, cursor, remaining, offset);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            return errno ? errno : EIO;
        }
        cursor += (size_t)written;
        offset += written;
        remaining -= (size_t)written;
    }
    return 0;
}

static const char *vpCommandString(const struct load_command *command, uint32_t offset) {
    if (offset < sizeof(*command) || offset >= command->cmdsize)
        return NULL;
    const char *string = (const char *)command + offset;
    size_t room = command->cmdsize - offset;
    return strnlen(string, room) < room ? string : NULL;
}

static int vpCollectArm64Slices(int fd, uint64_t fileSize, VPSigSlice slices[VP_SIG_MAX_SLICES],
                                size_t *sliceCount) {
    *sliceCount = 0;
    if (fileSize < sizeof(uint32_t))
        return 0;
    uint32_t magic = 0;
    int readStatus = vpPReadExact(fd, &magic, sizeof(magic), 0);
    if (readStatus)
        return readStatus;
    if (magic == MH_MAGIC_64) {
        if (fileSize < sizeof(struct mach_header_64))
            return 0;
        struct mach_header_64 header;
        readStatus = vpPReadExact(fd, &header, sizeof(header), 0);
        if (readStatus)
            return readStatus;
        if (header.cputype == CPU_TYPE_ARM64) {
            slices[0].offset = 0;
            slices[0].size = fileSize;
            *sliceCount = 1;
        }
        return 0;
    }
    if (magic != FAT_CIGAM)
        return 0;

    struct fat_header fat;
    if (fileSize < sizeof(fat) || vpPReadExact(fd, &fat, sizeof(fat), 0) != 0)
        return 0;
    uint32_t count = OSSwapBigToHostInt32(fat.nfat_arch);
    if (count == 0 || count > VP_SIG_MAX_SLICES)
        return 0;
    if (sizeof(fat) + (uint64_t)count * sizeof(struct fat_arch) > fileSize)
        return EFTYPE;

    for (uint32_t index = 0; index < count; index++) {
        struct fat_arch arch;
        off_t entryOffset = (off_t)sizeof(fat) + (off_t)index * (off_t)sizeof(arch);
        readStatus = vpPReadExact(fd, &arch, sizeof(arch), entryOffset);
        if (readStatus)
            return readStatus;
        cpu_type_t cpuType = (cpu_type_t)OSSwapBigToHostInt32((uint32_t)arch.cputype);
        if (cpuType != CPU_TYPE_ARM64)
            continue;
        uint32_t offset = OSSwapBigToHostInt32(arch.offset);
        uint32_t size = OSSwapBigToHostInt32(arch.size);
        if ((uint64_t)offset > fileSize || (uint64_t)size > fileSize - (uint64_t)offset)
            return EFTYPE;
        slices[*sliceCount].offset = (off_t)offset;
        slices[*sliceCount].size = (uint64_t)size;
        (*sliceCount)++;
    }
    return 0;
}

// Inspect one slice's embedded SuperBlob. A real CMS signature (slot 0x10000
// with payload beyond the 8-byte wrapper header) is left alone. Otherwise
// every CodeDirectory must carry CS_ADHOC; any that do not are recorded in
// `patches` if `codeLimit <= dataoff` (so flipping flags leaves every code
// page hash intact).
static int vpInspectSliceSignature(int fd, const VPSigSlice *slice, uint32_t dataoff, uint32_t datasize,
                                   VPFlagsPatch *patches, size_t *patchCount, size_t maxPatches) {
    if (datasize < 12 || datasize > VP_SIG_MAX_SUPERBLOB)
        return EFTYPE;
    if ((uint64_t)dataoff > slice->size || (uint64_t)datasize > slice->size - (uint64_t)dataoff)
        return EFTYPE;

    uint8_t *blob = malloc(datasize);
    if (!blob)
        return ENOMEM;
    int status = vpPReadExact(fd, blob, datasize, slice->offset + (off_t)dataoff);
    if (status)
        goto done;

    uint32_t magic = vpReadBE32(blob);
    uint32_t length = vpReadBE32(blob + 4);
    uint32_t count = vpReadBE32(blob + 8);
    if (magic != VP_CS_MAGIC_EMBEDDED_SIGNATURE || length < 12 || length > datasize ||
        count > (length - 12u) / 8u) {
        status = EFTYPE;
        goto done;
    }

    // Pass 1: preserve slices that carry a real CMS signature payload.
    for (uint32_t index = 0; index < count; index++) {
        uint32_t slot = vpReadBE32(blob + 12u + index * 8u);
        uint32_t blobOffset = vpReadBE32(blob + 16u + index * 8u);
        if (slot != VP_CS_SLOT_CMS_SIGNATURE)
            continue;
        if (blobOffset < 12u + count * 8u || blobOffset > length - 8u) {
            status = EFTYPE;
            goto done;
        }
        uint32_t blobMagic = vpReadBE32(blob + blobOffset);
        uint32_t blobLength = vpReadBE32(blob + blobOffset + 4u);
        if (blobMagic != VP_CS_MAGIC_BLOBWRAPPER || blobLength < 8u || blobLength > length - blobOffset) {
            status = EFTYPE;
            goto done;
        }
        if (blobLength > 8u)
            goto done;
    }

    // Pass 2: verify every CodeDirectory and collect any missing CS_ADHOC.
    size_t codeDirectories = 0;
    for (uint32_t index = 0; index < count; index++) {
        uint32_t slot = vpReadBE32(blob + 12u + index * 8u);
        uint32_t blobOffset = vpReadBE32(blob + 16u + index * 8u);
        int isCodeDirectory = (slot == VP_CS_SLOT_CODEDIRECTORY) ||
                              (slot >= VP_CS_SLOT_ALTERNATE_FIRST && slot <= VP_CS_SLOT_ALTERNATE_LAST);
        if (!isCodeDirectory)
            continue;
        if (length < 44u || blobOffset < 12u + count * 8u || blobOffset > length - 44u) {
            status = EFTYPE;
            goto done;
        }
        uint32_t blobMagic = vpReadBE32(blob + blobOffset);
        uint32_t blobLength = vpReadBE32(blob + blobOffset + 4u);
        if (blobMagic != VP_CS_MAGIC_CODEDIRECTORY || blobLength < 44u || blobLength > length - blobOffset) {
            status = EFTYPE;
            goto done;
        }
        uint32_t codeLimit = vpReadBE32(blob + blobOffset + 32u);
        if (codeLimit > dataoff) {
            status = EFTYPE;
            goto done;
        }
        codeDirectories++;
        uint32_t flags = vpReadBE32(blob + blobOffset + 12u);
        if ((flags & VP_CS_ADHOC) == 0) {
            if (*patchCount >= maxPatches) {
                status = EFTYPE;
                goto done;
            }
            patches[*patchCount].fileOffset = slice->offset + (off_t)dataoff + (off_t)blobOffset + 12;
            patches[*patchCount].newFlagsBE = OSSwapHostToBigInt32(flags | VP_CS_ADHOC);
            (*patchCount)++;
        }
    }
    if (codeDirectories == 0)
        status = EFTYPE;

done:
    free(blob);
    return status;
}

// Copies from the already-inspected `srcFd` so the written bytes and patch
// offsets always refer to the exact same inode. Returns EAGAIN if another
// writer (for example vphoned or dpkg) already replaced `canonicalPath`.
static int vpRewriteWithAdHocFlags(int srcFd, const char *canonicalPath, const struct stat *info,
                                   const VPFlagsPatch *patches, size_t patchCount) {
    const char *slash = strrchr(canonicalPath, '/');
    if (!slash || slash == canonicalPath || !slash[1])
        return EINVAL;
    size_t dirLength = (size_t)(slash - canonicalPath);
    const char *leaf = slash + 1;

    char tempPath[PATH_MAX];
    unsigned int sequence = __atomic_fetch_add(&vpTempSequence, 1u, __ATOMIC_RELAXED);
    int used = snprintf(tempPath, sizeof(tempPath), "%.*s/.%s.vphone-adhoc.%d.%u",
                        (int)dirLength, canonicalPath, leaf, getpid(), sequence);
    if (used <= 0 || (size_t)used >= sizeof(tempPath))
        return ENAMETOOLONG;

    int dstFd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (dstFd < 0)
        return errno;

    int status = 0;
    uint8_t *buffer = malloc(65536);
    if (!buffer) {
        status = ENOMEM;
        goto cleanup;
    }
    off_t readOffset = 0;
    while (readOffset < info->st_size) {
        size_t chunk = (size_t)(info->st_size - readOffset);
        if (chunk > 65536)
            chunk = 65536;
        ssize_t got = pread(srcFd, buffer, chunk, readOffset);
        if (got < 0) {
            if (errno == EINTR)
                continue;
            status = errno ? errno : EIO;
            goto cleanup;
        }
        if (got == 0) {
            status = EIO;
            goto cleanup;
        }
        status = vpWriteAll(dstFd, buffer, (size_t)got);
        if (status)
            goto cleanup;
        readOffset += got;
    }
    for (size_t index = 0; index < patchCount; index++) {
        status = vpPWriteExact(dstFd, &patches[index].newFlagsBE, sizeof(patches[index].newFlagsBE),
                               patches[index].fileOffset);
        if (status)
            goto cleanup;
    }
    if (fchmod(dstFd, info->st_mode & 07777) != 0) {
        status = errno;
        goto cleanup;
    }
    // Preserve ownership when running as root; ignore EPERM otherwise.
    (void)fchown(dstFd, info->st_uid, info->st_gid);

    free(buffer);
    buffer = NULL;
    if (close(dstFd) != 0) {
        status = errno;
        dstFd = -1;
        unlink(tempPath);
        return status;
    }
    dstFd = -1;

    struct stat current;
    if (lstat(canonicalPath, &current) != 0 ||
        current.st_dev != info->st_dev || current.st_ino != info->st_ino) {
        unlink(tempPath);
        return EAGAIN;
    }
    if (rename(tempPath, canonicalPath) != 0) {
        status = errno;
        unlink(tempPath);
        return status;
    }
    return 0;

cleanup:
    free(buffer);
    if (dstFd >= 0)
        close(dstFd);
    unlink(tempPath);
    return status;
}

static int vpResolveDependencyPath(const VPSigWalk *walk, const char *imageDir, const char *name,
                                   char candidate[PATH_MAX]) {
    if (strncmp(name, vpLoaderRootPrefix, sizeof(vpLoaderRootPrefix) - 1) == 0) {
        const char *relative = name + sizeof(vpLoaderRootPrefix) - 2;
        int used = snprintf(candidate, PATH_MAX, "%s%s", walk->root, relative);
        return used > 0 && used < PATH_MAX;
    }
    if (strncmp(name, vpLoaderPrefix, sizeof(vpLoaderPrefix) - 1) == 0) {
        const char *relative = name + sizeof(vpLoaderPrefix) - 1;
        int used = snprintf(candidate, PATH_MAX, "%s/%s", imageDir, relative);
        return used > 0 && used < PATH_MAX;
    }
    if (name[0] == '/') {
        int used = snprintf(candidate, PATH_MAX, "%s", name);
        return used > 0 && used < PATH_MAX;
    }
    return 0;
}

static void vpAddRPath(VPSigWalk *walk, const char *imageDir, const char *name) {
    char path[PATH_MAX];
    char canonical[PATH_MAX];
    if (!vpResolveDependencyPath(walk, imageDir, name, path) || !realpath(path, canonical) ||
        !vpWithinRoot(canonical, walk->root))
        return;
    for (size_t index = 0; index < walk->rpathCount; index++) {
        if (strcmp(walk->rpaths[index], canonical) == 0)
            return;
    }
    if (walk->rpathCount < VP_SIG_MAX_RPATHS)
        strcpy(walk->rpaths[walk->rpathCount++], canonical);
}

static void vpVisitImage(VPSigWalk *walk, const char *canonicalImage);

static int vpVisitCandidate(VPSigWalk *walk, const char *candidate) {
    char canonical[PATH_MAX];
    struct stat info;
    if (!realpath(candidate, canonical) || stat(canonical, &info) != 0 || !S_ISREG(info.st_mode))
        return 0;
    if (!vpWithinRoot(canonical, walk->root))
        return 1;
    vpVisitImage(walk, canonical);
    return 1;
}

static void vpWalkSliceDependencies(VPSigWalk *walk, const char *imageDir, const uint8_t *commands,
                                    uint32_t count, uint32_t size) {
    for (int pass = 0; pass < 2; pass++) {
        uint32_t offset = 0;
        for (uint32_t index = 0; index < count && offset + sizeof(struct load_command) <= size; index++) {
            const struct load_command *command = (const struct load_command *)(commands + offset);
            if (command->cmdsize < sizeof(*command) || (command->cmdsize & 3u) != 0 ||
                command->cmdsize > size - offset)
                break;
            offset += command->cmdsize;
            if (pass == 0) {
                if (command->cmd == LC_RPATH && command->cmdsize >= sizeof(struct rpath_command)) {
                    const char *name = vpCommandString(command, ((const struct rpath_command *)command)->path.offset);
                    if (name)
                        vpAddRPath(walk, imageDir, name);
                }
                continue;
            }
            if (command->cmd != LC_LOAD_DYLIB && command->cmd != LC_LOAD_WEAK_DYLIB &&
                command->cmd != LC_REEXPORT_DYLIB && command->cmd != LC_LAZY_LOAD_DYLIB &&
                command->cmd != LC_LOAD_UPWARD_DYLIB)
                continue;
            if (command->cmdsize < sizeof(struct dylib_command))
                continue;
            const char *name = vpCommandString(command, ((const struct dylib_command *)command)->dylib.name.offset);
            if (!name)
                continue;
            char candidate[PATH_MAX];
            if (strncmp(name, vpRPathPrefix, sizeof(vpRPathPrefix) - 1) == 0) {
                const char *leafName = name + sizeof(vpRPathPrefix) - 1;
                for (size_t rpath = 0; rpath < walk->rpathCount; rpath++) {
                    int used = snprintf(candidate, sizeof(candidate), "%s/%s", walk->rpaths[rpath], leafName);
                    if (used > 0 && (size_t)used < sizeof(candidate) && vpVisitCandidate(walk, candidate))
                        break;
                }
            } else if (vpResolveDependencyPath(walk, imageDir, name, candidate)) {
                vpVisitCandidate(walk, candidate);
            }
        }
    }
}

static int vpHasVisited(const VPSigWalk *walk, dev_t dev, ino_t ino) {
    for (size_t index = 0; index < walk->visitedCount; index++) {
        if (walk->visited[index].dev == dev && walk->visited[index].ino == ino)
            return 1;
    }
    return 0;
}

static void vpRecordVisited(VPSigWalk *walk, dev_t dev, ino_t ino) {
    if (vpHasVisited(walk, dev, ino) || walk->visitedCount >= VP_SIG_MAX_IMAGES)
        return;
    walk->visited[walk->visitedCount].dev = dev;
    walk->visited[walk->visitedCount].ino = ino;
    walk->visitedCount++;
}

static void vpVisitImage(VPSigWalk *walk, const char *canonicalImage) {
    char imageDir[PATH_MAX];
    strcpy(imageDir, canonicalImage);
    char *leaf = strrchr(imageDir, '/');
    if (!leaf || leaf == imageDir)
        return;
    *leaf = '\0';

    for (int attempt = 0; attempt < 2; attempt++) {
        int fd = open(canonicalImage, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0)
            return;
        struct stat info;
        if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0) {
            close(fd);
            return;
        }
        if (vpHasVisited(walk, info.st_dev, info.st_ino)) {
            close(fd);
            return;
        }
        if (walk->visitedCount >= VP_SIG_MAX_IMAGES) {
            close(fd);
            return;
        }
        vpRecordVisited(walk, info.st_dev, info.st_ino);

        VPSigSlice slices[VP_SIG_MAX_SLICES];
        size_t sliceCount = 0;
        int status = vpCollectArm64Slices(fd, (uint64_t)info.st_size, slices, &sliceCount);
        if (status) {
            close(fd);
            vpRecordFailure(walk, status, canonicalImage);
            return;
        }
        if (sliceCount == 0) {
            close(fd);
            return;
        }

        uint8_t *sliceCommands[VP_SIG_MAX_SLICES] = {0};
        uint32_t sliceCmdCounts[VP_SIG_MAX_SLICES] = {0};
        uint32_t sliceCmdSizes[VP_SIG_MAX_SLICES] = {0};
        VPFlagsPatch patches[VP_SIG_MAX_PATCHES];
        size_t patchCount = 0;

        for (size_t index = 0; index < sliceCount; index++) {
            struct mach_header_64 header;
            if (slices[index].size < sizeof(header) ||
                vpPReadExact(fd, &header, sizeof(header), slices[index].offset) != 0 ||
                header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 ||
                header.sizeofcmds == 0 || header.sizeofcmds > VP_SIG_MAX_COMMANDS ||
                sizeof(header) + (uint64_t)header.sizeofcmds > slices[index].size) {
                status = EFTYPE;
                break;
            }
            uint8_t *commands = malloc(header.sizeofcmds);
            if (!commands) {
                status = ENOMEM;
                break;
            }
            status = vpPReadExact(fd, commands, header.sizeofcmds,
                                  slices[index].offset + (off_t)sizeof(header));
            if (status) {
                free(commands);
                break;
            }
            sliceCommands[index] = commands;
            sliceCmdCounts[index] = header.ncmds;
            sliceCmdSizes[index] = header.sizeofcmds;

            // Only inspect/repair loadable libraries and bundles; executables keep
            // their own classification (for example type 5 for vm_remap).
            if (header.filetype != MH_DYLIB && header.filetype != MH_BUNDLE)
                continue;

            int foundCodeSig = 0;
            uint32_t csDataOff = 0;
            uint32_t csDataSize = 0;
            uint32_t cmdOffset = 0;
            for (uint32_t cmdIndex = 0;
                 cmdIndex < header.ncmds && cmdOffset + sizeof(struct load_command) <= header.sizeofcmds;
                 cmdIndex++) {
                const struct load_command *command = (const struct load_command *)(commands + cmdOffset);
                if (command->cmdsize < sizeof(*command) || (command->cmdsize & 3u) != 0 ||
                    command->cmdsize > header.sizeofcmds - cmdOffset) {
                    status = EFTYPE;
                    break;
                }
                if (command->cmd == LC_CODE_SIGNATURE && command->cmdsize >= sizeof(struct linkedit_data_command)) {
                    const struct linkedit_data_command *linkedit = (const struct linkedit_data_command *)command;
                    foundCodeSig = 1;
                    csDataOff = linkedit->dataoff;
                    csDataSize = linkedit->datasize;
                }
                cmdOffset += command->cmdsize;
            }
            if (status)
                break;
            if (!foundCodeSig) {
                status = EFTYPE;
                break;
            }
            status = vpInspectSliceSignature(fd, &slices[index], csDataOff, csDataSize,
                                             patches, &patchCount, VP_SIG_MAX_PATCHES);
            if (status)
                break;
        }

        if (!status && patchCount > 0)
            status = vpRewriteWithAdHocFlags(fd, canonicalImage, &info, patches, patchCount);
        close(fd);

        if (status == EAGAIN && attempt == 0) {
            for (size_t index = 0; index < sliceCount; index++)
                free(sliceCommands[index]);
            continue;
        }
        if (!status && patchCount > 0) {
            struct stat updated;
            if (lstat(canonicalImage, &updated) == 0)
                vpRecordVisited(walk, updated.st_dev, updated.st_ino);
        }
        if (status)
            vpRecordFailure(walk, status, canonicalImage);

        for (size_t index = 0; index < sliceCount; index++) {
            if (sliceCommands[index]) {
                vpWalkSliceDependencies(walk, imageDir, sliceCommands[index],
                                        sliceCmdCounts[index], sliceCmdSizes[index]);
                free(sliceCommands[index]);
            }
        }
        return;
    }
}

int vpPrepareRootHideDylib(const char *library, const char *root,
                           char *failedPath, size_t failedPathSize) {
    if (failedPath && failedPathSize > 0)
        failedPath[0] = '\0';
    if (!library || !root || !strstr(root, "/.jbroot-"))
        return 0;

    char canonicalRoot[PATH_MAX];
    char canonicalLibrary[PATH_MAX];
    if (!realpath(root, canonicalRoot))
        return 0;
    if (!realpath(library, canonicalLibrary))
        return errno == ENOENT ? 0 : errno;
    if (!vpWithinRoot(canonicalLibrary, canonicalRoot))
        return 0;

    VPSigWalk *walk = calloc(1, sizeof(*walk));
    if (!walk)
        return ENOMEM;
    strcpy(walk->root, canonicalRoot);
    vpVisitImage(walk, canonicalLibrary);
    int status = walk->status;
    if (status && failedPath && failedPathSize > 0)
        snprintf(failedPath, failedPathSize, "%s", walk->failedPath);
    free(walk);
    return status;
}

static void vpStatStamp(const char *path, VPPathStamp *stamp) {
    memset(stamp, 0, sizeof(*stamp));
    struct stat info;
    if (stat(path, &info) == 0) {
        stamp->present = 1;
        stamp->dev = info.st_dev;
        stamp->ino = info.st_ino;
        stamp->mtimeSec = info.st_mtimespec.tv_sec;
        stamp->mtimeNsec = info.st_mtimespec.tv_nsec;
    }
}

static void vpCaptureTweakSnapshot(const char *canonicalRoot, VPTweakSnapshot *snapshot) {
    static const char *const relativePaths[5] = {
        "usr/lib/TweakLoader.dylib",
        "usr/lib/ellekit",
        "usr/lib/TweakInject",
        "usr/lib",
        "Library/dpkg/status",
    };
    memset(snapshot, 0, sizeof(*snapshot));
    snprintf(snapshot->root, sizeof(snapshot->root), "%s", canonicalRoot);
    char fullPath[PATH_MAX];
    for (size_t index = 0; index < 5; index++) {
        int used = snprintf(fullPath, sizeof(fullPath), "%s/%s", canonicalRoot, relativePaths[index]);
        if (used > 0 && (size_t)used < sizeof(fullPath))
            vpStatStamp(fullPath, &snapshot->stamps[index]);
    }
}

static int vpSnapshotsEqual(const VPTweakSnapshot *lhs, const VPTweakSnapshot *rhs) {
    if (strcmp(lhs->root, rhs->root) != 0)
        return 0;
    for (size_t index = 0; index < 5; index++) {
        const VPPathStamp *a = &lhs->stamps[index];
        const VPPathStamp *b = &rhs->stamps[index];
        if (a->present != b->present || a->dev != b->dev || a->ino != b->ino ||
            a->mtimeSec != b->mtimeSec || a->mtimeNsec != b->mtimeNsec)
            return 0;
    }
    return 1;
}

static int vpHasDylibSuffix(const char *name) {
    size_t length = strlen(name);
    return length > 6 && strcmp(name + length - 6, ".dylib") == 0;
}

static void vpScanDylibDirectory(VPSigWalk *walk, const char *directory) {
    DIR *dir = opendir(directory);
    if (!dir)
        return;
    struct dirent *entry;
    char candidate[PATH_MAX];
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.' || !vpHasDylibSuffix(entry->d_name))
            continue;
        int used = snprintf(candidate, sizeof(candidate), "%s/%s", directory, entry->d_name);
        if (used > 0 && (size_t)used < sizeof(candidate))
            vpVisitCandidate(walk, candidate);
    }
    closedir(dir);
}

void vpEnsureRootHideTweakSignatures(const char *root) {
    if (!root || !strstr(root, "/.jbroot-"))
        return;
    char canonicalRoot[PATH_MAX];
    if (!realpath(root, canonicalRoot))
        return;

    pthread_mutex_lock(&vpTweakSnapshotLock);

    VPTweakSnapshot before;
    vpCaptureTweakSnapshot(canonicalRoot, &before);
    if (vpHasTweakSnapshot && vpSnapshotsEqual(&before, &vpLastTweakSnapshot)) {
        pthread_mutex_unlock(&vpTweakSnapshotLock);
        return;
    }

    VPSigWalk *walk = calloc(1, sizeof(*walk));
    if (!walk) {
        pthread_mutex_unlock(&vpTweakSnapshotLock);
        return;
    }
    strcpy(walk->root, canonicalRoot);

    char path[PATH_MAX];
    int used = snprintf(path, sizeof(path), "%s/usr/lib/TweakLoader.dylib", canonicalRoot);
    if (used > 0 && (size_t)used < sizeof(path))
        vpVisitCandidate(walk, path);
    used = snprintf(path, sizeof(path), "%s/usr/lib/libellekit.dylib", canonicalRoot);
    if (used > 0 && (size_t)used < sizeof(path))
        vpVisitCandidate(walk, path);
    used = snprintf(path, sizeof(path), "%s/usr/lib/ellekit", canonicalRoot);
    if (used > 0 && (size_t)used < sizeof(path))
        vpScanDylibDirectory(walk, path);
    used = snprintf(path, sizeof(path), "%s/usr/lib/TweakInject", canonicalRoot);
    if (used > 0 && (size_t)used < sizeof(path))
        vpScanDylibDirectory(walk, path);

    int status = walk->status;
    free(walk);

    // Cache permanent file-format failures (EFTYPE) alongside clean passes so an
    // unrepairable unsigned tweak does not force PID 1 to rescan on every spawn;
    // any subsequent vphoned/dpkg update changes directory mtimes and invalidates.
    if (status == 0 || status == EFTYPE) {
        vpCaptureTweakSnapshot(canonicalRoot, &vpLastTweakSnapshot);
        vpHasTweakSnapshot = 1;
    }
    pthread_mutex_unlock(&vpTweakSnapshotLock);
}
