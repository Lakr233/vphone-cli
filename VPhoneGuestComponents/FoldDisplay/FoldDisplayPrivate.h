#ifndef FOLD_DISPLAY_PRIVATE_H
#define FOLD_DISPLAY_PRIVATE_H

// Shared by every libvphonefolddisplay translation unit, grouped by the file
// that defines each declaration. State used by one file stays static there.
//
// Everything declared between the visibility pragmas is internal to the
// dylib: it links across files but stays out of the export table.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <xpc/xpc.h>

#pragma GCC visibility push(hidden)

// MARK: - FoldDisplaySupport.m

extern NSString *const vpInnerDisplayName;
void vpFoldDisplayLog(NSString *line);
id vpReadObject(id object, const char *name);
id vpReadObjectIvar(id object, const char *name);

// MARK: - FoldDisplayBackboard.m

void vpInstallInnerRenderDisplay(void);
void vpTagRenderDisplay(id display, NSString *tagName);

// MARK: - FoldDisplayAdapter.m

BOOL vpIsInnerDisplay(id display);
BOOL vpIsInnerDisplayIdentity(id identity);
void vpInstallExternalDisplay(BOOL serverProcess);
void vpPrepareExternalRenderDisplays(id server);
BOOL vpSceneIsOnInnerDisplay(id scene);
/// The SpringBoard window scene (not an aperture subclass) on the inner
/// display, or on Main.
id vpSpringBoardWindowScene(BOOL inner);
void vpInstallInnerDisplayAdapter(void);

// MARK: - FoldDisplayPanel.m

void vpInstallSharedPanel(void);

// MARK: - FoldDisplayStatusBar.m

void vpInstallDualStatusLookup(void);

#pragma GCC visibility pop

#endif
