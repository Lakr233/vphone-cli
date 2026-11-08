#pragma once

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <sys/stat.h>

typedef enum {
    VPhoneCachedFileIdentityError = -1,
    VPhoneCachedFileIdentityDifferent = 0,
    VPhoneCachedFileIdentityMatch = 1,
} VPhoneCachedFileIdentity;

typedef enum {
    VPhoneCachedConfirmationError = -1,
    VPhoneCachedConfirmationNotCurrent = 0,
    VPhoneCachedConfirmationSucceeded = 1,
} VPhoneCachedConfirmation;

// The cache path is opened separately with O_NOFOLLOW. stat() here follows
// aliases in the running executable path, such as /var and /private/var.
static inline VPhoneCachedFileIdentity vphone_cached_file_matches_path(int descriptor, const char *path) {
    if (descriptor < 0 || !path) {
        errno = EINVAL;
        return VPhoneCachedFileIdentityError;
    }

    struct stat opened;
    struct stat named;
    if (fstat(descriptor, &opened) != 0 || stat(path, &named) != 0) {
        return VPhoneCachedFileIdentityError;
    }
    if ((opened.st_mode & S_IFMT) != S_IFREG || (named.st_mode & S_IFMT) != S_IFREG) {
        errno = EINVAL;
        return VPhoneCachedFileIdentityError;
    }
    return opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
        ? VPhoneCachedFileIdentityMatch
        : VPhoneCachedFileIdentityDifferent;
}

// Called only after the caller has opened and validated the cache directory,
// pending marker, and cached image with the existing no-follow/root checks.
static inline VPhoneCachedConfirmation vphone_confirm_cached_image(
    int directory, int image, const char *current_path, const char *pending_leaf, const char *marker_leaf
) {
    VPhoneCachedFileIdentity identity = vphone_cached_file_matches_path(image, current_path);
    if (identity == VPhoneCachedFileIdentityDifferent) return VPhoneCachedConfirmationNotCurrent;
    if (identity == VPhoneCachedFileIdentityError) return VPhoneCachedConfirmationError;
    if (renameat(directory, pending_leaf, directory, marker_leaf) != 0) return VPhoneCachedConfirmationError;
    return VPhoneCachedConfirmationSucceeded;
}
