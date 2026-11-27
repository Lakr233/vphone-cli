#include "choma/PatchFinder.h"
#include "xpf.h"

static uint64_t xpf_find_pmap_image4_trust_caches(void)
{
	// search pmap_is_trust_cache_loaded
	uint32_t inst[] = {
		0x39400400, // ldrb wN, [xM, #0x1]
		0x39401400, // ldrb wN, [xM, #0x5]
		0x6b00001f, // cmp wN, wM
		0x54000001, // b.ne
		0x39400800, // ldrb wN, [xM, #0x2]
		0x39401800, // ldrb wN, [xM, #0x6]
		0x6b00001f, // cmp wN, wM
		0x54000001, // b.ne
	};
	uint32_t mask[] = {
		0xff40fc00,
		0xff40fc00,
		0xffe0fc1f,
		0xff00001f,
		0xff40fc00,
		0xff40fc00,
		0xffe0fc1f,
		0xff00001f,
	};

	PFPatternMetric *metric = pfmetric_pattern_init(&inst, &mask, sizeof(inst), sizeof(uint32_t));
	__block uint64_t found = 0;
	pfmetric_run(gXPF.kernelTextSection, metric, ^(uint64_t vmaddr, bool *stop) {
		found = vmaddr;
		*stop = true;
	});
	pfmetric_free(metric);
	XPF_ASSERT(found);
	
	uint32_t adrpInst = 0, adrpInstAny = 0;
	arm64_gen_adr_p(OPT_BOOL(true), OPT_UINT64_NONE, OPT_UINT64_NONE, ARM64_REG_ANY, &adrpInst, &adrpInstAny);
	uint64_t adrpAddr = pfsec_find_prev_inst(gXPF.kernelTextSection, found, 25, adrpInst, adrpInstAny);
	XPF_ASSERT(adrpAddr);

	return pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.kernelTextSection, adrpAddr + 4);
}

static uint64_t xpf_find_trust_cache_rt(void)
{
	PFStringMetric *stringMetric = pfmetric_string_init("unexpected size for TrustCache property: %u != %zu @%s:%d");
	__block uint64_t non_ppl_trust_cache_rt_stringAddr = 0;
	pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop){
		non_ppl_trust_cache_rt_stringAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);
	XPF_ASSERT(non_ppl_trust_cache_rt_stringAddr);
	
	PFXrefMetric *xrefMetric = pfmetric_xref_init(non_ppl_trust_cache_rt_stringAddr, XREF_TYPE_MASK_REFERENCE);
	__block uint64_t non_ppl_trust_cache_rt = 0;
	pfmetric_run(gXPF.kernelTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop) {
		non_ppl_trust_cache_rt = pfsec_find_function_start(gXPF.kernelTextSection, vmaddr);
		*stop = true;
	});
	pfmetric_free(xrefMetric);
	XPF_ASSERT(non_ppl_trust_cache_rt);
	
	// 2nd adrp
	uint32_t adrpInst = 0, adrpInstAny = 0;
	arm64_gen_adr_p(OPT_BOOL(true), OPT_UINT64_NONE, OPT_UINT64_NONE, ARM64_REG_ANY, &adrpInst, &adrpInstAny);
	
	uint64_t toCheck = non_ppl_trust_cache_rt;
	uint64_t adrpAddr = 0;
	for (int i = 0; i < 2; i++) {
		adrpAddr = pfsec_find_next_inst(gXPF.kernelTextSection, toCheck, 80, adrpInst, adrpInstAny);
		toCheck = adrpAddr + 4;
	}
	XPF_ASSERT(adrpAddr);
	
	return pfsec_read_pointer(gXPF.kernelDataConstSection, pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.kernelTextSection, adrpAddr + 4));
}

static uint64_t xpf_find_pmap_tt_deallocate(void)
{
	PFStringMetric *stringMetric = pfmetric_string_init("pmap_tt_deallocate(): ptdp %p, count %d @%s:%d");
	__block uint64_t pmap_tt_deallocate_stringAddr = 0;
	pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop){
		pmap_tt_deallocate_stringAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);

	if (!pmap_tt_deallocate_stringAddr) {
		stringMetric = pfmetric_string_init("\"pmap_tt_deallocate(): ptdp %p, count %d\\n\"");
		pmap_tt_deallocate_stringAddr = 0;
		pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop) {
			pmap_tt_deallocate_stringAddr = vmaddr;
			*stop = true;
		});
		pfmetric_free(stringMetric);
	}

	XPF_ASSERT(pmap_tt_deallocate_stringAddr);
	
	PFXrefMetric *xrefMetric = pfmetric_xref_init(pmap_tt_deallocate_stringAddr, XREF_TYPE_MASK_REFERENCE);
	__block uint64_t pmap_tt_deallocate = 0;
	pfmetric_run(gXPF.kernelTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop) {
		pmap_tt_deallocate = pfsec_find_function_start(gXPF.kernelTextSection, vmaddr);
		*stop = true;
	});
	pfmetric_free(xrefMetric);

	return pmap_tt_deallocate;
}

static uint64_t xpf_find_pmap_tt_deallocate_reference(uint32_t n)
{
	uint64_t pmap_tt_deallocate = xpf_item_resolve("kernelSymbol.pmap_tt_deallocate");
	XPF_ASSERT(pmap_tt_deallocate);
	
	uint32_t blAny = 0, blAnyMask = 0;
	arm64_gen_b_l(OPT_BOOL(true), OPT_UINT64_NONE, OPT_UINT64_NONE, &blAny, &blAnyMask);
	
	uint64_t toCheck = pmap_tt_deallocate;
	uint64_t blAddr = 0;
	for (int i = 0; i < 2; i++) {
		blAddr = pfsec_find_next_inst(gXPF.kernelTextSection, toCheck, 80, blAny, blAnyMask);
		toCheck = blAddr - 12;
	}
	XPF_ASSERT(blAddr);
	
	uint32_t adrpInst = 0, adrpInstAny = 0;
	arm64_gen_adr_p(OPT_BOOL(true), OPT_UINT64_NONE, OPT_UINT64_NONE, ARM64_REG_ANY, &adrpInst, &adrpInstAny);
	
	toCheck = blAddr;
	uint64_t adrpAddr = 0;
	for (int i = 0; i < n; i++) {
		adrpAddr = pfsec_find_next_inst(gXPF.kernelTextSection, toCheck, 80, adrpInst, adrpInstAny);
		toCheck = adrpAddr + 4;
	}
	XPF_ASSERT(adrpAddr);
	
	return pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.kernelTextSection, adrpAddr + 4);
}

static uint64_t xpf_find_pmap_enter_options_addr(void)
{
	__block uint64_t stringAddr = 0;

	PFStringMetric *stringMetric = pfmetric_string_init("pmap_enter_options_internal");
	pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop) {
		stringAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);

	if (!stringAddr) {
		stringMetric = pfmetric_string_init("\"pmap_enter_options() pmap %p v 0x%llx\\n\"");
		pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop) {
			stringAddr = vmaddr;
			*stop = true;
		});
		pfmetric_free(stringMetric);
	}
	XPF_ASSERT(stringAddr);

	__block uint64_t pmap_enter_options_internal = 0;
	PFXrefMetric *xrefMetric = pfmetric_xref_init(stringAddr, XREF_TYPE_MASK_REFERENCE);
	pfmetric_run(gXPF.kernelTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop) {
		pmap_enter_options_internal = pfsec_find_function_start(gXPF.kernelTextSection, vmaddr);
		*stop = true;
	});
	pfmetric_free(xrefMetric);

	// On arm64, pmap_enter_options_internal is equivalent to pmap_enter_options_addr
	return pmap_enter_options_internal;
}

static uint64_t xpf_find_pmap_remove_options(void)
{
	__block uint64_t stringAddr = 0;

	PFStringMetric *stringMetric = pfmetric_string_init("pmap_remove_options_internal");
	pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop) {
		stringAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);
	XPF_ASSERT(stringAddr);

	__block uint64_t pmap_remove_options_internal = 0;
	PFXrefMetric *xrefMetric = pfmetric_xref_init(stringAddr, XREF_TYPE_MASK_REFERENCE);
	pfmetric_run(gXPF.kernelTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop) {
		pmap_remove_options_internal = pfsec_find_function_start(gXPF.kernelTextSection, vmaddr);
		*stop = true;
	});
	pfmetric_free(xrefMetric);

	// On arm64, pmap_remove_options_internal is equivalent to pmap_remove_options
	return pmap_remove_options_internal;
}

// TODO
static uint64_t xpf_find_vm_last_phys(void)
{
	return 0xFFFFFF8000000000;
}

static uint64_t xpf_find_pp_attr_table(void)
{
	return 0xFFFFFF8000000000;
}

void xpf_non_ppl_init(void)
{
	if (!gXPF.kernelIsArm64e) {
		bool iOS14 = strcmp(gXPF.darwinVersion, "21.0.0") < 0;
		xpf_item_register("kernelSymbol.pmap_tt_deallocate", xpf_find_pmap_tt_deallocate, NULL);
		xpf_item_register("kernelSymbol.vm_first_phys", xpf_find_pmap_tt_deallocate_reference, iOS14 ? (void*)(uint32_t)2 : (void*)(uint32_t)1);
		xpf_item_register("kernelSymbol.pv_head_table", xpf_find_pmap_tt_deallocate_reference, iOS14 ? (void*)(uint32_t)1 : (void*)(uint32_t)2);
		
		xpf_item_register("kernelSymbol.vm_last_phys", xpf_find_vm_last_phys, NULL);
		xpf_item_register("kernelSymbol.pp_attr_table", xpf_find_pp_attr_table, NULL);
		
		xpf_item_register("kernelSymbol.pmap_enter_options_addr", xpf_find_pmap_enter_options_addr, NULL);
		xpf_item_register("kernelSymbol.pmap_remove_options", xpf_find_pmap_remove_options, NULL);

		if (strcmp(gXPF.darwinVersion, "22.0.0") >= 0) {
			// iOS >=16
			xpf_item_register("kernelSymbol.ppl_trust_cache_rt", xpf_find_trust_cache_rt, NULL);
		}
		else {
			// iOS <=15
			xpf_item_register("kernelSymbol.pmap_image4_trust_caches", xpf_find_pmap_image4_trust_caches, NULL);
		}
	}
}
