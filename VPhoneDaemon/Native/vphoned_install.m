#import "vphoned_install.h"
#import "unarchive.h"

#import <Security/Security.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#import "vphoned_response.h"

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

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (getter=isInstalled, nonatomic, readonly) BOOL installed;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)registerApplicationDictionary:(NSDictionary *)dict;
- (BOOL)registerContainerizedApplicationWithInfoDictionaries:(NSArray *)infos
                                              operationUUID:(NSUUID *)uuid
                                             requestContext:(id)context
                                               saveObserver:(id)observer
                                          registrationError:(NSError **)error;
- (BOOL)unregisterApplication:(id)arg1;
@end

@interface LSEnumerator : NSEnumerator
@property (nonatomic, copy) NSPredicate *predicate;
+ (instancetype)enumeratorForApplicationProxiesWithOptions:(NSUInteger)options;
@end

@interface MCMContainer : NSObject
+ (id)containerWithIdentifier:(id)arg1 createIfNecessary:(BOOL)arg2 existed:(BOOL *)arg3 error:(id *)arg4;
@property (nonatomic, readonly) NSURL *url;
@end

static NSString *const VPManagedMarker = @"_VPhone";

static void vp_load_private_frameworks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_NOW);
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
    });
}

static NSString *vp_trimmed_output(NSString *string) {
    NSString *trimmed = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > 4000) {
        return [trimmed substringToIndex:4000];
    }
    return trimmed;
}

static NSDictionary *vp_info_dictionary_for_app_path(NSString *appPath) {
    if (appPath.length == 0) return nil;
    return [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
}

static NSString *vp_app_id_for_app_path(NSString *appPath) {
    return vp_info_dictionary_for_app_path(appPath)[@"CFBundleIdentifier"];
}

static NSString *vp_app_main_executable_path_for_app_path(NSString *appPath) {
    NSDictionary *info = vp_info_dictionary_for_app_path(appPath);
    NSString *executable = info[@"CFBundleExecutable"];
    if (executable.length == 0) return nil;
    return [appPath stringByAppendingPathComponent:executable];
}

static NSString *vp_find_app_name_in_bundle_path(NSString *bundlePath) {
    NSArray<NSString *> *bundleItems = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
    for (NSString *bundleItem in bundleItems) {
        if ([bundleItem.pathExtension isEqualToString:@"app"]) {
            return bundleItem;
        }
    }
    return nil;
}

static NSString *vp_find_app_path_in_bundle_path(NSString *bundlePath) {
    NSString *appName = vp_find_app_name_in_bundle_path(bundlePath);
    if (appName.length == 0) return nil;
    return [bundlePath stringByAppendingPathComponent:appName];
}

static NSURL *vp_find_app_url_in_bundle_url(NSURL *bundleURL) {
    NSString *appName = vp_find_app_name_in_bundle_path(bundleURL.path);
    if (appName.length == 0) return nil;
    return [bundleURL URLByAppendingPathComponent:appName];
}

static BOOL vp_is_macho_file(NSString *filePath) {
    FILE *file = fopen(filePath.fileSystemRepresentation, "r");
    if (!file) return NO;

    uint32_t magic = 0;
    fread(&magic, sizeof(uint32_t), 1, file);
    fclose(file);

    return magic == FAT_MAGIC || magic == FAT_CIGAM || magic == MH_MAGIC_64 || magic == MH_CIGAM_64;
}

static void vp_fix_permissions_of_app_bundle(NSString *appBundlePath) {
    NSURL *fileURL = nil;
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:[NSURL fileURLWithPath:appBundlePath]
        includingPropertiesForKeys:nil
        options:0
        errorHandler:nil];
    while ((fileURL = [enumerator nextObject])) {
        NSString *filePath = fileURL.path;
        chown(filePath.fileSystemRepresentation, 33, 33);
        chmod(filePath.fileSystemRepresentation, 0644);
    }

    enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:[NSURL fileURLWithPath:appBundlePath]
        includingPropertiesForKeys:nil
        options:0
        errorHandler:nil];
    while ((fileURL = [enumerator nextObject])) {
        NSString *filePath = fileURL.path;
        BOOL isDir = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:filePath isDirectory:&isDir];
        if (isDir || vp_is_macho_file(filePath)) {
            chmod(filePath.fileSystemRepresentation, 0755);
        }
    }
}

static NSString *vp_read_all_from_fd(int fd) {
    NSMutableData *data = [NSMutableData data];
    uint8_t buf[4096];
    ssize_t n = 0;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        [data appendBytes:buf length:(NSUInteger)n];
    }
    if (data.length == 0) return @"";
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

static int vp_run_process_with_output(NSString *path, NSArray<NSString *> *args, NSString **output) {
    NSUInteger argc = args.count + 2;
    char **argv = calloc(argc, sizeof(char *));
    if (!argv) return ENOMEM;

    argv[0] = strdup(path.fileSystemRepresentation);
    for (NSUInteger i = 0; i < args.count; i++) {
        argv[i + 1] = strdup(args[i].fileSystemRepresentation);
    }
    argv[argc - 1] = NULL;

    int pipeFds[2] = {-1, -1};
    if (pipe(pipeFds) != 0) {
        for (NSUInteger i = 0; i < argc - 1; i++) free(argv[i]);
        free(argv);
        return errno;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipeFds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipeFds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipeFds[0]);

    pid_t pid = 0;
    int spawnError = posix_spawn(&pid, path.fileSystemRepresentation, &actions, NULL, argv, NULL);

    posix_spawn_file_actions_destroy(&actions);
    close(pipeFds[1]);

    NSString *captured = vp_read_all_from_fd(pipeFds[0]);
    close(pipeFds[0]);

    int status = 0;
    if (spawnError == 0 && waitpid(pid, &status, 0) < 0) {
        spawnError = errno;
    }

    for (NSUInteger i = 0; i < argc - 1; i++) free(argv[i]);
    free(argv);

    if (output) *output = captured;

    if (spawnError != 0) return spawnError;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

static NSString *vp_find_ldid_path(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in @[
        @"/var/jb/usr/bin/ldid",
        @"/iosbinpack64/usr/bin/ldid",
        @"/usr/bin/ldid",
    ]) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
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
    NSString *ldidPath,
    NSString **errorOutput
) {
    if (ldidPath.length == 0) {
        if (errorOutput) *errorOutput = @"The code-signing tool (ldid) is missing on the guest.";
        return ENOENT;
    }

    NSString *entitlementsPath = nil;
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    NSData *entitlementsXML = entitlements ? [NSPropertyListSerialization
        dataWithPropertyList:entitlements
        format:NSPropertyListXMLFormat_v1_0
        options:0
        error:nil] : nil;
    if (entitlementsXML) {
        entitlementsPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString]
            stringByAppendingPathExtension:@"plist"];
        [entitlementsXML writeToFile:entitlementsPath atomically:NO];
        [args addObject:[@"-S" stringByAppendingString:entitlementsPath]];
    } else {
        [args addObject:@"-S"];
    }

    if (certPath.length > 0) {
        [args addObject:@"-M"];
        [args addObject:[@"-K" stringByAppendingString:certPath]];
    }

    [args addObject:filePath];

    NSString *output = @"";
    int ret = vp_run_process_with_output(ldidPath, args, &output);
    if (entitlementsPath) {
        [[NSFileManager defaultManager] removeItemAtPath:entitlementsPath error:nil];
    }
    if (errorOutput) *errorOutput = output;
    return ret;
}

static int vp_sign_app(NSString *appPath, NSString *certPath, NSString *ldidPath, NSString **errorOutput) {
    if (!vp_info_dictionary_for_app_path(appPath)) {
        if (errorOutput) *errorOutput = @"The app package is incomplete and cannot be signed.";
        return 172;
    }

    NSString *mainExecutablePath = vp_app_main_executable_path_for_app_path(appPath);
    if (mainExecutablePath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:mainExecutablePath]) {
        if (errorOutput) *errorOutput = @"The app package is missing its program and cannot be signed.";
        return 174;
    }

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
        int ret = vp_sign_binary(bundleMainExecutablePath, entitlementsToUse, certPath, ldidPath, &signOutput);
        if (ret != 0) {
            if (errorOutput) *errorOutput = signOutput;
            return 173;
        }
    }

    NSString *recursiveOutput = @"";
    int recursiveRet = vp_sign_binary(appPath, nil, certPath, ldidPath, &recursiveOutput);
    if (recursiveRet != 0) {
        if (errorOutput) *errorOutput = recursiveOutput;
        return 173;
    }
    return 0;
}

static NSDictionary *vp_construct_groups_containers_for_entitlements(NSDictionary *entitlements, BOOL systemGroups) {
    if (!entitlements) return nil;

    NSString *entitlementForGroups = systemGroups
        ? @"com.apple.security.system-groups"
        : @"com.apple.security.application-groups";
    Class mcmClass = NSClassFromString(systemGroups ? @"MCMSystemDataContainer" : @"MCMSharedDataContainer");
    if (!mcmClass) return nil;

    NSArray *groupIDs = entitlements[entitlementForGroups];
    if (![groupIDs isKindOfClass:[NSArray class]]) return nil;

    NSMutableDictionary *groupContainers = [NSMutableDictionary dictionary];
    for (NSString *groupID in groupIDs) {
        MCMContainer *container = [mcmClass
            containerWithIdentifier:groupID
            createIfNecessary:YES
            existed:nil
            error:nil];
        if (container.url.path.length > 0) {
            groupContainers[groupID] = container.url.path;
        }
    }
    return groupContainers.count > 0 ? groupContainers.copy : nil;
}

static BOOL vp_construct_containerization_for_entitlements(NSDictionary *entitlements, NSString **customContainerOut) {
    NSNumber *noContainer = entitlements[@"com.apple.private.security.no-container"];
    if ([noContainer isKindOfClass:[NSNumber class]] && noContainer.boolValue) {
        return NO;
    }

    NSObject *containerRequired = entitlements[@"com.apple.private.security.container-required"];
    if ([containerRequired isKindOfClass:[NSNumber class]] && ![(NSNumber *)containerRequired boolValue]) {
        return NO;
    }
    if ([containerRequired isKindOfClass:[NSString class]]) {
        *customContainerOut = (NSString *)containerRequired;
    }
    return YES;
}

static NSString *vp_construct_team_identifier_for_entitlements(NSDictionary *entitlements) {
    NSString *teamIdentifier = entitlements[@"com.apple.developer.team-identifier"];
    return [teamIdentifier isKindOfClass:[NSString class]] ? teamIdentifier : nil;
}

static NSDictionary *vp_construct_environment_variables_for_container_path(
    NSString *containerPath,
    BOOL isContainerized
) {
    NSString *homeDir = isContainerized ? containerPath : @"/var/mobile";
    NSString *tmpDir = isContainerized ? [containerPath stringByAppendingPathComponent:@"tmp"] : @"/var/tmp";
    return @{
        @"CFFIXED_USER_HOME": homeDir,
        @"HOME": homeDir,
        @"TMPDIR": tmpDir,
    };
}

static NSSet<NSString *> *vp_immutable_app_bundle_identifiers(void) {
    NSMutableSet<NSString *> *systemAppIdentifiers = [NSMutableSet set];
    LSEnumerator *enumerator = [(id)NSClassFromString(@"LSEnumerator") enumeratorForApplicationProxiesWithOptions:0];
    LSApplicationProxy *appProxy = nil;
    while ((appProxy = [enumerator nextObject])) {
        if (appProxy.installed && ![appProxy.bundleURL.path hasPrefix:@"/private/var/containers"]) {
            [systemAppIdentifiers addObject:appProxy.bundleIdentifier.lowercaseString];
        }
    }
    return systemAppIdentifiers.copy;
}

/// Build the LaunchServices registration dictionary shared by an app bundle and its PlugIns.
/// The caller adds the keys that differ: ApplicationType, Path, and the app- or plugin-only keys.
static NSMutableDictionary *vp_registration_dictionary(
    NSString *bundleID,
    NSString *executablePath,
    Class containerClass
) {
    NSDictionary *entitlements = vp_dump_entitlements_from_binary_at_path(executablePath);

    NSString *dataContainerID = bundleID;
    BOOL containerized = vp_construct_containerization_for_entitlements(entitlements ?: @{}, &dataContainerID);

    MCMContainer *dataContainer = [containerClass
        containerWithIdentifier:dataContainerID
        createIfNecessary:YES
        existed:nil
        error:nil];
    NSString *containerPath = dataContainer.url.path;

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (entitlements) {
        dict[@"Entitlements"] = entitlements;
    }
    dict[@"CFBundleIdentifier"] = bundleID;
    dict[@"CodeInfoIdentifier"] = bundleID;
    dict[@"CompatibilityState"] = @0;
    dict[@"IsContainerized"] = @(containerized);
    if (containerPath.length > 0) {
        dict[@"Container"] = containerPath;
        dict[@"EnvironmentVariables"] =
            vp_construct_environment_variables_for_container_path(containerPath, containerized);
    }
    dict[@"SignerOrganization"] = @"Apple Inc.";
    dict[@"SignatureVersion"] = @132352;
    dict[@"SignerIdentity"] = @"Apple iPhone OS Application Signing";

    NSString *teamIdentifier = vp_construct_team_identifier_for_entitlements(entitlements ?: @{});
    if (teamIdentifier.length > 0) {
        dict[@"TeamIdentifier"] = teamIdentifier;
    }

    NSDictionary *appGroupContainers = vp_construct_groups_containers_for_entitlements(entitlements, NO);
    NSDictionary *systemGroupContainers = vp_construct_groups_containers_for_entitlements(entitlements, YES);
    NSMutableDictionary *groupContainers = [NSMutableDictionary dictionary];
    [groupContainers addEntriesFromDictionary:appGroupContainers];
    [groupContainers addEntriesFromDictionary:systemGroupContainers];
    if (groupContainers.count > 0) {
        if (appGroupContainers.count > 0) {
            dict[@"HasAppGroupContainers"] = @YES;
        }
        if (systemGroupContainers.count > 0) {
            dict[@"HasSystemGroupContainers"] = @YES;
        }
        dict[@"GroupContainers"] = groupContainers.copy;
    }

    return dict;
}

static BOOL vp_register_path(NSString *path, BOOL unregister, BOOL forceSystem) {
    if (path.length == 0) return NO;

    LSApplicationWorkspace *workspace = [(id)NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace];
    if (unregister && ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        LSApplicationProxy *app = [LSApplicationProxy applicationProxyForIdentifier:path];
        if (app.bundleURL.path.length > 0) {
            path = app.bundleURL.path;
        }
    }

    path = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSDictionary *appInfoPlist =
        [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *appBundleID = appInfoPlist[@"CFBundleIdentifier"];
    if (appBundleID.length == 0) return NO;
    if ([vp_immutable_app_bundle_identifiers() containsObject:appBundleID.lowercaseString]) return NO;

    if (!unregister) {
        NSString *appExecutablePath = [path stringByAppendingPathComponent:appInfoPlist[@"CFBundleExecutable"]];
        NSMutableDictionary *dictToRegister = vp_registration_dictionary(
            appBundleID,
            appExecutablePath,
            NSClassFromString(@"MCMAppDataContainer"));

        BOOL isRemovableSystemApp = [[NSFileManager defaultManager]
            fileExistsAtPath:[@"/System/Library/AppSignatures" stringByAppendingPathComponent:appBundleID]];
        BOOL registerAsUser = [path hasPrefix:@"/var/containers"] && !isRemovableSystemApp && !forceSystem;

        dictToRegister[@"ApplicationType"] = registerAsUser ? @"User" : @"System";
        dictToRegister[@"IsDeletable"] = @YES;
        dictToRegister[@"Path"] = path;
        dictToRegister[@"IsAdHocSigned"] = @YES;
        dictToRegister[@"LSInstallType"] = @1;
        dictToRegister[@"HasMIDBasedSINF"] = @0;
        dictToRegister[@"MissingSINF"] = @0;
        dictToRegister[@"FamilyID"] = @0;
        dictToRegister[@"IsOnDemandInstallCapable"] = @0;

        NSString *pluginsPath = [path stringByAppendingPathComponent:@"PlugIns"];
        NSArray<NSString *> *plugins = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:pluginsPath error:nil];
        NSMutableDictionary *bundlePlugins = [NSMutableDictionary dictionary];
        for (NSString *pluginName in plugins) {
            NSString *pluginPath = [pluginsPath stringByAppendingPathComponent:pluginName];
            NSDictionary *pluginInfoPlist =
                [NSDictionary dictionaryWithContentsOfFile:[pluginPath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *pluginBundleID = pluginInfoPlist[@"CFBundleIdentifier"];
            NSString *pluginExecutable = pluginInfoPlist[@"CFBundleExecutable"];
            if (pluginBundleID.length == 0 || pluginExecutable.length == 0) {
                continue;
            }
            NSString *pluginExecutablePath = [pluginPath stringByAppendingPathComponent:pluginExecutable];

            NSMutableDictionary *pluginDict = vp_registration_dictionary(
                pluginBundleID,
                pluginExecutablePath,
                NSClassFromString(@"MCMPluginKitPluginDataContainer"));
            pluginDict[@"ApplicationType"] = @"PluginKitPlugin";
            pluginDict[@"Path"] = pluginPath;
            pluginDict[@"PluginOwnerBundleID"] = appBundleID;

            bundlePlugins[pluginBundleID] = pluginDict;
        }
        dictToRegister[@"_LSBundlePlugins"] = bundlePlugins;

        if ([workspace registerApplicationDictionary:dictToRegister]) {
            return YES;
        }
        // iOS 27+: the plain registerApplicationDictionary path is gated off in lsd
        // (returns NO). Fall back to the containerized registration path, which
        // works once lsd's clientIsEntitledForEmbeddedRegistrationOperations gate
        // is patched (cfw_patch_lsd_embedded_reg). It returns NO even on success,
        // so treat a nil registrationError as success.
        SEL containerizedSel = @selector(registerContainerizedApplicationWithInfoDictionaries:operationUUID:requestContext:saveObserver:registrationError:);
        if ([workspace respondsToSelector:containerizedSel]) {
            NSError *regError = nil;
            [workspace registerContainerizedApplicationWithInfoDictionaries:@[dictToRegister]
                                                              operationUUID:[NSUUID UUID]
                                                             requestContext:nil
                                                               saveObserver:nil
                                                          registrationError:&regError];
            if (regError == nil) {
                return YES;
            }
        }
        return NO;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    return [workspace unregisterApplication:url];
}

static BOOL vp_container_has_known_marker(NSString *containerPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *marker in @[VPManagedMarker, @"_TrollStoreLite", @"_TrollStore"]) {
        if ([fm fileExistsAtPath:[containerPath stringByAppendingPathComponent:marker]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL vp_mark_container_as_managed(NSString *containerPath) {
    NSString *markerPath = [containerPath stringByAppendingPathComponent:VPManagedMarker];
    if ([[NSFileManager defaultManager] fileExistsAtPath:markerPath]) {
        return YES;
    }
    return [@"" writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static int vp_install_app_from_package(
    NSString *appPackagePath,
    BOOL forceSystem,
    NSString *certPath,
    NSString *ldidPath,
    NSString **detailOutput
) {
    NSString *appPayloadPath = [appPackagePath stringByAppendingPathComponent:@"Payload"];
    NSString *appBundleToInstallPath = vp_find_app_path_in_bundle_path(appPayloadPath);
    if (appBundleToInstallPath.length == 0) {
        if (detailOutput) *detailOutput = @"The app package does not contain an app.";
        return 167;
    }

    NSString *appId = vp_app_id_for_app_path(appBundleToInstallPath);
    if (appId.length == 0) {
        if (detailOutput) *detailOutput = @"The app package has no bundle identifier.";
        return 176;
    }

    if ([vp_immutable_app_bundle_identifiers() containsObject:appId.lowercaseString]) {
        if (detailOutput) *detailOutput = @"This app is part of iOS and cannot be replaced.";
        return 179;
    }

    NSString *signOutput = @"";
    int signRet = vp_sign_app(appBundleToInstallPath, certPath, ldidPath, &signOutput);
    if (signRet != 0) {
        if (detailOutput) *detailOutput = signOutput;
        return signRet;
    }

    Class appContainerClass = NSClassFromString(@"MCMAppContainer");
    if (!appContainerClass) {
        if (detailOutput) *detailOutput = @"The app container service is unavailable.";
        return 170;
    }

    MCMContainer *appContainer = [appContainerClass
        containerWithIdentifier:appId
        createIfNecessary:NO
        existed:nil
        error:nil];
    if (appContainer) {
        NSURL *bundleContainerURL = appContainer.url;
        NSURL *appBundleURL = vp_find_app_url_in_bundle_url(bundleContainerURL);
        if (appBundleURL.path.length > 0 && !vp_container_has_known_marker(bundleContainerURL.path)) {
            if (detailOutput) *detailOutput = @"An app with the same bundle identifier is already installed. Remove it and try again.";
            return 171;
        }
        if (appBundleURL.path.length > 0) {
            [[NSFileManager defaultManager] removeItemAtURL:appBundleURL error:nil];
        }
    } else {
        NSError *mcmError = nil;
        appContainer = [appContainerClass
            containerWithIdentifier:appId
            createIfNecessary:YES
            existed:nil
            error:&mcmError];
        if (!appContainer || mcmError) {
            if (detailOutput) *detailOutput = mcmError.localizedDescription ?: @"Unable to prepare storage for the app.";
            return 170;
        }
    }

    NSString *newAppBundlePath =
        [appContainer.url.path stringByAppendingPathComponent:appBundleToInstallPath.lastPathComponent];
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:appBundleToInstallPath
                                                 toPath:newAppBundlePath
                                                  error:&copyError]) {
        if (detailOutput) *detailOutput = copyError.localizedDescription ?: @"Unable to copy the app onto the guest.";
        return 178;
    }

    if (!vp_mark_container_as_managed(appContainer.url.path)) {
        if (detailOutput) *detailOutput = @"The app was installed but could not be marked as managed.";
        return 177;
    }

    NSURL *updatedAppURL = vp_find_app_url_in_bundle_url(appContainer.url);
    if (updatedAppURL.path.length == 0) {
        if (detailOutput) *detailOutput = @"The app was installed but could not be located afterwards.";
        return 178;
    }

    vp_fix_permissions_of_app_bundle(updatedAppURL.path);
    if (!vp_register_path(updatedAppURL.path, NO, forceSystem)) {
        if (detailOutput) *detailOutput = @"The app was copied but could not be registered with the system.";
        return 181;
    }

    if (detailOutput) {
        *detailOutput = [NSString stringWithFormat:@"%@ (%@)", updatedAppURL.lastPathComponent, appId];
    }
    return 0;
}

static int vp_extract_package_to_directory(
    NSString *fileToExtract,
    NSString *extractionPath,
    NSString **detailOutput
) {
    NSString *archiveError = nil;
    int ret = vp_extract_archive(fileToExtract, extractionPath, &archiveError);
    if (ret != 0) {
        if (detailOutput) *detailOutput = archiveError ?: @"Unable to extract the app package.";
        return 168;
    }
    return 0;
}

BOOL vp_custom_installer_available(void) {
    vp_load_private_frameworks();
    return NSClassFromString(@"MCMAppContainer") != Nil
        && NSClassFromString(@"LSApplicationWorkspace") != Nil;
}

NSDictionary *vp_handle_custom_install(NSDictionary *msg) {
    vp_load_private_frameworks();
    id reqId = msg[@"id"];
    NSString *ipaPath = msg[@"path"];
    NSString *registration = msg[@"registration"];
    NSString *certPath = msg[@"cert_path"];
    NSString *ldidPath = vp_find_ldid_path();
    BOOL forceSystem = [registration isEqualToString:@"System"];

    if (ipaPath.length == 0) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        response[@"msg"] = @"No app package was specified.";
        return response;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:ipaPath]) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        response[@"msg"] = [NSString stringWithFormat:@"App package not found at %@.", ipaPath];
        return response;
    }
    if (!vp_custom_installer_available()) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        NSMutableArray<NSString *> *missing = [NSMutableArray array];
        if (NSClassFromString(@"MCMAppContainer") == Nil) [missing addObject:@"MCMAppContainer"];
        if (NSClassFromString(@"LSApplicationWorkspace") == Nil) [missing addObject:@"LSApplicationWorkspace"];
        NSString *detail = missing.count > 0 ? [missing componentsJoinedByString:@", "] : @"unknown";
        NSLog(@"vphoned: custom installer unavailable: %@", detail);
        response[@"msg"] = @"This guest cannot install apps. The built-in installer is not supported here.";
        return response;
    }
    if (ldidPath.length == 0) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        response[@"msg"] = @"The code-signing tool (ldid) is missing on the guest. Install it and try again.";
        return response;
    }
    if (certPath.length > 0 && ![[NSFileManager defaultManager] fileExistsAtPath:certPath]) {
        certPath = nil;
    }

    NSString *tmpPackagePath = [[NSTemporaryDirectory() stringByResolvingSymlinksInPath]
        stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:tmpPackagePath
                                   withIntermediateDirectories:NO
                                                    attributes:nil
                                                         error:nil]) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        response[@"msg"] = @"Unable to prepare the guest for installation. Try again.";
        return response;
    }

    NSString *detail = @"";
    int extractRet = vp_extract_package_to_directory(ipaPath, tmpPackagePath, &detail);
    int installRet = 0;
    if (extractRet == 0) {
        installRet = vp_install_app_from_package(tmpPackagePath, forceSystem, certPath, ldidPath, &detail);
    }

    [[NSFileManager defaultManager] removeItemAtPath:tmpPackagePath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:ipaPath error:nil];
    if (certPath.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:certPath error:nil];
    }
    if (extractRet != 0 || installRet != 0) {
        NSMutableDictionary *response = vp_make_response(@"err", reqId);
        int retCode = extractRet != 0 ? extractRet : installRet;
        NSString *trimmed = vp_trimmed_output(detail ?: @"");
        response[@"msg"] = trimmed.length > 0
            ? [NSString stringWithFormat:@"Unable to install the app (code %d).\n%@", retCode, trimmed]
            : [NSString stringWithFormat:@"Unable to install the app (code %d).", retCode];
        return response;
    }

    NSMutableDictionary *response = vp_make_response(@"ok", reqId);
    response[@"msg"] = forceSystem
        ? [NSString stringWithFormat:@"Installed %@ as a system app.", detail]
        : [NSString stringWithFormat:@"Installed %@ as a user app.", detail];
    return response;
}
