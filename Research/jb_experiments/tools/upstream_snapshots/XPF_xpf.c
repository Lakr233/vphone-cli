#include <choma/Fat.h>
#include <choma/MachO.h>
#include <choma/PatchFinder.h>
#include <choma/MachOByteOrder.h>
#include <choma/BufferedStream.h>
#include <mach/machine.h>
#include "xpf.h"
#include "decompress.h"

#include "ppl.h"
#include "non_ppl.h"
#include "sptm_txm.h"
#include "common.h"
#include "bad_recovery.h"

#include <libvfs/vfs.h>

bool xpf_supported_always(void)
{
	return true;
}

bool xpf_supported_sptm(void)
{
	return (bool)gXPF.sptm;
}

bool xpf_supported_sptm_18_3_down(void)
{
	return (bool)gXPF.sptm && strcmp(gXPF.darwinVersion, "24.3.0") <= 0;
}

bool xpf_supported_sptm_18_4_to_26_x(void)
{
	return (bool)gXPF.sptm && strcmp(gXPF.darwinVersion, "24.4.0") >= 0 && strcmp(gXPF.darwinVersion, "27.0.0") < 0;
}

bool xpf_supported_18_down_incl_26b1(void)
{
	if (!strcmp(gXPF.xnuBuild, "12377.0.81.0.3~311")) {
		return true;
	}
	return strcmp(gXPF.darwinVersion, "25.0.0") < 0;
}

bool xpf_supported_26_up_excl_26b1(void)
{
	if (!strcmp(gXPF.xnuBuild, "12377.0.81.0.3~311")) {
		return false;
	}
	return strcmp(gXPF.darwinVersion, "25.0.0") >= 0;
}

bool xpf_supported_sptm_27_0_up(void)
{
	return (bool)gXPF.sptm && strcmp(gXPF.darwinVersion, "27.0.0") >= 0;
}

bool xpf_supported_non_sptm(void)
{
	return !xpf_supported_sptm();
}

// iOS 15 and above
bool xpf_supported_15up(void)
{
	return strcmp(gXPF.darwinVersion, "21.0.0") >= 0;
}

// iOS 15 and below
bool xpf_supported_15down(void)
{
	return strcmp(gXPF.darwinVersion, "22.0.0") < 0;
}

// iOS 16 and above
bool xpf_supported_16up(void)
{
	return strcmp(gXPF.darwinVersion, "22.0.0") >= 0;
}

// iOS 16 and below
bool xpf_supported_16down(void)
{
	return strcmp(gXPF.darwinVersion, "23.0.0") < 0;
}

// iOS 15.x and 16.x
bool xpf_supported_1516(void)
{
	return xpf_supported_15up() && xpf_supported_16down();
}

bool xpf_supported_16up_sptm(void)
{
	return xpf_supported_16up() && xpf_supported_sptm();
}

bool xpf_supported_16up_no_sptm(void)
{
	return xpf_supported_16up() && xpf_supported_non_sptm();
}

bool xpf_supported_arm64(void)
{
	return !gXPF.kernelIsArm64e;
}

bool xpf_arm64_kcall_supported(void)
{
	return xpf_supported_arm64() && xpf_supported_16down();
}

bool xpf_trigon_supported(void)
{
	return gXPF.kernelIsArm64e && xpf_supported_15up() && xpf_supported_16down();
}

XPFSet gBaseSet = {
	.name="base",
	.supported=xpf_supported_always,
	.metrics={
		"kernelConstant.kernel_el",
		"kernelSymbol.allproc",
		"kernelSymbol.kalloc_data_external",
		"kernelSymbol.kfree_data_external",
		NULL
	}
};

XPFSet gTranslationSet = {
	.name="translation",
	.supported=xpf_supported_non_sptm,
	.metrics={
		"kernelSymbol.cpu_ttep",
		"kernelSymbol.gVirtBase",
		"kernelSymbol.gPhysBase",
		"kernelSymbol.gPhysSize",
		"kernelSymbol.ptov_table",
		"kernelConstant.pointer_mask",
		"kernelConstant.T1SZ_BOOT",
		"kernelConstant.ARM_TT_L1_INDEX_MASK",
		NULL
	}
};

XPFSet gTranslationSPTMSet = {
	.name="translation",
	.supported=xpf_supported_sptm,
	.metrics={
		"kernelSymbol.SPTMArgs",
		"kernelSymbol.cpu_ttep",
		"kernelSymbol.gVirtBase",
		"kernelSymbol.gPhysBase",
		"kernelSymbol.gPhysSize",
		"kernelConstant.pointer_mask",
		"kernelConstant.T1SZ_BOOT",
		"kernelConstant.ARM_TT_L1_INDEX_MASK",
		NULL
	}
};

XPFSet gPhysmapSet = {
	.name="physmap",
	.supported=xpf_supported_non_sptm,
	.metrics={
		"kernelSymbol.vm_page_array_beginning_addr",
		"kernelSymbol.vm_page_array_ending_addr",
		"kernelSymbol.vm_first_phys_ppnum",
		"kernelSymbol.vm_first_phys",
		"kernelSymbol.vm_last_phys",
		"kernelSymbol.pp_attr_table",
		"kernelSymbol.pv_head_table",
		"kernelSymbol.ptov_table",
		"kernelConstant.PT_INDEX_MAX",
		"kernelSymbol.pmap_enter_options_addr",
		"kernelSymbol.pmap_remove_options",
		NULL
	}
};

XPFSet gPhysmapSPTMSet_18_3_Down = {
	.name="physmap",
	.supported=xpf_supported_sptm_18_3_down,
	.metrics={
		"kernelSymbol.vm_page_array_beginning_addr",
		"kernelSymbol.vm_page_array_ending_addr",
		"kernelSymbol.vm_first_phys_ppnum",
		"kernelSymbol.vm_first_phys",
		"kernelSymbol.vm_last_phys",
		"kernelSymbol.pp_attr_table",
		"kernelSymbol.pv_head_table",
		"kernelSymbol.libsptm_papt_ranges",
		"kernelSymbol.libsptm_n_papt_ranges",
		"kernelSymbol.papt_ranges_compressed",
		"kernelSymbol.n_papt_ranges_compressed",
		"kernelSymbol.libsptm_frame_table",
		NULL
	}
};

XPFSet gPhysmapSPTMSet_18_4_Up = {
	.name="physmap",
	.supported=xpf_supported_sptm_18_4_to_26_x,
	.metrics={
		"kernelSymbol.vm_page_array_beginning_addr",
		"kernelSymbol.vm_page_array_ending_addr",
		"kernelSymbol.vm_first_phys_ppnum",
		"kernelSymbol.vm_first_phys",
		"kernelSymbol.vm_last_phys",
		"kernelSymbol.pp_attr_table",
		"kernelSymbol.pv_head_table",
		"kernelSymbol.libsptm_papt_ranges",
		"kernelSymbol.libsptm_n_papt_ranges",
		"kernelSymbol.papt_ranges_compressed",
		"kernelSymbol.n_papt_ranges_compressed",
		"kernelSymbol.libsptm_frame_table",
		"kernelSymbol.libsptm_frame_type_params",
		"kernelStruct.sptm_frame_type_descriptor.struct_size",
		NULL
	}
};

XPFSet gPhysmapSPTMSet_27_0_Up = {
	.name="physmap",
	.supported=xpf_supported_sptm_27_0_up,
	.metrics={
		"kernelSymbol.vm_page_array_beginning_addr",
		"kernelSymbol.vm_page_array_ending_addr",
		"kernelSymbol.vm_first_phys_ppnum",
		"kernelSymbol.vm_first_phys",
		"kernelSymbol.vm_last_phys",
		"kernelSymbol.libsptm_papt_ranges",
		"kernelSymbol.libsptm_n_papt_ranges",
		"kernelSymbol.papt_ranges_compressed",
		"kernelSymbol.n_papt_ranges_compressed",
		"kernelSymbol.libsptm_frame_table",
		"kernelSymbol.libsptm_frame_type_params",
		"kernelStruct.sptm_frame_type_descriptor.struct_size",
		"kernelSymbol.pmap_first_pnum",
		"kernelSymbol.vm_pages_radix_root",
		NULL
	}
};

XPFSet gStructSet_18Down = {
	.name="struct",
	.supported=xpf_supported_18_down_incl_26b1,
	.metrics={
		"kernelStruct.proc.struct_size",
		"kernelStruct.task.itk_space",
		"kernelStruct.vm_map.pmap",
		NULL
	}
};

XPFSet gStructSet_26Up = {
	.name="struct",
	.supported=xpf_supported_26_up_excl_26b1,
	.metrics={
		"kernelStruct.proc.struct_size",
		"kernelStruct.task.itk_space",
		"kernelStruct.task.security_config", // The field in this that Dopamine needs was only introduced in 26.0b2
		"kernelStruct.vm_map.pmap",
		NULL
	}
};

XPFSet gTrustcache15Set = {
	.name="trustcache",
	.supported=xpf_supported_15down,
	{
		"kernelSymbol.pmap_image4_trust_caches",
		NULL
	}
};

XPFSet gTrustcache16Set = {
	.name="trustcache",
	xpf_supported_16up_no_sptm,
	.metrics={
		"kernelSymbol.ppl_trust_cache_rt",
		NULL
	}
};

XPFSet gTrustcacheSPTMSet = {
	.name="trustcache",
	xpf_supported_16up_sptm,
	.metrics={
		"kernelSymbol.txm_trustcache_root",
		NULL
	}
};

XPFSet gBadRecoverySet = {
	.name="badRecovery",
	.supported=xpf_bad_recovery_supported,
	.metrics={
		"kernelSymbol.hw_lck_ticket_reserve_orig_allow_invalid",
		"kernelGadget.hw_lck_ticket_reserve_orig_allow_invalid_signed",
		"kernelGadget.br_x22",
		"kernelSymbol.exception_return",
		"kernelGadget.exception_return_after_check",
		"kernelGadget.exception_return_after_check_no_restore",
		"kernelGadget.ldp_x0_x1_x8",
		"kernelGadget.str_x8_x9",
		"kernelGadget.str_x0_x19_ldr_x20",
		"kernelGadget.pacda",
		"kernelSymbol.ml_sign_thread_state",
		"kernelStruct.thread.recover",
		"kernelStruct.thread.machine_kstackptr",
		"kernelStruct.thread.machine_CpuDatap",
		"kernelStruct.thread.machine_contextData",
		"kernelSymbol.mac_label_set",
		NULL
	}
};

XPFSet gSandboxSet = {
	.name="sandbox",
	.supported=xpf_supported_15up,
	.metrics={
		"kernelConstant.nsysent",
		"kernelConstant.mach_trap_count",
		"kernelSymbol.mach_kobj_count",
		NULL,
	}
};

XPFSet gPhysRWSet = {
	.name="physrw",
	.supported=xpf_supported_always,
	.metrics={
		NULL,
	}
};

XPFSet gPerfKRWSet = {
	.name="perfkrw",
	.supported=xpf_supported_1516,
	.metrics={
		"kernelSymbol.perfmon_dev_open",
		"kernelSymbol.perfmon_devices",
		"kernelSymbol.vn_kqfilter",
		"kernelSymbol.cdevsw",
		NULL
	},
};

XPFSet gDevModeSet = {
	.name="devmode",
	.supported=xpf_supported_16up_no_sptm,
	.metrics={
		"kernelSymbol.developer_mode_enabled",
		NULL
	},
};

XPFSet gDevModeSPTMSet = {
	.name="devmode",
	.supported=xpf_supported_16up_sptm,
	.metrics={
		"kernelSymbol.txm_developer_mode_storage",
		NULL
	},
};

XPFSet gArm64KcallSet = {
	.name="arm64kcall",
	.supported=xpf_arm64_kcall_supported,
	.metrics={
		"kernelSymbol.exception_return",
		"kernelGadget.kcall_return",
		"kernelGadget.str_x8_x0",
		"kernelStruct.thread.machine_CpuDatap",
		"kernelStruct.thread.machine_kstackptr",
		"kernelStruct.thread.machine_contextData",
		NULL
	},
};

XPFSet gTrigonSet = {
	.name="trigon",
	.supported=xpf_trigon_supported,
	.metrics={
		"kernelSymbol.iorvbar",
		NULL
	}
};

XPFSet gIOSurfaceSet = {
	.name="IOSurface",
	.supported=xpf_supported_always,
	.metrics={
		"kernelStruct.IOSurface.ranges",
		"kernelStruct.IOSurface.rangeCount",
		NULL
	}
};

XPFSet *gSets[] = {
	&gBaseSet,
	&gTranslationSet,
	&gTranslationSPTMSet,
	&gSandboxSet,
	&gPhysmapSet,
	&gPhysmapSPTMSet_18_3_Down,
	&gPhysmapSPTMSet_18_4_Up,
	&gPhysmapSPTMSet_27_0_Up,
	&gStructSet_18Down,
	&gStructSet_26Up,
	&gTrustcache15Set,
	&gTrustcache16Set,
	&gTrustcacheSPTMSet,
	&gBadRecoverySet,
	&gPhysRWSet,
	&gPerfKRWSet,
	&gDevModeSet,
	&gDevModeSPTMSet,
	&gArm64KcallSet,
	&gTrigonSet,
	&gIOSurfaceSet,
};

XPF gXPF = { 0 };

PFSection *xpf_pfsec_init(const char *filesetEntryId, const char *segName, const char *sectName)
{
	PFSection *section = pfsec_init_from_macho(gXPF.kernel, gXPF.kernelIsFileset ? filesetEntryId : NULL, segName, sectName);
	if (section) {
		pfsec_set_cached(section, true);
		pfsec_set_pointer_decoder(section, xpfsec_decode_pointer);
	}
	return section;
}

PFSection *xpf_sptm_pfsec_init(const char *segName, const char *sectName)
{
	if (!gXPF.sptm) return NULL;

	PFSection *section = pfsec_init_from_macho(gXPF.sptm, NULL, segName, sectName);
	if (section) {
		pfsec_set_cached(section, true);
		pfsec_set_pointer_decoder(section, xpfsec_decode_pointer);
	}
	return section;
}

PFSection *xpf_txm_pfsec_init(const char *segName, const char *sectName)
{
	if (!gXPF.txm) return NULL;

	PFSection *section = pfsec_init_from_macho(gXPF.txm, NULL, segName, sectName);
	if (section) {
		pfsec_set_cached(section, true);
		pfsec_set_pointer_decoder(section, xpfsec_decode_pointer);
	}
	return section;
}

int xpf_load_img4(const char *path, void **outBuf, size_t *outSize)
{
	FHANDLE fd = img4_reopen(file_open(path, O_RDONLY), NULL, 0);
	if (!fd) return -1;

	unsigned char *buf = 0;
	size_t sz = 0;
	int r = fd->ioctl(fd, IOCTL_MEM_GET_DATAPTR, &buf, &sz);
	if (r == 0 && outBuf && outSize) {
		*outSize = sz;
		*outBuf = malloc(sz);
		memcpy(*outBuf, buf, sz);
	}

	fd->close(fd);
	return r;
}

int xpf_start_with_kernel_path(const char *kernelPath, const char *optSptmPath, const char *optTxmPath)
{
	gXPF.kernelFd = open(kernelPath, O_RDONLY);
	if (gXPF.kernelFd < 0) {
		xpf_set_error("Failed to open kernelcache");
		return -1;
	}

	struct stat s;
	fstat(gXPF.kernelFd, &s);
	gXPF.kernelSize = s.st_size;
	gXPF.mappedKernel = mmap(NULL, gXPF.kernelSize, PROT_READ, MAP_PRIVATE, gXPF.kernelFd, 0);
	if (gXPF.mappedKernel == MAP_FAILED) {
		xpf_set_error("Failed to map kernelcache");
		return -1;
	}

	MemoryStream *stream = NULL;
	if (LITTLE_TO_HOST(*(uint32_t *)(gXPF.mappedKernel)) == MH_MAGIC_64
		|| (*(uint32_t *)(gXPF.mappedKernel)) == FAT_CIGAM) {
		stream = buffered_stream_init_from_buffer_nocopy(gXPF.mappedKernel, gXPF.kernelSize, 0);
	}
	else {
		gXPF.decompressedKernel = kdecompress(gXPF.mappedKernel, gXPF.kernelSize, &gXPF.decompressedKernelSize);
		if (gXPF.decompressedKernel) {
			stream = buffered_stream_init_from_buffer_nocopy(gXPF.decompressedKernel, gXPF.decompressedKernelSize, 0);
		}
	}

	Fat *candidate = fat_init_from_memory_stream(stream);
	if (!candidate) {
		xpf_set_error("Failed to load kernel macho");
		return -1;
	}

	MachO *machoCandidate = NULL;
	gXPF.kernelIsArm64e = false;
	machoCandidate = fat_find_slice(candidate, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL);
	if (!machoCandidate) {
		gXPF.kernelIsArm64e = true;
		machoCandidate = fat_find_slice(candidate, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E);
		if (!machoCandidate) {
			machoCandidate = fat_find_slice(candidate, CPU_TYPE_ARM64, 0xC0000002);
		}
	}
	if (!machoCandidate) {
		xpf_set_error("Failed to load kernel macho");
		return -1;
	}

	gXPF.kernelContainer = candidate;
	gXPF.kernel = machoCandidate;
	gXPF.kernelIsFileset = macho_get_filetype(gXPF.kernel) == MH_FILESET;

	gXPF.kernelTextSection = xpf_pfsec_init("com.apple.kernel", "__TEXT_EXEC", "__text");
	gXPF.kernelPinstSection = xpf_pfsec_init("com.apple.kernel", "__LAST", "__pinst");
	gXPF.kernelPPLTextSection = xpf_pfsec_init("com.apple.kernel", "__PPLTEXT", "__text");
	gXPF.kernelStringSection = xpf_pfsec_init("com.apple.kernel", "__TEXT", "__cstring");
	gXPF.kernelConstSection = xpf_pfsec_init("com.apple.kernel", "__TEXT", "__const");
	gXPF.kernelDataConstSection = xpf_pfsec_init("com.apple.kernel", "__DATA_CONST", "__const");
	gXPF.kernelDataSection = xpf_pfsec_init("com.apple.kernel", "__DATA", "__data");
	gXPF.kernelOSLogSection = xpf_pfsec_init("com.apple.kernel", "__TEXT", "__os_log");
	gXPF.kernelBootdataInit = xpf_pfsec_init("com.apple.kernel", "__BOOTDATA", "__init");
	gXPF.kernelBootcodeSection = xpf_pfsec_init("com.apple.kernel", "__TEXT_BOOT_EXEC", "__bootcode");

	if (gXPF.kernelIsFileset) {
		gXPF.kernelAMFITextSection = xpf_pfsec_init("com.apple.driver.AppleMobileFileIntegrity", "__TEXT_EXEC", "__text");
		gXPF.kernelAMFIStringSection = xpf_pfsec_init("com.apple.driver.AppleMobileFileIntegrity", "__TEXT", "__cstring");
		gXPF.kernelSandboxTextSection = xpf_pfsec_init("com.apple.security.sandbox", "__TEXT_EXEC", "__text");
		gXPF.kernelSandboxAuthStubSection = xpf_pfsec_init("com.apple.security.sandbox", "__TEXT_EXEC", "__auth_stubs");
		gXPF.kernelSandboxStringSection = xpf_pfsec_init("com.apple.security.sandbox", "__TEXT", "__cstring");
		gXPF.kernelIOSurfaceTextSection = xpf_pfsec_init("com.apple.iokit.IOSurface", "__TEXT_EXEC", "__text");
		gXPF.kernelIOSurfaceStringSection = xpf_pfsec_init("com.apple.iokit.IOSurface", "__TEXT", "__cstring");
		gXPF.kernelIOSurfaceOsLogSection = xpf_pfsec_init("com.apple.iokit.IOSurface", "__TEXT", "__os_log");
		gXPF.kernelInfoPlistSection = xpf_pfsec_init("com.apple.security.AppleImage4", "__TEXT", "__info_plist");
	}
	else {
		gXPF.kernelPrelinkTextSection = xpf_pfsec_init(NULL, "__PRELINK_TEXT", "__text");
		gXPF.kernelPLKTextSection = xpf_pfsec_init(NULL, "__PLK_TEXT_EXEC", "__text");
		gXPF.kernelKmodInfoSection = xpf_pfsec_init(NULL, "__PRELINK_INFO", "__kmod_info");
		gXPF.kernelPrelinkInfoSection = xpf_pfsec_init(NULL, "__PRELINK_INFO", "__info");
	}

	gXPF.kernelBase = macho_get_base_address(gXPF.kernel);
	gXPF.kernelEntry = 0;
	macho_enumerate_load_commands(gXPF.kernel, ^(struct load_command loadCommand, uint64_t offset, void *cmd, bool *stop) {
		if (loadCommand.cmd == LC_UNIXTHREAD) {
			uint8_t *cmdData = ((uint8_t *)cmd + sizeof(struct thread_command));
			uint8_t *cmdDataEnd = ((uint8_t *)cmd + loadCommand.cmdsize);

			while (cmdData < cmdDataEnd) {
				uint32_t flavor = LITTLE_TO_HOST(*(uint32_t *)cmdData);
				uint32_t count = LITTLE_TO_HOST(*(uint32_t *)(cmdData + 4));
				if (flavor == ARM_THREAD_STATE64) {
					arm_thread_state64_t *threadState = (arm_thread_state64_t *)(cmdData + 8);
#ifdef __arm64e__
					gXPF.kernelEntry = LITTLE_TO_HOST((uint64_t)threadState->__opaque_pc);
#else
					gXPF.kernelEntry = LITTLE_TO_HOST((uint64_t)threadState->__pc);
#endif
				}
				cmdData += (8 + count);
			}
			*stop = true;
		}
	});

	if (gXPF.kernelBase == UINT64_MAX) {
		xpf_set_error("Failed to find kernel base");
		return -1;
	}
	if (!gXPF.kernelEntry) {
		xpf_set_error("Failed to find kernel entry point");
		return -1;
	}

	const char *versionSearchString = "Darwin Kernel Version ";
	PFPatternMetric *versionMetric = pfmetric_pattern_init((void *)versionSearchString, NULL, strlen(versionSearchString), sizeof(uint8_t));
	pfmetric_run(gXPF.kernelConstSection, versionMetric, ^(uint64_t vmaddr, bool *stop) {
		int r = pfsec_read_string(gXPF.kernelConstSection, vmaddr, &gXPF.kernelVersionString);
		*stop = true;
	});
	pfmetric_free(versionMetric);

	if (gXPF.kernelInfoPlistSection) {
		const char *infoPlistString = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";
		PFPatternMetric *infoPlistMetric = pfmetric_pattern_init((void *)infoPlistString, NULL, strlen(infoPlistString), sizeof(uint8_t));
		pfmetric_run(gXPF.kernelInfoPlistSection, infoPlistMetric, ^(uint64_t vmaddr, bool *stop) {
			int r = pfsec_read_string(gXPF.kernelInfoPlistSection, vmaddr, &gXPF.kernelInfoPlist);
			*stop = true;
		});
		pfmetric_free(infoPlistMetric);
	}

	if (!gXPF.kernelVersionString) {
		xpf_set_error("Failed to find kernel version");
		return -1;
	}
	else {
		char darwinVersion[100];
		char xnuBuild[100];
		char xnuPlatform[100];
		sscanf(gXPF.kernelVersionString, "Darwin Kernel Version %[^:]: %*[^;]; root:xnu-%[^/]/%s", darwinVersion, xnuBuild, xnuPlatform);
		gXPF.darwinVersion = strdup(darwinVersion);
		gXPF.xnuBuild = strdup(xnuBuild);
		gXPF.xnuPlatform = strdup(xnuPlatform);

		if (gXPF.kernelInfoPlistSection) {
			char osVersion[100];
			const char *DTPlatformVersion = strstr(gXPF.kernelInfoPlist, "<key>DTPlatformVersion</key>");
			sscanf(DTPlatformVersion, "<key>DTPlatformVersion</key>\t<string>%9[^<]</string>", osVersion);
			gXPF.osVersion = strdup(osVersion);
		}
	}

	if (optSptmPath) {
		if (xpf_load_img4(optSptmPath, &gXPF.decompressedSptm, &gXPF.decompressedSptmSize) != 0) {
			xpf_set_error("Failed to load / decompress SPTM");
			return -1;
		}

		MemoryStream *stream = buffered_stream_init_from_buffer_nocopy(gXPF.decompressedSptm, gXPF.decompressedSptmSize, 0);
		gXPF.sptmContainer = fat_init_from_memory_stream(stream);
		gXPF.sptm = fat_get_single_slice(gXPF.sptmContainer);
		gXPF.sptmBase = macho_get_base_address(gXPF.sptm);

		gXPF.sptmTextSection = xpf_sptm_pfsec_init("__TEXT_EXEC", "__text");
		gXPF.sptmStringSection = xpf_sptm_pfsec_init("__TEXT", "__cstring");
	}
	if (optTxmPath) {
		if (xpf_load_img4(optTxmPath, &gXPF.decompressedTxm, &gXPF.decompressedTxmSize) != 0) {
			xpf_set_error("Failed to load / decompress TXM");
			return -1;
		}

		MemoryStream *stream = buffered_stream_init_from_buffer_nocopy(gXPF.decompressedTxm, gXPF.decompressedTxmSize, 0);
		gXPF.txmContainer = fat_init_from_memory_stream(stream);
		gXPF.txm = fat_get_single_slice(gXPF.txmContainer);
		gXPF.txmBase = macho_get_base_address(gXPF.txm);

		gXPF.txmTextSection = xpf_txm_pfsec_init("__TEXT_EXEC", "__text");
		gXPF.txmStringSection = xpf_txm_pfsec_init("__TEXT", "__cstring");
	}

	xpf_ppl_init();
	xpf_non_ppl_init();
	xpf_sptm_txm_init();
	xpf_common_init();
	xpf_bad_recovery_init();

	return 0;
}

void xpf_item_register(const char *name, void *finder, void *ctx)
{
	XPFItem *newItem = malloc(sizeof(XPFItem));
	memset(newItem, 0x0, sizeof(XPFItem));
	newItem->name = name;
	newItem->ctx = ctx;
	newItem->finder = finder;
	newItem->cache = 0;
	newItem->cached = false;

	XPFItem *lastItem = NULL;
	XPFItem *item = gXPF.firstItem;
	while (item) {
		lastItem = item;
		item = item->nextItem;
	}
	if (!lastItem) {
		gXPF.firstItem = newItem;
	}
	else {
		lastItem->nextItem = newItem;
	}
}

uint64_t xpf_item_resolve(const char *name)
{
	XPFItem *item = gXPF.firstItem;
	while (item) {
		if (!strcmp(item->name, name)) {
			if (!item->cached) {
				item->cache = item->finder(item->ctx);
				item->cached = true;
			}
			return item->cache;
		}
		item = item->nextItem;
	}
	return 0;
}

void xpf_print_all_items(void)
{
	XPFItem *item = gXPF.firstItem;
	while (item) {
		printf("0x%016llx <- %s\n", xpf_item_resolve(item->name), item->name);
		item = item->nextItem;
	}
}

uint64_t xpfsec_decode_pointer(PFSection *section, uint64_t vmaddr, uint64_t value)
{
	if ((value & 0xffff000000000000) != 0xffff000000000000) {
		// Chained fixups, other stuff
		value &= 0x00000000ffffffff;
		value += macho_get_base_address(section->macho);
	}
	return value;
}

XPFSet *xpf_find_set(const char *name, bool *foundUnsupported)
{
	uint32_t setCount = (sizeof(gSets)/sizeof(XPFSet*));
	for (int i = 0; i < setCount; i++) {
		if (!strcmp(gSets[i]->name, name)) {
			if (!gSets[i]->supported()) {
				if (foundUnsupported) *foundUnsupported = true;
				continue;
			}
			return gSets[i];
		}
	}
	return false;
}

bool xpf_set_is_supported(const char *name)
{
	XPFSet *set = xpf_find_set(name, NULL);
	return set != NULL;
}

int xpf_offset_dictionary_add_set(xpc_object_t xdict, XPFSet *set)
{
	if (!set->supported()) {
		return -1;
	}

	for (int i = 0; set->metrics[i]; i++) {
		uint64_t resolved = xpf_item_resolve(set->metrics[i]);
		if (resolved) {
			xpc_dictionary_set_uint64(xdict, set->metrics[i], resolved);
		}
		else {
			const char *existingError = xpf_get_error();
			if (existingError) {
				xpf_set_error("Set \"%s\" failed on \"%s\" (%s)", set->name, set->metrics[i], existingError);
			}
			else {
				xpf_set_error("Set \"%s\" failed on \"%s\"", set->name, set->metrics[i]);
			}
			return -1;
		}
	}
	return 0;
}

void xpf_set_ignore_base_set(bool val)
{
	gXPF.ignoreBaseSet = val;
}

xpc_object_t xpf_construct_offset_dictionary(const char *sets[])
{
	xpc_object_t offsetDictionary = xpc_dictionary_create_empty();

	if (!gXPF.ignoreBaseSet) {
		if (xpf_offset_dictionary_add_set(offsetDictionary, &gBaseSet) != 0) return NULL;
	}

	uint32_t setCount = (sizeof(gSets)/sizeof(XPFSet*));

	for (int i = 0; sets[i]; i++) {
		bool foundUnsupported = false;
		XPFSet *set = xpf_find_set(sets[i], &foundUnsupported);
		if (set) {
			int r = xpf_offset_dictionary_add_set(offsetDictionary, set);
			if (r != 0) {
				xpc_release(offsetDictionary);
				return NULL;
			}
		}
		else if (foundUnsupported) {
			xpf_set_error("Set \"%s\" is unsupported by this device", sets[i]);
			xpc_release(offsetDictionary);
			return NULL;
		}
		else {
			xpf_set_error("Failed to find set \"%s\"", sets[i]);
			xpc_release(offsetDictionary);
			return NULL;
		}
	}

	return offsetDictionary;
}

static char *gXPFError;

void xpf_set_error(const char *error, ...)
{
	char *newError = NULL;
	va_list va;
	va_start(va, error);
	vasprintf(&newError, error, va);
	va_end(va);

	if (gXPFError) {
		free(gXPFError);
	}
	gXPFError = newError;
}

const char *xpf_get_error(void)
{
	return gXPFError;
}

void xpf_stop(void)
{
	if (gXPF.mappedKernel) {
		munmap(gXPF.mappedKernel, gXPF.kernelSize);
	}
	if (gXPF.decompressedKernel) {
		free(gXPF.decompressedKernel);
	}
	if (gXPF.kernelFd >= 0) {
		close(gXPF.kernelFd);
	}

	if (gXPF.kernelTextSection) pfsec_free(gXPF.kernelTextSection);
	if (gXPF.kernelPPLTextSection) pfsec_free(gXPF.kernelPPLTextSection);
	if (gXPF.kernelStringSection) pfsec_free(gXPF.kernelStringSection);
	if (gXPF.kernelConstSection) pfsec_free(gXPF.kernelConstSection);
	if (gXPF.kernelDataConstSection) pfsec_free(gXPF.kernelDataConstSection);
	if (gXPF.kernelDataSection) pfsec_free(gXPF.kernelDataSection);
	if (gXPF.kernelOSLogSection) pfsec_free(gXPF.kernelOSLogSection);
	if (gXPF.kernelAMFITextSection) pfsec_free(gXPF.kernelAMFITextSection);
	if (gXPF.kernelAMFIStringSection) pfsec_free(gXPF.kernelAMFIStringSection);
	if (gXPF.kernelSandboxTextSection) pfsec_free(gXPF.kernelSandboxTextSection);
	if (gXPF.kernelSandboxStringSection) pfsec_free(gXPF.kernelSandboxStringSection);
	if (gXPF.kernelPrelinkTextSection) pfsec_free(gXPF.kernelPrelinkTextSection);
	if (gXPF.kernelBootdataInit) pfsec_free(gXPF.kernelBootdataInit);
	if (gXPF.kernelPLKTextSection) pfsec_free(gXPF.kernelPLKTextSection);
	if (gXPF.kernelInfoPlistSection) pfsec_free(gXPF.kernelInfoPlistSection);
	if (gXPF.kernelContainer) fat_free(gXPF.kernelContainer);

	if (gXPF.kernelVersionString) free(gXPF.kernelVersionString);
	if (gXPF.darwinVersion) free(gXPF.darwinVersion);
	if (gXPF.xnuBuild) free(gXPF.xnuBuild);
	if (gXPF.xnuPlatform) free(gXPF.xnuPlatform);
	if (gXPF.osVersion) free(gXPF.osVersion);
	if (gXPF.kernelInfoPlist) free(gXPF.kernelInfoPlist);

	XPFItem *item = gXPF.firstItem;
	while (item) {
		XPFItem *curItem = item;
		item = item->nextItem;
		free(curItem);
	}
	
	gXPF = (struct s_XPF){ 0 };
}