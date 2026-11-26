#ifndef VPHONE_ROOT_HIDE_DYLIB_SIGNATURE_H
#define VPHONE_ROOT_HIDE_DYLIB_SIGNATURE_H

#include <stddef.h>

// Ensure `library` and every Mach-O dylib or bundle it depends on inside a
// RootHide `root` carries either a real CMS signature or CS_ADHOC. Under
// txm-cfw-executable_remap, CMS-less ldid signatures (flags == 0) located
// under /private/var/containers/Bundle/ classify as type 5 and are rejected by
// TXM selector 38 (0x07 | 0x30 | 5) in higher-trust hosts, killing every app
// during dlopen with CODESIGNING / Invalid Page.
//
// When a CMS-less dylib lacks CS_ADHOC, this atomically writes a sibling copy
// with CS_ADHOC set and renames it into place so XNU/TXM sees a fresh inode.
// Returns 0 when safe to dlopen (already compatible, outside RootHide, missing,
// or repaired), or a non-zero errno when dlopen must be refused (for example
// EACCES/EPERM when unprivileged, or EFTYPE when unsigned or malformed). When
// returning non-zero and `failedPath` is non-NULL, stores the offending path.
int vpPrepareRootHideDylib(const char *library, const char *root,
                           char *failedPath, size_t failedPathSize);

// Best-effort root-side maintenance for RootHide tweak injection: repairs
// TweakLoader.dylib, libellekit.dylib, ellekit/*.dylib, TweakInject/*.dylib,
// and their in-root Mach-O dependencies whenever any tracked path changes.
void vpEnsureRootHideTweakSignatures(const char *root);

#endif
