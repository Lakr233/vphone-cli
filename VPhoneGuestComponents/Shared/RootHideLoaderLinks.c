#include "RootHideLoaderLinks.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int vpWithin(const char *path, const char *directory) {
    size_t length = strlen(directory);
    return strncmp(path, directory, length) == 0 &&
           (path[length] == '/' || path[length] == '\0');
}

static int vpLinkTarget(const char *directory, const char *root, char target[PATH_MAX]) {
    const char *relative = directory + strlen(root);
    if (!*relative) {
        strcpy(target, ".");
        return 0;
    }
    size_t depth = 0;
    for (const char *cursor = relative; *cursor; cursor++) {
        if (*cursor == '/')
            depth++;
    }
    if (depth * 3 >= PATH_MAX)
        return ENAMETOOLONG;
    target[0] = '\0';
    for (size_t index = 0; index < depth; index++)
        strcat(target, index ? "/.." : "..");
    return 0;
}

int vpEnsureRootHideLoaderLink(const char *executable, const char *root) {
    if (!executable || !root || !strstr(root, "/.jbroot-"))
        return 0;
    const char *namedRoot = root;
    if (strncmp(root, "/private/var/", 13) == 0 && strncmp(executable, "/var/", 5) == 0)
        namedRoot += 8;
    if (!vpWithin(executable, namedRoot))
        return 0;

    char canonicalRoot[PATH_MAX];
    char canonicalExecutable[PATH_MAX];
    if (!realpath(root, canonicalRoot) || !realpath(executable, canonicalExecutable))
        return errno;
    char *leaf = strrchr(canonicalExecutable, '/');
    if (!leaf || leaf == canonicalExecutable)
        return EINVAL;
    *leaf = '\0';
    if (!vpWithin(canonicalExecutable, canonicalRoot))
        return 0;

    char target[PATH_MAX];
    int status = vpLinkTarget(canonicalExecutable, canonicalRoot, target);
    if (status)
        return status;
    int directory = open(canonicalExecutable, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0)
        return errno;
    struct stat info;
    if (fstatat(directory, ".jbroot", &info, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISLNK(info.st_mode)) {
            close(directory);
            return EEXIST;
        }
        char linkPath[PATH_MAX];
        char resolved[PATH_MAX];
        int used = snprintf(linkPath, sizeof(linkPath), "%s/.jbroot", canonicalExecutable);
        status = used <= 0 || (size_t)used >= sizeof(linkPath) ? ENAMETOOLONG :
                 !realpath(linkPath, resolved) ? errno :
                 strcmp(resolved, canonicalRoot) == 0 ? 0 : EEXIST;
    } else if (errno == ENOENT) {
        status = symlinkat(target, directory, ".jbroot") == 0 ? 0 : errno;
    } else {
        status = errno;
    }
    close(directory);
    return status;
}
