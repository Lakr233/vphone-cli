#include "../Shared/RootHideLoaderLinks.h"
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void directory(const char *path) { assert(mkdir(path, 0700) == 0); }
static void file(const char *path) {
    FILE *stream = fopen(path, "w");
    assert(stream);
    assert(fclose(stream) == 0);
}

int main(void) {
    char scratch[] = "/tmp/vphone-loader-links.XXXXXX";
    assert(mkdtemp(scratch));
    char root[PATH_MAX], apps[PATH_MAX], bundle[PATH_MAX], executable[PATH_MAX], link[PATH_MAX];
    assert((size_t)snprintf(root, sizeof(root), "%s/.jbroot-000114514191980C", scratch) < sizeof(root));
    assert((size_t)snprintf(apps, sizeof(apps), "%s/Applications", root) < sizeof(apps));
    assert((size_t)snprintf(bundle, sizeof(bundle), "%s/TrollSpeed.app", apps) < sizeof(bundle));
    assert((size_t)snprintf(executable, sizeof(executable), "%s/TrollSpeed", bundle) < sizeof(executable));
    assert((size_t)snprintf(link, sizeof(link), "%s/.jbroot", bundle) < sizeof(link));
    directory(root);
    directory(apps);
    directory(bundle);
    file(executable);

    assert(vpEnsureRootHideLoaderLink(executable, root) == 0);
    char resolved[PATH_MAX], canonicalRoot[PATH_MAX], canonicalScratch[PATH_MAX];
    assert(realpath(root, canonicalRoot));
    assert(realpath(scratch, canonicalScratch));
    assert(realpath(link, resolved) && strcmp(resolved, canonicalRoot) == 0);
    assert(vpEnsureRootHideLoaderLink(executable, root) == 0);

    assert(unlink(link) == 0);
    assert(symlink(scratch, link) == 0);
    assert(vpEnsureRootHideLoaderLink(executable, root) == EEXIST);
    assert(realpath(link, resolved) && strcmp(resolved, canonicalScratch) == 0);

    assert(unlink(link) == 0);
    file(link);
    assert(vpEnsureRootHideLoaderLink(executable, root) == EEXIST);
    assert(unlink(link) == 0);

    char unrelated[PATH_MAX];
    assert((size_t)snprintf(unrelated, sizeof(unrelated), "%s/unrelated", scratch) < sizeof(unrelated));
    file(unrelated);
    assert(vpEnsureRootHideLoaderLink(unrelated, root) == 0);
    assert(unlink(unrelated) == 0);

    assert(unlink(executable) == 0);
    assert(rmdir(bundle) == 0);
    assert(rmdir(apps) == 0);
    assert(rmdir(root) == 0);
    assert(rmdir(scratch) == 0);
    puts("RootHide loader link tests passed");
}
