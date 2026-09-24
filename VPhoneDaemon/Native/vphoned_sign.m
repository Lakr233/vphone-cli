#import "Include/VphonedNative.h"
#import <Security/Security.h>
#include <errno.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct __SecCode const *SecStaticCodeRef;
typedef CF_OPTIONS(uint32_t, SecCSFlags) {
    kSecCSDefaultFlags = 0
};
#define kSecCSRequirementInformation (1 << 2)

OSStatus SecStaticCodeCreateWithPathAndAttributes(
    CFURLRef path,
    SecCSFlags flags,
    CFDictionaryRef attributes,
    SecStaticCodeRef *staticCode
);
OSStatus SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags, CFDictionaryRef *information);
extern CFStringRef kSecCodeInfoEntitlementsDict;

// Implemented in GuestSigner.swift using the shared VPhoneSign target.
extern char *vp_guest_sign_binary(const char *path, const char *entitlementsPath, const char *certificatePath);

static NSDictionary *vp_info_dictionary_for_app_path(NSString *appPath) {
    if (appPath.length == 0) return nil;
    return [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
}

static NSString *vp_app_main_executable_path_for_app_path(NSString *appPath) {
    NSDictionary *info = vp_info_dictionary_for_app_path(appPath);
    NSString *executable = info[@"CFBundleExecutable"];
    if (executable.length == 0) return nil;
    return [appPath stringByAppendingPathComponent:executable];
}

static BOOL vp_is_macho_file(NSString *filePath) {
    FILE *file = fopen(filePath.fileSystemRepresentation, "r");
    if (!file) return NO;

    uint32_t magic = 0;
    fread(&magic, sizeof(uint32_t), 1, file);
    fclose(file);

    return magic == FAT_MAGIC || magic == FAT_CIGAM || magic == MH_MAGIC_64 || magic == MH_CIGAM_64;
}

static SecStaticCodeRef vp_get_static_code_ref(NSString *binaryPath) {
    if (binaryPath.length == 0) return NULL;

    CFURLRef binaryURL = CFURLCreateWithFileSystemPath(
        kCFAllocatorDefault,
        (__bridge CFStringRef)binaryPath,
        kCFURLPOSIXPathStyle,
        false
    );
    if (binaryURL == NULL) return NULL;

    SecStaticCodeRef codeRef = NULL;
    OSStatus result = SecStaticCodeCreateWithPathAndAttributes(binaryURL, kSecCSDefaultFlags, NULL, &codeRef);
    CFRelease(binaryURL);
    if (result != errSecSuccess) {
        return NULL;
    }
    return codeRef;
}

static NSDictionary *vp_dump_entitlements_from_binary_at_path(NSString *binaryPath) {
    SecStaticCodeRef codeRef = vp_get_static_code_ref(binaryPath);
    if (codeRef == NULL) return nil;

    CFDictionaryRef signingInfo = NULL;
    OSStatus result = SecCodeCopySigningInformation(codeRef, kSecCSRequirementInformation, &signingInfo);
    CFRelease(codeRef);
    if (result != errSecSuccess || signingInfo == NULL) {
        if (signingInfo) CFRelease(signingInfo);
        return nil;
    }

    NSDictionary *entitlementsNSDict = nil;
    CFDictionaryRef entitlements = CFDictionaryGetValue(signingInfo, kSecCodeInfoEntitlementsDict);
    if (entitlements && CFGetTypeID(entitlements) == CFDictionaryGetTypeID()) {
        entitlementsNSDict = [(__bridge NSDictionary *)entitlements copy];
    }

    CFRelease(signingInfo);
    return entitlementsNSDict;
}

static int vp_sign_binary(
    NSString *filePath,
    NSDictionary *entitlements,
    NSString *certPath,
    NSString **errorOutput
) {
    NSString *entitlementsPath = nil;
    NSData *entitlementsXML = entitlements ? [NSPropertyListSerialization
        dataWithPropertyList:entitlements
        format:NSPropertyListXMLFormat_v1_0
        options:0
        error:nil] : nil;
    if (entitlementsXML) {
        entitlementsPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString]
            stringByAppendingPathExtension:@"plist"];
        if (![entitlementsXML writeToFile:entitlementsPath atomically:YES]) {
            if (errorOutput) *errorOutput = @"Could not prepare app entitlements.";
            return EIO;
        }
    }

    char *error = vp_guest_sign_binary(
        filePath.fileSystemRepresentation,
        entitlementsPath.fileSystemRepresentation,
        certPath.length > 0 ? certPath.fileSystemRepresentation : NULL
    );
    if (entitlementsPath) {
        [[NSFileManager defaultManager] removeItemAtPath:entitlementsPath error:nil];
    }
    if (!error) return 0;
    if (errorOutput) *errorOutput = [NSString stringWithUTF8String:error] ?: @"Could not sign app executable.";
    free(error);
    return EINVAL;
}

static int vp_sign_app(NSString *appPath, NSString *certPath, NSString **errorOutput) {
    if (!vp_info_dictionary_for_app_path(appPath)) {
        if (errorOutput) *errorOutput = @"The app package is incomplete and cannot be signed.";
        return 172;
    }

    NSString *mainExecutablePath = vp_app_main_executable_path_for_app_path(appPath);
    if (mainExecutablePath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:mainExecutablePath]) {
        if (errorOutput) *errorOutput = @"The app package is missing its program and cannot be signed.";
        return 174;
    }

    NSMutableSet<NSString *> *signedExecutables = [NSMutableSet set];
    NSURL *fileURL = nil;
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:[NSURL fileURLWithPath:appPath]
        includingPropertiesForKeys:nil
        options:0
        errorHandler:nil];
    while ((fileURL = [enumerator nextObject])) {
        NSString *filePath = fileURL.path;
        if (![filePath.lastPathComponent isEqualToString:@"Info.plist"]) {
            continue;
        }

        NSDictionary *infoDict = [NSDictionary dictionaryWithContentsOfFile:filePath];
        NSString *bundleId = infoDict[@"CFBundleIdentifier"];
        NSString *bundleExecutable = infoDict[@"CFBundleExecutable"];
        if (bundleId.length == 0 || bundleExecutable.length == 0) {
            continue;
        }

        NSString *bundleMainExecutablePath = [[filePath stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:bundleExecutable];
        if (![[NSFileManager defaultManager] fileExistsAtPath:bundleMainExecutablePath]) {
            continue;
        }

        NSString *packageType = infoDict[@"CFBundlePackageType"];
        if ([packageType isEqualToString:@"FMWK"]) {
            continue;
        }

        NSMutableDictionary *entitlementsToUse =
            [vp_dump_entitlements_from_binary_at_path(bundleMainExecutablePath) mutableCopy];
        if (!entitlementsToUse && [bundleMainExecutablePath isEqualToString:mainExecutablePath]) {
            entitlementsToUse = [@{
                @"application-identifier": @"TROLLTROLL.*",
                @"com.apple.developer.team-identifier": @"TROLLTROLL",
                @"get-task-allow": @YES,
                @"keychain-access-groups": @[@"TROLLTROLL.*", @"com.apple.token"],
            } mutableCopy];
        }
        if (!entitlementsToUse) {
            entitlementsToUse = [NSMutableDictionary dictionary];
        }

        NSObject *containerRequired = entitlementsToUse[@"com.apple.private.security.container-required"];
        BOOL shouldWriteContainerRequired = YES;
        if ([containerRequired isKindOfClass:[NSString class]]) {
            shouldWriteContainerRequired = NO;
        } else if ([containerRequired isKindOfClass:[NSNumber class]]) {
            shouldWriteContainerRequired = [(NSNumber *)containerRequired boolValue];
        }
        BOOL noContainer =
            [entitlementsToUse[@"com.apple.private.security.no-container"] respondsToSelector:@selector(boolValue)]
            ? [entitlementsToUse[@"com.apple.private.security.no-container"] boolValue]
            : NO;
        BOOL noSandbox =
            [entitlementsToUse[@"com.apple.private.security.no-sandbox"] respondsToSelector:@selector(boolValue)]
            ? [entitlementsToUse[@"com.apple.private.security.no-sandbox"] boolValue]
            : NO;
        if (shouldWriteContainerRequired && !noContainer && !noSandbox) {
            entitlementsToUse[@"com.apple.private.security.container-required"] = bundleId;
        }
        entitlementsToUse[@"jb.pmap_cs_custom_trust"] = @"PMAP_CS_APP_STORE";

        NSString *signOutput = @"";
        int ret = vp_sign_binary(bundleMainExecutablePath, entitlementsToUse, certPath, &signOutput);
        if (ret != 0) {
            if (errorOutput) *errorOutput = signOutput;
            return 173;
        }
        [signedExecutables addObject:bundleMainExecutablePath];
    }

    // Sign code without an Info.plist executable declaration, such as dylibs.
    // The declared executables above already carry their guest entitlements.
    enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:[NSURL fileURLWithPath:appPath]
        includingPropertiesForKeys:nil
        options:0
        errorHandler:nil];
    while ((fileURL = [enumerator nextObject])) {
        NSString *filePath = fileURL.path;
        if ([signedExecutables containsObject:filePath] || !vp_is_macho_file(filePath)) continue;
        NSString *signOutput = @"";
        if (vp_sign_binary(filePath, nil, certPath, &signOutput) != 0) {
            if (errorOutput) *errorOutput = signOutput;
            return 173;
        }
    }
    return 0;
}


char *vp_sign_app_for_install(const char *appPath, const char *certificatePath) {
    if (!appPath) return strdup("Missing app path");
    NSString *failure = nil;
    NSString *app = [NSString stringWithUTF8String:appPath];
    NSString *certificate = certificatePath ? [NSString stringWithUTF8String:certificatePath] : nil;
    if (vp_sign_app(app, certificate, &failure) == 0) return NULL;
    return strdup((failure ?: @"Could not sign app.").UTF8String);
}
