#import "sptm_txm.h"
#import "xpf.h"
#include <choma/arm64.h>
#include <choma/PatchFinder.h>

static uint64_t xpf_find_sptm_args(void)
{
	PFStringMetric *stringMetric = pfmetric_string_init("Debug Header address: %p\n");
	__block uint64_t debugHeaderAddressStringAddr = 0;
	pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop) {
		debugHeaderAddressStringAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);
	XPF_ASSERT(debugHeaderAddressStringAddr);

	PFXrefMetric *xrefMetric = pfmetric_xref_init(debugHeaderAddressStringAddr, XREF_TYPE_MASK_REFERENCE);
	__block uint64_t debugHeaderAddressStringXrefAddr = 0;
	pfmetric_run(gXPF.kernelTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop){
		debugHeaderAddressStringXrefAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(xrefMetric);
	XPF_ASSERT(debugHeaderAddressStringXrefAddr);

	uint32_t adrpAnyInst = 0, adrpAnyMask = 0;
	arm64_gen_adr_p(OPT_BOOL(true), OPT_UINT64_NONE, OPT_UINT64_NONE, ARM64_REG_ANY, &adrpAnyInst, &adrpAnyMask);

	uint64_t adrpAddr = pfsec_find_prev_inst(gXPF.kernelTextSection, debugHeaderAddressStringXrefAddr - 4, 20, adrpAnyInst, adrpAnyMask);
	XPF_ASSERT(adrpAddr);

	arm64_register addrReg;
	arm64_dec_adr_p(pfsec_read32(gXPF.kernelTextSection, adrpAddr), adrpAddr, NULL, &addrReg, NULL);

	uint32_t ldrInst = 0, ldrMask = 0;
	arm64_gen_ldr_imm(0, LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, addrReg, OPT_UINT64_NONE, &ldrInst, &ldrMask);

	uint64_t ldrAddr = pfsec_find_next_inst(gXPF.kernelTextSection, adrpAddr, 20, ldrInst, ldrMask);
	XPF_ASSERT(ldrAddr);

	return pfsec_arm64_resolve_adrp_ldr_str_add_reference(gXPF.kernelTextSection, adrpAddr, ldrAddr);
}

static uint64_t xpf_find_sptm_get_page_table_refcnt(void)
{
	PFStringMetric *stringMetric = pfmetric_string_init("sptm_get_page_table_refcnt");
	__block uint64_t sptm_get_page_table_refcnt_stringAddr = 0;
	pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop){
		sptm_get_page_table_refcnt_stringAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);
	XPF_ASSERT(sptm_get_page_table_refcnt_stringAddr);

	PFXrefMetric *stringXrefMetric = pfmetric_xref_init(sptm_get_page_table_refcnt_stringAddr, XREF_TYPE_MASK_REFERENCE);
	__block uint64_t sptm_get_page_table_refcnt_stringXref = 0;
	pfmetric_run(gXPF.kernelTextSection, stringXrefMetric, ^(uint64_t vmaddr, bool *stop) {
		sptm_get_page_table_refcnt_stringXref = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringXrefMetric);
	XPF_ASSERT(sptm_get_page_table_refcnt_stringXref);

	__block uint64_t beforeBlAddr = sptm_get_page_table_refcnt_stringXref;
	PFXrefMetric *jumpXrefMetric = pfmetric_xref_init(sptm_get_page_table_refcnt_stringXref - 0x10, XREF_TYPE_MASK_JUMP);
	pfmetric_run(gXPF.kernelTextSection, jumpXrefMetric, ^(uint64_t vmaddr, bool *stop) {
		beforeBlAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(jumpXrefMetric);
	XPF_ASSERT(beforeBlAddr);

	uint32_t blAnyInst = 0, blAnyMask = 0;
	arm64_gen_b_l(OPT_BOOL(true), OPT_UINT64_NONE, OPT_UINT64_NONE, &blAnyInst, &blAnyMask);
	uint64_t blAddr = pfsec_find_prev_inst(gXPF.kernelTextSection, beforeBlAddr, 10, blAnyInst, blAnyMask);
	XPF_ASSERT(blAddr);

	uint64_t sptm_get_page_table_refcnt = 0;
	arm64_dec_b_l(pfsec_read32(gXPF.kernelTextSection, blAddr), blAddr, &sptm_get_page_table_refcnt, NULL);
	return sptm_get_page_table_refcnt;
}

static uint64_t xpf_find_sptm_get_page_table_refcnt_references(uint32_t idx)
{
	uint64_t sptm_get_page_table_refcnt = xpf_item_resolve("kernelSymbol.sptm_get_page_table_refcnt");
	XPF_ASSERT(sptm_get_page_table_refcnt);
	
	uint32_t ldrAnyInst = 0, ldrAnyMask = 0;
	arm64_gen_ldr_imm(0, LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, ARM64_REG_ANY, OPT_UINT64_NONE, &ldrAnyInst, &ldrAnyMask);

	__block uint64_t ref = 0;
	__block uint32_t f = 0;
	PFPatternMetric *metric = pfmetric_pattern_init(&ldrAnyInst, &ldrAnyMask, sizeof(ldrAnyInst), sizeof(uint32_t));
	pfmetric_run_in_range(gXPF.kernelTextSection, sptm_get_page_table_refcnt, -1, metric, ^(uint64_t vmaddr, bool *stop) {
		if (f == idx) {
			ref = pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.kernelTextSection, vmaddr);
			*stop = true;
		}
		f++;
	});

	return ref;
}

static uint64_t xpf_find_libsptm_frame_type_params(void)
{
	uint64_t sptm_get_page_table_refcnt = xpf_item_resolve("kernelSymbol.sptm_get_page_table_refcnt");
	XPF_ASSERT(sptm_get_page_table_refcnt);

	// ldrb w?, [x?, 1]
	uint32_t ldrb1Inst = 0, ldrb1Mask = 0;
	arm64_gen_ldr_imm('b', LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, ARM64_REG_ANY, OPT_UINT64(1), &ldrb1Inst, &ldrb1Mask);
	uint64_t ldrb1Addr = pfsec_find_next_inst(gXPF.kernelTextSection, sptm_get_page_table_refcnt, 0x100, ldrb1Inst, ldrb1Mask);
	XPF_ASSERT(ldrb1Addr != 0);

	uint32_t ldrAnyInst = 0, ldrAnyMask = 0;
	arm64_gen_ldr_imm(0, LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, ARM64_REG_ANY, OPT_UINT64_NONE, &ldrAnyInst, &ldrAnyMask);

	uint64_t ldrAddr = pfsec_find_prev_inst(gXPF.kernelTextSection, ldrb1Addr - 4, 10, ldrAnyInst, ldrAnyMask);
	XPF_ASSERT(ldrAddr);

	return pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.kernelTextSection, ldrAddr);
}

static uint64_t xpf_find_sptm_frame_type_descriptor_size(void)
{
	uint64_t libsptm_frame_type_paramsAddr = xpf_item_resolve("kernelSymbol.libsptm_frame_type_params");

	__block uint64_t descriptorSize = 0;
	PFXrefMetric *xrefMetric = pfmetric_xref_init(libsptm_frame_type_paramsAddr, XREF_TYPE_MASK_REFERENCE);
	pfmetric_run(gXPF.kernelTextSection, xrefMetric, ^(uint64_t xrefAddr, bool *stop) {
		// ldrb w?, [x?, 1]
		uint32_t ldrb1Inst = 0, ldrb1Mask = 0;
		arm64_gen_ldr_imm('b', LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, ARM64_REG_ANY, OPT_UINT64(1), &ldrb1Inst, &ldrb1Mask);
		uint64_t ldrb1Addr = pfsec_find_next_inst(gXPF.kernelTextSection, xrefAddr, 5, ldrb1Inst, ldrb1Mask);

		arm64_register ldrb1SourceReg;
		arm64_dec_ldr_imm(pfsec_read32(gXPF.kernelTextSection, ldrb1Addr), NULL, &ldrb1SourceReg, NULL, NULL, NULL);

		uint64_t instInBetween = ((ldrb1Addr - xrefAddr) / sizeof(uint32_t)) - 1;
		if (instInBetween == 2) {
			arm64_register firstAddDstReg, firstAddSourceReg, firstAddShiftReg;
			arm64_register secondAddDstReg, secondAddSourceReg, secondAddShiftReg;
			arm64_shift_type firstAddShiftType, secondAddShiftType;
			uint64_t firstAddShiftImm = 0, secondAddShiftImm = 0;
			if (arm64_dec_add_shift_reg(pfsec_read32(gXPF.kernelTextSection, xrefAddr + 4), &firstAddDstReg, &firstAddSourceReg, &firstAddShiftReg, &firstAddShiftType, &firstAddShiftImm) == 0 && 
				arm64_dec_add_shift_reg(pfsec_read32(gXPF.kernelTextSection, xrefAddr + 8), &secondAddDstReg, &secondAddSourceReg, &secondAddShiftReg, &secondAddShiftType, &secondAddShiftImm) == 0) {
				// On some devices on iOS 27.0+
				
				// Make sure this makes sense:
				// add  x[a], x[b], x[b], LSL#?
				// add  x[c], x[?], x[a], LSL#?
				// ldrb x[?], [x[c], 1]

				if (ARM64_REG_GET_NUM(firstAddDstReg) == ARM64_REG_GET_NUM(secondAddShiftReg) &&   // a
					ARM64_REG_GET_NUM(firstAddSourceReg) == ARM64_REG_GET_NUM(firstAddShiftReg) && // b
					ARM64_REG_GET_NUM(secondAddDstReg) == ARM64_REG_GET_NUM(ldrb1SourceReg) &&     // c
					firstAddShiftType == ARM64_SHIFT_TYPE_LSL &&
					secondAddShiftType == ARM64_SHIFT_TYPE_LSL) {
					// Decode assuming "x[b] = 1"
					descriptorSize = ((1 + (1 << firstAddShiftImm)) << secondAddShiftImm);
					*stop = true;
				}
			}
			else {
				// If the pattern above doesn't exist, we assume it's the other one
				// mov    w[a], #<size>
				// umaddl x[b], w[?], w[a], x[?]
				// ldrb   x[?], [x[b], 1]

				arm64_dec_mov_imm(pfsec_read32(gXPF.kernelTextSection, xrefAddr + 4), NULL, &descriptorSize, NULL, NULL);
				if (descriptorSize) {
					*stop = true;
				}
			}
		}		
	});
	pfmetric_free(xrefMetric);

	return descriptorSize;
}

static uint64_t xpf_find_libsptm_frame_table(void)
{
	uint64_t sptm_get_page_table_refcnt = xpf_item_resolve("kernelSymbol.sptm_get_page_table_refcnt");
	XPF_ASSERT(sptm_get_page_table_refcnt);

	// iOS 18+
	uint32_t instructions[] = {
		0xd34efc00, // lsr x?, x?, #0xe
		0x8b001000, // add x?, x?, x?, LSL#4
	};
	uint32_t masks[] = {
		0xfffffc00,
		0xffe0fc00,
	};

	__block uint64_t afterLdrAddr = 0;
	PFPatternMetric *patternMetric = pfmetric_pattern_init(instructions, masks, sizeof(instructions), sizeof(uint32_t));
	pfmetric_run_in_range(gXPF.kernelTextSection, sptm_get_page_table_refcnt, sptm_get_page_table_refcnt + 0x100, patternMetric, ^(uint64_t vmaddr, bool *stop){
		afterLdrAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(patternMetric);
	if (!afterLdrAddr) {
		// iOS 17
		uint32_t instructions2[] = {
			0xd34afc00, // lsr x?, x?, #0xa
			0x927cc400, // and x?, x?, #0x3ffffffffffff0
			0x8b000000, // add x?, x?, x?
		};
		uint32_t masks2[] = {
			0xfffffc00,
			0xfffffc00,
			0xffe0fc00
		};

		patternMetric = pfmetric_pattern_init(instructions2, masks2, sizeof(instructions2), sizeof(uint32_t));
		pfmetric_run_in_range(gXPF.kernelTextSection, sptm_get_page_table_refcnt, sptm_get_page_table_refcnt + 0x100, patternMetric, ^(uint64_t vmaddr, bool *stop){
			afterLdrAddr = vmaddr;
			*stop = true;
		});
		pfmetric_free(patternMetric);
	}
	XPF_ASSERT(afterLdrAddr);

	uint32_t ldrAnyInst = 0, ldrAnyMask = 0;
	arm64_gen_ldr_imm(0, LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, ARM64_REG_ANY, OPT_UINT64_NONE, &ldrAnyInst, &ldrAnyMask);

	uint64_t ldrAddr = pfsec_find_prev_inst(gXPF.kernelTextSection, afterLdrAddr, 10, ldrAnyInst, ldrAnyMask);
	XPF_ASSERT(ldrAddr);

	return pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.kernelTextSection, ldrAddr);
}

static uint64_t xpf_find_pmap_enter_pv(void)
{
	PFStringMetric *stringMetric = pfmetric_string_init("%s: unexpected pmap_enter_pv ret code: %d. new_pve_p=%p pmap=%p @%s:%d");
	__block uint64_t pmap_enter_pv_errStringAddr = 0;
	pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop){
		pmap_enter_pv_errStringAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);
	XPF_ASSERT(pmap_enter_pv_errStringAddr);

	PFXrefMetric *stringXrefMetric = pfmetric_xref_init(pmap_enter_pv_errStringAddr, XREF_TYPE_MASK_REFERENCE);
	__block uint64_t pmap_enter_pv_stringXref = 0;
	pfmetric_run(gXPF.kernelTextSection, stringXrefMetric, ^(uint64_t vmaddr, bool *stop) {
		pmap_enter_pv_stringXref = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringXrefMetric);
	XPF_ASSERT(pmap_enter_pv_stringXref);

	uint32_t b_lAnyInst = 0, b_lAnyMask = 0;
	arm64_gen_b_l(OPT_BOOL_NONE, OPT_UINT64_NONE, OPT_UINT64_NONE, &b_lAnyInst, &b_lAnyMask);
	__block uint64_t afterBlAddr = pmap_enter_pv_stringXref;

	uint64_t prevBlockEnd = pfsec_find_prev_inst(gXPF.kernelTextSection, pmap_enter_pv_stringXref, 16, b_lAnyInst, b_lAnyMask);
	if (prevBlockEnd != 0) {
		uint64_t thisBlockStart = prevBlockEnd + 4;
		PFXrefMetric *xrefMetric = pfmetric_xref_init(thisBlockStart, XREF_TYPE_MASK_JUMP);
		pfmetric_run(gXPF.kernelTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop) {
			afterBlAddr = vmaddr;
			*stop = true;
		});
		pfmetric_free(xrefMetric);
	}

	uint32_t blAnyInst = 0, blAnyMask = 0;
	arm64_gen_b_l(OPT_BOOL(true), OPT_UINT64_NONE, OPT_UINT64_NONE, &blAnyInst, &blAnyMask);
	uint64_t blAddr = pfsec_find_prev_inst(gXPF.kernelTextSection, afterBlAddr, 6, blAnyInst, blAnyMask);
	XPF_ASSERT(blAddr);

	uint64_t pmap_enter_pv = 0;
	arm64_dec_b_l(pfsec_read32(gXPF.kernelTextSection, blAddr), blAddr, &pmap_enter_pv, NULL);
	return pmap_enter_pv;
}

static uint64_t xpf_find_pp_attr_table(void)
{
	uint64_t pmap_enter_pv = xpf_item_resolve("kernelSymbol.pmap_enter_pv");
	XPF_ASSERT(pmap_enter_pv);

	// Find "bics wzr w? w?"
	uint64_t afterLdrAddr = pfsec_find_next_inst(gXPF.kernelTextSection, pmap_enter_pv, 50, 0x6a20001f, 0xffe0fc1f);
	XPF_ASSERT(afterLdrAddr);

	// Seek back to last ldr before the bics
	uint32_t ldrAnyInst = 0, ldrAnyMask = 0;
	int genRet = arm64_gen_ldr_imm(0, LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, ARM64_REG_ANY, OPT_UINT64_NONE, &ldrAnyInst, &ldrAnyMask);
	XPF_ASSERT(genRet == 0);

	uint64_t ldrAddr = pfsec_find_prev_inst(gXPF.kernelTextSection, afterLdrAddr, 10, ldrAnyInst, ldrAnyMask);
	XPF_ASSERT(ldrAddr);
	return pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.kernelTextSection, ldrAddr);
}

static uint64_t xpf_find_pv_alloc(void)
{
	PFStringMetric *stringMetric = pfmetric_string_init("pv_alloc");
	__block uint64_t pv_allocStringAddr = 0;
	pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop) {
		pv_allocStringAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);
	if (pv_allocStringAddr) {
		PFXrefMetric *xrefMetric = pfmetric_xref_init(pv_allocStringAddr, XREF_TYPE_MASK_REFERENCE);
		__block uint64_t pv_alloc = 0;
		pfmetric_run(gXPF.kernelTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop){
			pv_alloc = pfsec_find_function_start(gXPF.kernelTextSection, vmaddr);
			*stop = true;
		});
		return pv_alloc;
	}
	else {
		stringMetric = pfmetric_string_init("pmap_enter_pv");
		__block uint64_t pmap_enter_pv_stringAddr = 0;
		pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop) {
			pmap_enter_pv_stringAddr = vmaddr;
			*stop = true;
		});
		XPF_ASSERT(pmap_enter_pv_stringAddr != 0);
		pfmetric_free(stringMetric);

		PFXrefMetric *pmap_enter_pv_stringXrefMetric = pfmetric_xref_init(pmap_enter_pv_stringAddr, XREF_TYPE_MASK_REFERENCE);
		__block uint64_t pmap_enter_pv_stringXrefAddr = 0;
		pfmetric_run(gXPF.kernelTextSection, pmap_enter_pv_stringXrefMetric, ^(uint64_t vmaddr, bool *stop){
			pmap_enter_pv_stringXrefAddr = vmaddr;
			*stop = true;
		});
		XPF_ASSERT(pmap_enter_pv_stringXrefAddr != 0);
		pfmetric_free(pmap_enter_pv_stringXrefMetric);

		PFXrefMetric *jumpXrefMetric = pfmetric_xref_init(pmap_enter_pv_stringXrefAddr - (6 * sizeof(uint32_t)), XREF_TYPE_MASK_JUMP);
		__block uint64_t jumpAddr = 0;
		pfmetric_run(gXPF.kernelTextSection, jumpXrefMetric, ^(uint64_t vmaddr, bool *stop){
			jumpAddr = vmaddr;
			*stop = true;
		});
		XPF_ASSERT(jumpAddr != 0);
		pfmetric_free(jumpXrefMetric);

		uint32_t blAnyInst = 0, blAnyMask = 0;
		arm64_gen_b_l(OPT_BOOL(true), OPT_UINT64_NONE, OPT_UINT64_NONE, &blAnyInst, &blAnyMask);
		uint64_t blAddr = pfsec_find_next_inst(gXPF.kernelTextSection, jumpAddr, 50, blAnyInst, blAnyMask);
		XPF_ASSERT(blAddr != 0);
	
		uint64_t pv_alloc = 0;
		arm64_dec_b_l(pfsec_read32(gXPF.kernelTextSection, blAddr), blAddr, &pv_alloc, NULL);
		XPF_ASSERT(pv_alloc != 0);
		return pv_alloc;
	}
}

static uint64_t xpf_find_pv_head_table(void)
{
	// com.apple.kernel:__text:FFFFFFF027EC8024 _pv_alloc
	// ...
	// com.apple.kernel:__text:FFFFFFF027EC821C                 LDR             W8, [X26,#dword_FFFFFFF02A366E88@PAGEOFF]
	// com.apple.kernel:__text:FFFFFFF027EC8220                 CMP             W8, #0x555
	// ...
	// com.apple.kernel:__text:FFFFFFF027EC822C                 ADRP            X26, #_pv_head_table@PAGE
	// com.apple.kernel:__text:FFFFFFF027EC8230                 LDR             X8, [X26,#_pv_head_table@PAGEOFF]

	uint64_t pv_alloc = xpf_item_resolve("kernelSymbol.pv_alloc");
	XPF_ASSERT(pv_alloc);

	uint32_t instructions[] = {
		0,
		0x7115541f,
	};

	uint32_t masks[] = {
		0, 			// ldr ?, [? ?]
		0xfffffc1f, // cmp w?, 0x555
	};

	arm64_gen_ldr_imm(0, LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, ARM64_REG_ANY, OPT_UINT64_NONE, &instructions[0], &masks[0]);

	PFPatternMetric *patternMetric = pfmetric_pattern_init(instructions, masks, sizeof(instructions), sizeof(uint32_t));
	__block uint64_t beforeAdrpAddr = 0;
	pfmetric_run_in_range(gXPF.kernelTextSection, pv_alloc, -1, patternMetric, ^(uint64_t vmaddr, bool *stop){
		beforeAdrpAddr = vmaddr + 4;
		*stop = true;
	});
	pfmetric_free(patternMetric);
	XPF_ASSERT(beforeAdrpAddr);

	uint32_t adrpAnyInst = 0, adrpAnyMask = 0;
	arm64_gen_adr_p(OPT_BOOL(true), OPT_UINT64_NONE, OPT_UINT64_NONE, ARM64_REG_ANY, &adrpAnyInst, &adrpAnyMask);
	uint64_t adrpAddr = pfsec_find_next_inst(gXPF.kernelTextSection, beforeAdrpAddr, 20, adrpAnyInst, adrpAnyMask);

	arm64_register adrpDestReg;
	arm64_dec_adr_p(pfsec_read32(gXPF.kernelTextSection, adrpAddr), adrpAddr, NULL, &adrpDestReg, NULL);

	uint32_t ldrInst = 0, ldrMask = 0;
	arm64_gen_ldr_imm(0, LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, adrpDestReg, OPT_UINT64_NONE, &ldrInst, &ldrMask);
	uint64_t ldrAddr = pfsec_find_next_inst(gXPF.kernelTextSection, adrpAddr, 20, ldrInst, ldrMask);
	XPF_ASSERT(ldrAddr);

	return pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.kernelTextSection, ldrAddr);
}

static uint64_t xpf_find_wfe_timeout_configure(void)
{
	PFStringMetric *stringMetric = pfmetric_string_init("wfe_events_sec");
	__block uint64_t wfe_timeout_configureString = 0;
	pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop) {
		wfe_timeout_configureString = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);
	XPF_ASSERT(wfe_timeout_configureString);

	PFXrefMetric *xrefMetric = pfmetric_xref_init(wfe_timeout_configureString, XREF_TYPE_MASK_REFERENCE);
	__block uint64_t wfe_timeout_configure = 0;
	pfmetric_run(gXPF.kernelTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop){
		wfe_timeout_configure = pfsec_find_function_start(gXPF.kernelTextSection, vmaddr);
	});
	return wfe_timeout_configure;
}

static uint64_t xpf_find_libsptm_init(void)
{
	if (strcmp(gXPF.darwinVersion, "27.0.0") >= 0) {
		// iOS >=27.0
		// The last function in __TEXT_BOOT_EXEC:__bootcode is libsptm_init
		uint64_t bootcodeSectionEnd = gXPF.kernelBootcodeSection->info.vmaddr + gXPF.kernelBootcodeSection->info.size;
		return pfsec_find_function_start(gXPF.kernelBootcodeSection, bootcodeSectionEnd-4);
	}
	else {
		// __text:FFFFFE000745C964 _arm_init
		// ...
		// com.apple.kernel:__text:FFFFFFF0080A74D4                 BL              _libsptm_init
		// com.apple.kernel:__text:FFFFFFF0080A74D8                 CBNZ            W0, loc_FFFFFFF0080A7B68
		// com.apple.kernel:__text:FFFFFFF0080A74DC                 MSR             ACNTRDIR_EL21, XZR
		// com.apple.kernel:__text:FFFFFFF0080A74E0                 MOV             W8, #3
		// com.apple.kernel:__text:FFFFFFF0080A74E4                 MSR             ACNTRDIR_EL12, X8
		// com.apple.kernel:__text:FFFFFFF0080A74E8                 ISB
		// com.apple.kernel:__text:FFFFFFF0080A74EC                 BL              _wfe_timeout_configure
		// We get wfe_timeout_configure, find the xref to it and seek back to the previous BL to find libsptm_init

		uint64_t wfe_timeout_configure = xpf_item_resolve("kernelSymbol.wfe_timeout_configure");
		XPF_ASSERT(wfe_timeout_configure);

		__block uint64_t wfe_timeout_configureXrefAddr = 0;
		PFXrefMetric *xrefMetric = pfmetric_xref_init(wfe_timeout_configure, XREF_TYPE_MASK_CALL);
		pfmetric_run(gXPF.kernelTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop){
			wfe_timeout_configureXrefAddr = vmaddr;
			*stop = true;
		});
		XPF_ASSERT(wfe_timeout_configureXrefAddr);

		uint32_t blAnyInst = 0, blAnyMask = 0;
		arm64_gen_b_l(OPT_BOOL_NONE, OPT_UINT64_NONE, OPT_UINT64_NONE, &blAnyInst, &blAnyMask);
		uint64_t blAddr = pfsec_find_prev_inst(gXPF.kernelTextSection, wfe_timeout_configureXrefAddr, 20, blAnyInst, blAnyMask);
		XPF_ASSERT(blAddr);

		uint64_t libsptm_init = 0;
		arm64_dec_b_l(pfsec_read32(gXPF.kernelTextSection, blAddr), blAddr, &libsptm_init, NULL);
		return libsptm_init;
	}
}

static uint64_t xpf_find_libsptm_init_str_reference(uint32_t idx)
{
	PFSection *textSection = gXPF.kernelTextSection;
	if (strcmp(gXPF.darwinVersion, "27.0.0") >= 0) {
		textSection = gXPF.kernelBootcodeSection;
	}

	uint64_t libsptm_init = xpf_item_resolve("kernelSymbol.libsptm_init");
	XPF_ASSERT(libsptm_init);

	uint32_t strAnyInst = 0, strAnyMask = 0;
	arm64_gen_str_imm(0, LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, ARM64_REG_ANY, OPT_UINT64_NONE, &strAnyInst, &strAnyMask);

	PFPatternMetric *metric = pfmetric_pattern_init(&strAnyInst, &strAnyMask, sizeof(strAnyInst), sizeof(uint32_t));
	__block uint64_t ref = 0;
	__block uint32_t i = 0;
	pfmetric_run_in_range(textSection, libsptm_init, -1, metric, ^(uint64_t vmaddr, bool *stop){
		if (i == idx) {
			ref = pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(textSection, vmaddr);
			*stop = true;
		}
		i++;
	});
	pfmetric_free(metric);

	return ref;
}

static uint64_t xpf_find_cpu_ttep(void)
{
	uint64_t start_first_cpu = xpf_item_resolve("kernelSymbol.arm_vm_init");
	XPF_ASSERT(start_first_cpu);

	uint32_t blAnyInst = 0, blAnyMask = 0;
	arm64_gen_b_l(OPT_BOOL(true), OPT_UINT64_NONE, OPT_UINT64_NONE, &blAnyInst, &blAnyMask);

	uint64_t blSptmPhytokvAddr = pfsec_find_next_inst(gXPF.kernelTextSection, start_first_cpu, 0, blAnyInst, blAnyMask);

	uint32_t strAnyInst = 0, strAnyMask = 0;
	arm64_gen_str_imm(0, LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, ARM64_REG_ANY, OPT_UINT64_NONE, &strAnyInst, &strAnyMask);

	uint64_t strAddr = blSptmPhytokvAddr;
	while ((strAddr = pfsec_find_prev_inst(gXPF.kernelTextSection, strAddr, 0, strAnyInst, strAnyMask))) {
		arm64_register reg;
		arm64_dec_str_imm(pfsec_read32(gXPF.kernelTextSection, strAddr), NULL, &reg, NULL, NULL, NULL);
		if (ARM64_REG_GET_NUM(reg) != ARM64_REG_NUM_SP) {
			break;
		}
	}

	return pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.kernelTextSection, strAddr);
}

static uint64_t xpf_find_txm_deviceTreeTrustCacheRange(void)
{
	__block uint64_t chosenMemoryMapStringAddr = 0;
	PFStringMetric *stringMetric = pfmetric_string_init("/chosen/memory-map");
	pfmetric_run(gXPF.txmStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop){
		chosenMemoryMapStringAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);
	XPF_ASSERT(chosenMemoryMapStringAddr);

	__block uint64_t deviceTreeTrustCacheRangeAddr = 0;
	PFXrefMetric *xrefMetric = pfmetric_xref_init(chosenMemoryMapStringAddr, XREF_TYPE_MASK_REFERENCE);
	pfmetric_run(gXPF.txmTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop){
		deviceTreeTrustCacheRangeAddr = pfsec_find_function_start(gXPF.txmTextSection, vmaddr);
		*stop = true;
	});
	pfmetric_free(xrefMetric);

	return deviceTreeTrustCacheRangeAddr;
}

static uint64_t xpf_find_txm_trustcache_root(void)
{
	// (17.0.2, iPhone 15)
	// __text:FFFFFFF01701D3E4                 STRB            WZR, [X26,#(txm_trustcache_root+0xA - 0xFFFFFFF017010420)] (2)
	// (...)
	// __text:FFFFFFF01701D3F0                 STR             X8, [X26,#(txm_trustcache_root - 0xFFFFFFF017010420)] (3)
	// __text:FFFFFFF01701D3F4                 BL              _deviceTreeTrustCacheRange (1)

	// (18.5, iPhone 15)
	// __text:FFFFFFF017021CDC                 STRB            WZR, [X22,#(txm_trustcache_root+0xA - 0xFFFFFFF0170104E8)] (2)
	// __text:FFFFFFF017021CE0                 STR             X19, [X22,#(txm_trustcache_root - 0xFFFFFFF0170104E8)] (3)
	// __text:FFFFFFF017021CE4                 TBZ             W0, #0, loc_FFFFFFF017021D20
	// (...)
	// __text:FFFFFFF017021D20 loc_FFFFFFF017021D20                    ; CODE XREF: _setupTrustCaches+CC↑j
	// __text:FFFFFFF017021D20                 BL              _deviceTreeTrustCacheRange (1)

	uint64_t txm_deviceTreeTrustCacheRangeAddr = xpf_item_resolve("kernelSymbol.txm_deviceTreeTrustCacheRange");

	// Find xref to _deviceTreeTrustCacheRange (1)
	__block uint64_t txm_deviceTreeTrustCacheRangeCallerAddr = 0;
	PFXrefMetric *xrefMetric = pfmetric_xref_init(txm_deviceTreeTrustCacheRangeAddr, XREF_TYPE_MASK_CALL);
	pfmetric_run(gXPF.txmTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop){
		txm_deviceTreeTrustCacheRangeCallerAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(xrefMetric);
	XPF_ASSERT(txm_deviceTreeTrustCacheRangeCallerAddr);

	// TODO: we could try to check if there is a jump to txm_deviceTreeTrustCacheRangeCallerAddr (18.5 case) and if so, follow it
	
	// Seek back to find "strb wzr, [x?, ?]" (2)
	uint32_t strbWzrAnyInst = 0, strbWzrAnyMask = 0;
	arm64_gen_str_imm('b', LDR_STR_TYPE_UNSIGNED, ARM64_REG_W(ARM64_REG_NUM_ZR), ARM64_REG_ANY, OPT_UINT64_NONE, &strbWzrAnyInst, &strbWzrAnyMask);

	uint64_t strWzrAnyAddr = pfsec_find_prev_inst(gXPF.txmTextSection, txm_deviceTreeTrustCacheRangeCallerAddr, 100, strbWzrAnyInst, strbWzrAnyMask);
	XPF_ASSERT(strWzrAnyAddr);

	// Now, seek forward to the next normal str (3)
	uint32_t strAnyInst = 0, strAnyMask = 0;
	arm64_gen_str_imm(0, LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, ARM64_REG_ANY, OPT_UINT64_NONE, &strAnyInst, &strAnyMask);
	uint64_t strAddr = pfsec_find_next_inst(gXPF.txmTextSection, strWzrAnyAddr + sizeof(uint32_t), 10, strAnyInst, strAnyMask);
	XPF_ASSERT(strAddr);

	return pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.txmTextSection, strAddr);
}

static uint64_t xpf_find_txm_developer_mode_storage(void)
{
	// Case 1: (17.0.1, iPhone 15)
	// __text:FFFFFFF01701B0B0                 LDRB            W8, [X8,#(txm_developer_mode_storage - 0xFFFFFFF017058160)]
	// __text:FFFFFFF01701B0B4                 TBNZ            W8, #0, loc_FFFFFFF01701B0C0
	// __text:FFFFFFF01701B0B8                 MOV             W20, #0x1B
	// __text:FFFFFFF01701B0BC                 B               loc_FFFFFFF01701B14C
	// __text:FFFFFFF01701B0C0 ; ---------------------------------------------------------------------------
	// __text:FFFFFFF01701B0C0
	// __text:FFFFFFF01701B0C0 loc_FFFFFFF01701B0C0                    ; CODE XREF: sub_FFFFFFF01701B080+24↑j
	// __text:FFFFFFF01701B0C0                                         ; sub_FFFFFFF01701B080+34↑j
	// __text:FFFFFFF01701B0C0                 ADR             X1, aResearchComApp ; "research.com.apple.license-to-operate"

	// Case 2: (18.5, iPhone 15)
	// __text:FFFFFFF01701F550                 LDRB            W8, [X8,#(txm_developer_mode_storage - 0xFFFFFFF017064CD0)]
	// __text:FFFFFFF01701F554                 CMP             W8, #1
	// __text:FFFFFFF01701F558                 B.NE            loc_FFFFFFF01701F5F0
	// __text:FFFFFFF01701F55C                 MOV             X19, X0
	// __text:FFFFFFF01701F560                 ADR             X1, aResearchComApp ; "research.com.apple.license-to-operate"

	__block uint64_t licenseToOperateStringAddr = 0;
	PFStringMetric *stringMetric = pfmetric_string_init("research.com.apple.license-to-operate");
	pfmetric_run(gXPF.txmStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop){
		licenseToOperateStringAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);
	XPF_ASSERT(licenseToOperateStringAddr);

	PFXrefMetric *xrefMetric = pfmetric_xref_init(licenseToOperateStringAddr, XREF_TYPE_MASK_REFERENCE);
	__block uint64_t licenseToOperateStringXrefAddr = 0;
	pfmetric_run(gXPF.txmTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop){
		licenseToOperateStringXrefAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(xrefMetric);
	XPF_ASSERT(licenseToOperateStringXrefAddr);

	__block uint64_t afterLdrbAddr = licenseToOperateStringXrefAddr;

	PFXrefMetric *xrefMetric2 = pfmetric_xref_init(afterLdrbAddr, XREF_TYPE_MASK_JUMP);
	pfmetric_run(gXPF.txmTextSection, xrefMetric2, ^(uint64_t vmaddr, bool *stop) {
		if (afterLdrbAddr == licenseToOperateStringXrefAddr) {
			// First iteration
			afterLdrbAddr = vmaddr;
		}
		else {
			// Find closest xref
			uint64_t curOff  = vmaddr < licenseToOperateStringXrefAddr ? licenseToOperateStringXrefAddr - vmaddr : vmaddr - licenseToOperateStringXrefAddr;
			uint64_t prevOff = afterLdrbAddr < licenseToOperateStringXrefAddr ? licenseToOperateStringXrefAddr - afterLdrbAddr : afterLdrbAddr - licenseToOperateStringXrefAddr;
			if (curOff < prevOff) {
				afterLdrbAddr = vmaddr;
			}
		}
	});
	pfmetric_free(xrefMetric2);

	uint32_t ldrbAnyInst = 0, ldrbAnyMask = 0;
	arm64_gen_ldr_imm('b', LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, ARM64_REG_ANY, OPT_UINT64_NONE, &ldrbAnyInst, &ldrbAnyMask);

	uint64_t ldrbAddr = pfsec_find_prev_inst(gXPF.txmTextSection, afterLdrbAddr, 20, ldrbAnyInst, ldrbAnyMask);
	return pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.txmTextSection, ldrbAddr);
}

uint64_t xpf_find_papt_ranges_update(void)
{
	PFStringMetric *stringMetric = pfmetric_string_init("papt_ranges_update");
	__block uint64_t stringAddr = 0;
	pfmetric_run(gXPF.sptmStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop){
		stringAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);
	XPF_ASSERT(stringAddr != 0);

	PFXrefMetric *stringXrefMetric = pfmetric_xref_init(stringAddr, XREF_TYPE_MASK_REFERENCE);
	__block uint64_t xrefAddr = 0;
	pfmetric_run(gXPF.sptmTextSection, stringXrefMetric, ^(uint64_t vmaddr, bool *stop){
		xrefAddr = vmaddr;
		*stop = true;
	});
	XPF_ASSERT(xrefAddr != 0);

	return pfsec_find_function_start(gXPF.sptmTextSection, xrefAddr);
}

int xpf_find_papt_ranges_compressed_n_papt_ranges_compressed(uint64_t *papt_ranges_compressed, uint64_t *n_papt_ranges_compressed)
{
	uint64_t papt_ranges_update = xpf_item_resolve("kernelSymbol.papt_ranges_update");
	XPF_ASSERT(papt_ranges_update);

	uint32_t searchCmpInst = 0x7100041F, searchCmpMask = 0xFFFFFC1F; // cmp w?, #1

	uint64_t cmpAddr = pfsec_find_next_inst(gXPF.sptmTextSection, papt_ranges_update, 30, searchCmpInst, searchCmpMask);
	uint64_t lastJumpTargetAddr = 0;

	uint64_t curAddr = cmpAddr;
	for (int idx = 0; idx < 50; idx++) {
		uint32_t inst = pfsec_read32(gXPF.sptmTextSection, curAddr);
		uint64_t target;
		bool isBl = false;

		arm64_register movDst;
		uint64_t movImm, movShift;

		if (arm64_dec_b_l(inst, curAddr, &target, &isBl) == 0 && !isBl) {
			lastJumpTargetAddr = target;
			curAddr = target;
			continue;
		}
		else if (arm64_dec_mov_imm(inst, &movDst, &movImm, &movShift, NULL) == 0) {
			if (ARM64_REG_GET_NUM(movDst) == 17 && movImm == 0xe4fe && movShift == 0) {
				break;
			}
		}
		curAddr += sizeof(uint32_t);
	}

	uint32_t adrAnyInst = 0, adrAnyMask = 0;
	arm64_gen_adr_p(OPT_BOOL_NONE, OPT_UINT64_NONE, OPT_UINT64_NONE, ARM64_REG_ANY, &adrAnyInst, &adrAnyMask);

	PFPatternMetric *patternMetric = pfmetric_pattern_init(&adrAnyInst, &adrAnyMask, sizeof(adrAnyInst), sizeof(uint32_t));
	__block int adrIdx = 0;
	pfmetric_run_in_range(gXPF.sptmTextSection, lastJumpTargetAddr ?: cmpAddr, curAddr, patternMetric, ^(uint64_t vmaddr, bool *stop) {
		uint32_t inst = pfsec_read32(gXPF.sptmTextSection, vmaddr);
		bool isAdrp = false;
		uint64_t target = 0;
		arm64_dec_adr_p(inst, vmaddr, &target, NULL, &isAdrp);

		if (adrIdx == 0) {
			if (n_papt_ranges_compressed) {
				if (isAdrp) {
					*n_papt_ranges_compressed = pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.sptmTextSection, vmaddr + sizeof(uint32_t));
				}
				else {
					*n_papt_ranges_compressed = target;
				}
			}
		}
		else if (adrIdx == 1) {
			if (papt_ranges_compressed) {
				if (isAdrp) {
					*papt_ranges_compressed = pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.sptmTextSection, vmaddr + sizeof(uint32_t));
				}
				else {
					*papt_ranges_compressed = target;
				}
			}
			*stop = true;
		}

		adrIdx++;
	});

	return 0;
}

uint64_t xpf_find_n_papt_ranges_compressed(void)
{
	uint64_t o = 0;
	if (xpf_find_papt_ranges_compressed_n_papt_ranges_compressed(NULL, &o) != 0) return 0;
	return o;
}

uint64_t xpf_find_papt_ranges_compressed(void)
{
	uint64_t o = 0;
	if (xpf_find_papt_ranges_compressed_n_papt_ranges_compressed(&o, NULL) != 0) return 0;
	return o;
}

uint64_t xpf_find_pmap_tte_deallocate(void)
{
	PFStringMetric *stringMetric = pfmetric_string_init("pmap_tte_deallocate");
	__block uint64_t pmap_tte_deallocate_stringAddr = 0;
	pfmetric_run(gXPF.kernelStringSection, stringMetric, ^(uint64_t vmaddr, bool *stop) {
		pmap_tte_deallocate_stringAddr = vmaddr;
		*stop = true;
	});
	pfmetric_free(stringMetric);
	XPF_ASSERT(pmap_tte_deallocate_stringAddr);

	PFXrefMetric *xrefMetric = pfmetric_xref_init(pmap_tte_deallocate_stringAddr, XREF_TYPE_MASK_REFERENCE);
	__block uint64_t pmap_tte_deallocateAddr = 0;
	pfmetric_run(gXPF.kernelTextSection, xrefMetric, ^(uint64_t vmaddr, bool *stop) {
		pmap_tte_deallocateAddr = pfsec_find_function_start(gXPF.kernelTextSection, vmaddr);
		*stop = true;
	});

	XPF_ASSERT(pmap_tte_deallocateAddr);
	return pmap_tte_deallocateAddr;
}

uint64_t xpf_find_vm_page_find_canonical_radix(void)
{
	uint64_t pmap_tte_deallocate = xpf_item_resolve("kernelSymbol.pmap_tte_deallocate");

	uint32_t subsAnyInst = 0x6b000000, subsAnyMask = 0xffe00000;

	uint32_t inst[] = {
		0x6b000000, // subs w?, w?, w?
		0,          // b.cc ?
	};
	uint32_t mask[] = {
		0xffe00000,
		0,
	};
	arm64_gen_b_c_cond(OPT_BOOL(false), OPT_UINT64_NONE, OPT_UINT64_NONE, ARM64_COND(0b0011), &inst[1], &mask[1]);

	__block uint64_t jmpDestAddr = 0;
	PFPatternMetric *patternMetric = pfmetric_pattern_init(inst, mask, sizeof(inst), sizeof(uint32_t));
	pfmetric_run_in_range(gXPF.kernelTextSection, pmap_tte_deallocate, pmap_tte_deallocate + (sizeof(uint32_t) * 0x20), patternMetric, ^(uint64_t vmaddr, bool *stop){
		uint64_t jmpAddr = (vmaddr + sizeof(uint32_t));
		arm64_dec_b_c_cond(pfsec_read32(gXPF.kernelTextSection, jmpAddr), jmpAddr, &jmpDestAddr, NULL, NULL);
		*stop = true;
	});
	XPF_ASSERT(jmpDestAddr);

	uint32_t blAnyInst = 0, blAnyMask = 0;
	arm64_gen_b_l(OPT_BOOL(true), OPT_UINT64_NONE, OPT_UINT64_NONE, &blAnyInst, &blAnyMask);
	uint64_t bl_vm_page_find_canonical_radix_Addr = pfsec_find_next_inst(gXPF.kernelTextSection, jmpDestAddr, 10, blAnyInst, blAnyMask);
	XPF_ASSERT(bl_vm_page_find_canonical_radix_Addr);

	uint64_t vm_page_find_canonical_radix = 0;
	arm64_dec_b_l(pfsec_read32(gXPF.kernelTextSection, bl_vm_page_find_canonical_radix_Addr), bl_vm_page_find_canonical_radix_Addr, &vm_page_find_canonical_radix, NULL);
	return vm_page_find_canonical_radix;
}

uint64_t xpf_find_vm_page_find_canonical_radix_ref(uint32_t idxToFind)
{
	uint64_t vm_page_find_canonical_radix = xpf_item_resolve("kernelSymbol.vm_page_find_canonical_radix");
	uint32_t maxSearch = 0x100;

	uint32_t ldrAnyInst = 0, ldrAnyMask;
	arm64_gen_ldr_imm(0, LDR_STR_TYPE_UNSIGNED, ARM64_REG_ANY, ARM64_REG_ANY, OPT_UINT64_NONE, &ldrAnyInst, &ldrAnyMask);

	uint64_t findBuf = vm_page_find_canonical_radix;
	int idx = 0;
	while (idx <= idxToFind) {
		findBuf = pfsec_find_next_inst(gXPF.kernelTextSection, findBuf + (findBuf == vm_page_find_canonical_radix ? 0 : sizeof(uint32_t)), maxSearch - ((findBuf - vm_page_find_canonical_radix) / sizeof(uint32_t)), ldrAnyInst, ldrAnyMask);
		idx++;
	}

	return pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto(gXPF.kernelTextSection, findBuf);
}

void xpf_sptm_txm_init(void)
{
	if (gXPF.kernelIsArm64e && gXPF.sptm) {
		xpf_item_register("kernelSymbol.SPTMArgs", xpf_find_sptm_args, NULL);

		xpf_item_register("kernelSymbol.sptm_get_page_table_refcnt", xpf_find_sptm_get_page_table_refcnt, NULL);
		xpf_item_register("kernelSymbol.vm_first_phys", xpf_find_sptm_get_page_table_refcnt_references, (void *)(uint32_t)1);
		xpf_item_register("kernelSymbol.vm_last_phys", xpf_find_sptm_get_page_table_refcnt_references, (void *)(uint32_t)2);
		xpf_item_register("kernelSymbol.libsptm_frame_table", xpf_find_libsptm_frame_table, NULL);
		xpf_item_register("kernelSymbol.pmap_enter_pv", xpf_find_pmap_enter_pv, NULL);
		xpf_item_register("kernelSymbol.pp_attr_table", xpf_find_pp_attr_table, NULL);
		xpf_item_register("kernelSymbol.pv_alloc", xpf_find_pv_alloc, NULL);
		xpf_item_register("kernelSymbol.pv_head_table", xpf_find_pv_head_table, NULL);

		xpf_item_register("kernelSymbol.papt_ranges_update", xpf_find_papt_ranges_update, NULL);
		xpf_item_register("kernelSymbol.n_papt_ranges_compressed", xpf_find_n_papt_ranges_compressed, NULL);
		xpf_item_register("kernelSymbol.papt_ranges_compressed", xpf_find_papt_ranges_compressed, NULL);

		// iOS 18.4+
		xpf_item_register("kernelSymbol.libsptm_frame_type_params", xpf_find_libsptm_frame_type_params, NULL);
		xpf_item_register("kernelStruct.sptm_frame_type_descriptor.struct_size", xpf_find_sptm_frame_type_descriptor_size, NULL);

		xpf_item_register("kernelSymbol.wfe_timeout_configure", xpf_find_wfe_timeout_configure, NULL);
		xpf_item_register("kernelSymbol.libsptm_init", xpf_find_libsptm_init, NULL);
		xpf_item_register("kernelSymbol.libsptm_n_papt_ranges", xpf_find_libsptm_init_str_reference, (void *)(uint32_t)0);
		xpf_item_register("kernelSymbol.libsptm_papt_ranges", xpf_find_libsptm_init_str_reference, (void *)(uint32_t)1);

		xpf_item_register("kernelSymbol.cpu_ttep", xpf_find_cpu_ttep, NULL);

		xpf_item_register("kernelSymbol.txm_deviceTreeTrustCacheRange", xpf_find_txm_deviceTreeTrustCacheRange, NULL);
		xpf_item_register("kernelSymbol.txm_trustcache_root", xpf_find_txm_trustcache_root, NULL);
		xpf_item_register("kernelSymbol.txm_developer_mode_storage", xpf_find_txm_developer_mode_storage, NULL);

		// 27.0+
		xpf_item_register("kernelSymbol.pmap_tte_deallocate", xpf_find_pmap_tte_deallocate, NULL);
		xpf_item_register("kernelSymbol.vm_page_find_canonical_radix", xpf_find_vm_page_find_canonical_radix, NULL);
		xpf_item_register("kernelSymbol.pmap_first_pnum", xpf_find_vm_page_find_canonical_radix_ref, (void *)(uint32_t)0);
		xpf_item_register("kernelSymbol.vm_pages_radix_root", xpf_find_vm_page_find_canonical_radix_ref, (void *)(uint32_t)1);
	}
}