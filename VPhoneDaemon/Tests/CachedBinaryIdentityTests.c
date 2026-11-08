#include "../Native/Include/VphonedCacheIdentity.h"

#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int checks;
static int failures;

static void check(bool condition, const char *message) {
    checks++;
    if (!condition) {
        failures++;
        printf("FAIL: %s\n", message);
    }
}

static bool make_directory(const char *path) {
    return mkdir(path, 0700) == 0;
}

static bool join_path(char *destination, size_t capacity, const char *parent, const char *child) {
    size_t parent_length = strlen(parent);
    size_t child_length = strlen(child);
    if (parent_length + 1 + child_length + 1 > capacity) return false;
    memcpy(destination, parent, parent_length);
    destination[parent_length] = '/';
    memcpy(destination + parent_length + 1, child, child_length + 1);
    return true;
}

static bool write_file(const char *path, const char *contents) {
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (descriptor < 0) return false;
    size_t length = strlen(contents);
    ssize_t written = write(descriptor, contents, length);
    int close_result = close(descriptor);
    return written == (ssize_t)length && close_result == 0;
}

int main(void) {
    char root[] = "/tmp/vphoned-cache-identity.XXXXXX";
    if (!mkdtemp(root)) {
        perror("mkdtemp");
        return 1;
    }

    char volume[PATH_MAX];
    char alias_root[PATH_MAX];
    char variable[PATH_MAX];
    char root_directory[PATH_MAX];
    char library[PATH_MAX];
    char caches[PATH_MAX];
    char cache_path[PATH_MAX];
    char alias_path[PATH_MAX];
    char other_path[PATH_MAX];
    char pending_path[PATH_MAX];
    char marker_path[PATH_MAX];
    bool paths_ready = join_path(volume, sizeof(volume), root, "volume") &&
        join_path(alias_root, sizeof(alias_root), root, "private") &&
        join_path(variable, sizeof(variable), volume, "var") &&
        join_path(root_directory, sizeof(root_directory), variable, "root") &&
        join_path(library, sizeof(library), root_directory, "Library") &&
        join_path(caches, sizeof(caches), library, "Caches") &&
        join_path(cache_path, sizeof(cache_path), caches, "vphoned") &&
        join_path(alias_path, sizeof(alias_path), alias_root, "var/root/Library/Caches/vphoned") &&
        join_path(other_path, sizeof(other_path), caches, "other-vphoned") &&
        join_path(pending_path, sizeof(pending_path), caches, "pending") &&
        join_path(marker_path, sizeof(marker_path), caches, "marker");
    check(paths_ready, "built fixture paths");
    if (!paths_ready) return 1;

    bool ready = make_directory(volume) && make_directory(variable) && make_directory(root_directory) &&
        make_directory(library) && make_directory(caches) && symlink(volume, alias_root) == 0 &&
        write_file(cache_path, "cached worker") && write_file(other_path, "different worker");
    check(ready, "created the cache fixture and its aliased path");
    if (!ready) return 1;

    int directory = open(caches, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int image = open(cache_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    check(directory >= 0 && image >= 0, "opened fixture directory and image");
    if (directory < 0 || image < 0) return 1;

    check(strcmp(alias_path, cache_path) != 0, "fixture paths use different spellings");
    check(vphone_cached_file_matches_path(image, alias_path) == VPhoneCachedFileIdentityMatch,
          "the executable alias resolves to the opened cache inode");

    check(write_file(pending_path, "trusted pending marker"), "created pending marker for alias confirmation");
    VPhoneCachedConfirmation confirmation = vphone_confirm_cached_image(
        directory, image, alias_path, "pending", "marker");
    check(confirmation == VPhoneCachedConfirmationSucceeded,
          "a path alias for the cached inode confirms the pending marker");
    check(access(marker_path, F_OK) == 0 && access(pending_path, F_OK) != 0,
          "successful alias confirmation restores the marker");

    check(write_file(pending_path, "pending must remain"), "created pending marker for mismatch case");
    confirmation = vphone_confirm_cached_image(directory, image, other_path, "pending", "marker");
    check(confirmation == VPhoneCachedConfirmationNotCurrent,
          "a different executable inode cannot confirm the cache");
    check(access(pending_path, F_OK) == 0, "mismatch leaves the pending marker untouched");

    int missing = vphone_cached_file_matches_path(image, "/no/such/vphoned");
    check(missing == VPhoneCachedFileIdentityError, "an unresolvable executable path is an error");

    close(image);
    close(directory);
    unlink(marker_path);
    unlink(pending_path);
    unlink(other_path);
    unlink(cache_path);
    rmdir(caches);
    rmdir(library);
    rmdir(root_directory);
    rmdir(variable);
    unlink(alias_root);
    rmdir(volume);
    rmdir(root);

    printf("%d/%d cache identity checks passed\n", checks - failures, checks);
    return failures == 0 ? 0 : 1;
}
