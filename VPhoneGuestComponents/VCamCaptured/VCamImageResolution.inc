// MARK: - runtime image resolution

#define VCC_MAX_DATA_RANGES 8

typedef struct {
  uintptr_t start;
  uintptr_t end;
} vcc_range_t;

typedef struct {
  const struct mach_header_64 *mh;
  intptr_t slide;
  const uint32_t *text;
  size_t text_words;  // count of 4-byte instructions
  vcc_range_t data_ranges[VCC_MAX_DATA_RANGES];
  unsigned data_range_count;
  // LC_SYMTAB pointers (may be 0 on DSC dylibs that strip private symbols
  // from the per-image symtab; callers must handle gracefully).
  const struct nlist_64 *symtab;
  const char *strtab;
  uint32_t nsyms;
} vcc_image_t;

static int vcc_image_resolve(vcc_image_t *out, const char *anchor_sym) {
  memset(out, 0, sizeof(*out));
  void *anchor = dlsym(RTLD_DEFAULT, anchor_sym);
  if (!anchor) return -1;
  void *stripped = ptrauth_strip(anchor, ptrauth_key_function_pointer);
  Dl_info info;
  if (!dladdr(stripped, &info) || !info.dli_fbase) return -2;
  const struct mach_header_64 *mh =
      (const struct mach_header_64 *)info.dli_fbase;
  if (mh->magic != MH_MAGIC_64) return -3;
  out->mh = mh;

  uint32_t cnt = _dyld_image_count();
  for (uint32_t i = 0; i < cnt; i++) {
    if (_dyld_get_image_header(i) == (const struct mach_header *)mh) {
      out->slide = _dyld_get_image_vmaddr_slide(i);
      break;
    }
  }

  unsigned long sz = 0;
  uint8_t *text =
      getsectiondata((struct mach_header_64 *)mh, "__TEXT", "__text", &sz);
  if (!text || sz < 8) return -4;
  out->text = (const uint32_t *)text;
  out->text_words = sz / 4;

  // Capture bounds of every writable segment so the structural scan can
  // reject candidate targets that don't fall within a data segment.
  // Also stash the LC_SYMTAB pointers for later private-symbol lookups.
  const struct load_command *lc = (const struct load_command *)(mh + 1);
  const struct segment_command_64 *linkedit = NULL;
  const struct symtab_command *symtab_cmd = NULL;
  for (uint32_t i = 0; i < mh->ncmds; i++) {
    if (lc->cmd == LC_SEGMENT_64) {
      const struct segment_command_64 *seg =
          (const struct segment_command_64 *)lc;
      if (strcmp(seg->segname, "__LINKEDIT") == 0) {
        linkedit = seg;
      }
      // Skip __TEXT, __LINKEDIT — only consider writable/data segments.
      // segname comparisons are sufficient; __PAGEZERO has vmaddr 0 anyway.
      if (strcmp(seg->segname, "__TEXT") != 0 &&
          strcmp(seg->segname, "__LINKEDIT") != 0 &&
          strcmp(seg->segname, "__PAGEZERO") != 0 &&
          seg->vmsize > 0 &&
          out->data_range_count < VCC_MAX_DATA_RANGES) {
        uintptr_t start = (uintptr_t)seg->vmaddr + out->slide;
        out->data_ranges[out->data_range_count++] = (vcc_range_t){
            start, start + (uintptr_t)seg->vmsize};
      }
    } else if (lc->cmd == LC_SYMTAB) {
      symtab_cmd = (const struct symtab_command *)lc;
    }
    lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
  }
  if (out->data_range_count == 0) return -5;

  // LC_SYMTAB pointers — file-offsets in the symtab_cmd are relative to the
  // DSC file layout; runtime addresses are recovered via the __LINKEDIT
  // segment's (vmaddr+slide) - fileoff base.
  if (symtab_cmd && linkedit && linkedit->fileoff <= symtab_cmd->symoff) {
    uintptr_t linkedit_base = (uintptr_t)linkedit->vmaddr + out->slide -
                              (uintptr_t)linkedit->fileoff;
    out->symtab = (const struct nlist_64 *)(linkedit_base +
                                            (uintptr_t)symtab_cmd->symoff);
    out->strtab = (const char *)(linkedit_base + (uintptr_t)symtab_cmd->stroff);
    out->nsyms  = symtab_cmd->nsyms;
  }
  return 0;
}

// Walk CMCapture's LC_SYMTAB for `name`. Returns slid VMA on match, or 0.
// On DSC dylibs the per-image symtab may be stripped of private symbols, in
// which case this returns 0 even for symbols that exist statically.
static uintptr_t vcc_lookup_lc_symtab(const vcc_image_t *img,
                                       const char *name) {
  if (!img->symtab || !img->strtab || img->nsyms == 0) return 0;
  for (uint32_t i = 0; i < img->nsyms; i++) {
    if (img->symtab[i].n_un.n_strx == 0) continue;
    const char *nm = img->strtab + img->symtab[i].n_un.n_strx;
    if (strcmp(nm, name) == 0) {
      uintptr_t val = (uintptr_t)img->symtab[i].n_value;
      if (val == 0) continue;
      return val + img->slide;
    }
  }
  return 0;
}

// Decode ARM64 BL imm26 -> absolute branch target.
static uintptr_t vcc_bl_target(uintptr_t bl_pc, uint32_t bl) {
  int64_t imm = (int64_t)(bl & 0x03FFFFFFu) << 6;  // place 26 bits in top
  imm >>= 4;                                        // shift right 4 (sign-ext + *4)
  return bl_pc + (uintptr_t)imm;
}

// Scan __text for the per-source ownership filter inside
// _captureSourceServer_handleCopySourcesMessage. The compiler emits:
//
//   bl  <objc_msgSend$boolValue>     ; w0  = [prewarmingEnabledRet boolValue]
//   mov x25, x0                       ; 0xAA0003F9
//   ldr x2, [sp, #<imm>]              ; F9400000 | (imm12<<10) | (31<<5) | 2
//                                     ;   — copy of bundleID outparam; offset
//                                     ;   is compiler-chosen, so mask it off
//   mov x0, x22                       ; 0xAA1603E0 — clientSI string
//   bl  <objc_msgSend$isEqualToString:>; w0  = [clientSI isEqualToString:bundleID]
//   cbz w0,  SKIP                     ; (insn & 0xFF00001F) == 0x34000000  → patch
//   cbz w25, SKIP                     ; (insn & 0xFF00001F) == 0x34000019  → patch
//
// Both cbz branch targets are identical (same SKIP label). We patch both
// to NOP so every source survives the per-client ownership + prewarming-
// enabled filter and reaches the response serializer.
static uintptr_t vcc_find_per_source_filter(const vcc_image_t *img) {
  if (!img->text || img->text_words < 6) return 0;
  for (size_t i = 0; i + 5 < img->text_words; i++) {
    if (img->text[i]     != 0xAA0003F9u) continue;          // mov x25, x0
    // ldr x2, [sp, #?] — any sp-relative 64-bit load into x2. The stack
    // offset is a compiler-chosen frame slot and shifts between builds.
    if ((img->text[i + 1] & 0xFFC003FFu) != 0xF94003E2u) continue;
    if (img->text[i + 2] != 0xAA1603E0u) continue;          // mov x0, x22
    if ((img->text[i + 3] & 0xFC000000u) != 0x94000000u)    // BL (don't care)
      continue;
    if ((img->text[i + 4] & 0xFF00001Fu) != 0x34000000u)    // cbz w0, ?
      continue;
    if ((img->text[i + 5] & 0xFF00001Fu) != 0x34000019u)    // cbz w25, ?
      continue;
    // Verify both cbz branch to the same target (same SKIP block).
    // CBZ encoding: bits 23..5 = imm19 (19-bit signed instruction offset).
    // Byte offset = sign_extend(imm19) * 4.
    int32_t imm0 = (int32_t)((img->text[i + 4] >> 5) & 0x7FFFFu);
    int32_t imm1 = (int32_t)((img->text[i + 5] >> 5) & 0x7FFFFu);
    if (imm0 & 0x40000) imm0 |= 0xFFF80000;
    if (imm1 & 0x40000) imm1 |= 0xFFF80000;
    uintptr_t tgt0 = (uintptr_t)&img->text[i + 4] + (intptr_t)imm0 * 4;
    uintptr_t tgt1 = (uintptr_t)&img->text[i + 5] + (intptr_t)imm1 * 4;
    if (tgt0 != tgt1) continue;
    return (uintptr_t)&img->text[i + 4];
  }
  return 0;
}

// Patch two consecutive instructions starting at `pc` to NOP. iOS __TEXT
// is W^X-enforced + TXM-validated. Try in order:
//  (a) vm_protect with VM_PROT_COPY: kernel COWs the page into an anon
//      mapping and grants RW. Standard iOS-hooker recipe (libhooker etc).
//  (b) vm_allocate scratch + memcpy + vm_remap(OVERWRITE|FIXED) overlay.
// Either way, scratch_writable -> patch -> set RX -> icache flush.
static int vcc_patch_two_nops(uintptr_t pc) {
  uintptr_t page_size = (uintptr_t)getpagesize();
  uintptr_t page_start = pc & ~(page_size - 1);
  uintptr_t end = pc + 8;
  uintptr_t page_end =
      ((end + page_size - 1) & ~(page_size - 1));
  vm_size_t span = (vm_size_t)(page_end - page_start);
  mach_port_t self_task = mach_task_self();

  // (a) vm_protect with VM_PROT_COPY (= 0x10) to force COW.
  kern_return_t kr = vm_protect(
      self_task,
      (vm_address_t)page_start,
      span,
      FALSE,
      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
  if (kr == KERN_SUCCESS) {
    uint32_t nop = 0xD503201Fu;
    ((uint32_t *)pc)[0] = nop;
    ((uint32_t *)pc)[1] = nop;
    kr = vm_protect(
        self_task,
        (vm_address_t)page_start,
        span,
        FALSE,
        VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr == KERN_SUCCESS) {
      sys_icache_invalidate((void *)pc, 8);
      vcc_log(@"  vm_protect+COPY patch OK @ 0x%lx",
              (unsigned long)pc);
      return 1;
    }
    vcc_log(@"  vm_protect restore RX failed: %d (page=0x%lx)",
            kr,
            (unsigned long)page_start);
    // Continue to try (b).
  } else {
    vcc_log(@"  vm_protect+COPY failed: %d", kr);
  }

  // (b) Scratch allocation + vm_remap with FIXED|OVERWRITE.
  vm_address_t scratch = 0;
  kr = vm_allocate(self_task, &scratch, span, VM_FLAGS_ANYWHERE);
  if (kr != KERN_SUCCESS) {
    vcc_log(@"  vm_allocate failed: %d", kr);
    return 0;
  }
  memcpy((void *)scratch, (const void *)page_start, span);
  uint32_t nop = 0xD503201Fu;
  uintptr_t scratch_pc = scratch + (pc - page_start);
  ((uint32_t *)scratch_pc)[0] = nop;
  ((uint32_t *)scratch_pc)[1] = nop;
  kr = vm_protect(
      self_task,
      scratch,
      span,
      FALSE,
      VM_PROT_READ | VM_PROT_EXECUTE);
  if (kr != KERN_SUCCESS) {
    vcc_log(@"  vm_protect RX scratch failed: %d", kr);
    vm_deallocate(self_task, scratch, span);
    return 0;
  }
  vm_address_t target = (vm_address_t)page_start;
  vm_prot_t cur_prot = 0, max_prot = 0;
  kr = vm_remap(
      self_task,
      &target,
      span,
      0,
      VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
      self_task,
      scratch,
      FALSE,
      &cur_prot,
      &max_prot,
      VM_INHERIT_NONE);
  if (kr != KERN_SUCCESS) {
    vcc_log(@"  vm_remap FIXED|OVERWRITE failed: %d (cur=0x%x max=0x%x)",
            kr,
            cur_prot,
            max_prot);
    vm_deallocate(self_task, scratch, span);
    return 0;
  }
  sys_icache_invalidate((void *)pc, 8);
  vcc_log(@"  vm_remap OK: page=0x%lx span=%zu (cur=0x%x max=0x%x)",
          (unsigned long)page_start,
          (size_t)span,
          cur_prot,
          max_prot);
  return 1;
}

// Patch a single 32-bit ARM64 instruction word at `pc` to `new_word`.
// Uses the same vm_protect(VM_PROT_COPY) → write → vm_protect(RX) →
// icache flush dance as vcc_patch_two_nops. Verifies the original word
// matches `expected_word` before writing so an iOS version skew doesn't
// silently corrupt the wrong code. Returns 1 on success.
static int vcc_patch_word(uintptr_t pc,
                          uint32_t expected_word,
                          uint32_t new_word) {
  uint32_t cur = ((const uint32_t *)pc)[0];
  if (cur != expected_word) {
    vcc_log(@"  patch_word @ 0x%lx: expected 0x%08x, found 0x%08x — skip",
            (unsigned long)pc,
            expected_word,
            cur);
    return 0;
  }
  uintptr_t page_size = (uintptr_t)getpagesize();
  uintptr_t page_start = pc & ~(page_size - 1);
  uintptr_t end = pc + 4;
  uintptr_t page_end = ((end + page_size - 1) & ~(page_size - 1));
  vm_size_t span = (vm_size_t)(page_end - page_start);
  mach_port_t self_task = mach_task_self();

  kern_return_t kr = vm_protect(
      self_task,
      (vm_address_t)page_start,
      span,
      FALSE,
      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
  if (kr != KERN_SUCCESS) {
    vcc_log(@"  patch_word vm_protect+COPY failed: %d", kr);
    return 0;
  }
  ((uint32_t *)pc)[0] = new_word;
  kr = vm_protect(
      self_task,
      (vm_address_t)page_start,
      span,
      FALSE,
      VM_PROT_READ | VM_PROT_EXECUTE);
  if (kr != KERN_SUCCESS) {
    vcc_log(@"  patch_word restore RX failed: %d", kr);
    return 0;
  }
  sys_icache_invalidate((void *)pc, 4);
  vcc_log(@"  patch_word OK @ 0x%lx: 0x%08x -> 0x%08x",
          (unsigned long)pc,
          expected_word,
          new_word);
  return 1;
}

// Scan the image's __text for every occurrence of `needle` and rewrite
// each to `replacement` via vcc_patch_word. Replaces hardcoded image
// VMAs for patches whose addresses we don't know per-build but whose
// instruction encoding is a stable fingerprint (e.g. `mov w20, #-12783`
// MOVN encodings used for error-prep). Returns the count patched.
static unsigned vcc_scan_and_patch(const vcc_image_t *img,
                                   uint32_t needle,
                                   uint32_t replacement,
                                   const char *what) {
  if (!img->text || !img->text_words) return 0;
  unsigned hits = 0;
  for (size_t i = 0; i < img->text_words; i++) {
    if (img->text[i] != needle) continue;
    uintptr_t pc = (uintptr_t)&img->text[i];
    if (vcc_patch_word(pc, needle, replacement)) hits++;
  }
  vcc_log(@"  scan_and_patch %s (0x%08x -> 0x%08x): %u hit(s)",
          what ? what : "?",
          needle,
          replacement,
          hits);
  return hits;
}

// Scan __text for the daemon's client-allowlist filter sequence:
//   bl  <FigCaptureCopyClientCodeSigningIdentifier>   ; X
//   bl  <objc_autorelease_stub>                       ; (don't care about target)
//   mov x22, x0                                       ; 0xAA0003F6
//   bl  <FigCaptureGetSupportedPrewarmingBundleIds>   ; Y
//   cbz x22, ...                                      ; (insn & 0xFF00001F) == 0xB4000016
//   mov x2, x22                                       ; 0xAA1603E2
//   bl  <objc_msgSend$containsObject:>                ; (don't care)
//   cbz w0,  ...                                      ; (insn & 0xFF00001F) == 0x34000000
//
// On a hit, writes the absolute (slid) target of the 1st and 4th BL into
// `*si_fn_out` and `*prewarm_fn_out`. Returns the PC of the first BL.
static uintptr_t vcc_find_filter_chain(const vcc_image_t *img,
                                        uintptr_t *si_fn_out,
                                        uintptr_t *prewarm_fn_out) {
  if (!img->text || img->text_words < 8) return 0;
  *si_fn_out = 0;
  *prewarm_fn_out = 0;

  for (size_t i = 0; i + 7 < img->text_words; i++) {
    uint32_t bl1 = img->text[i];
    if ((bl1 & 0xFC000000u) != 0x94000000u) continue;       // BL

    uint32_t bl2 = img->text[i + 1];
    if ((bl2 & 0xFC000000u) != 0x94000000u) continue;       // BL

    uint32_t mov_x22 = img->text[i + 2];
    if (mov_x22 != 0xAA0003F6u) continue;                   // mov x22, x0

    uint32_t bl3 = img->text[i + 3];
    if ((bl3 & 0xFC000000u) != 0x94000000u) continue;       // BL

    uint32_t cbz_x22 = img->text[i + 4];
    if ((cbz_x22 & 0xFF00001Fu) != 0xB4000016u) continue;   // cbz x22, ...

    uint32_t mov_x2 = img->text[i + 5];
    if (mov_x2 != 0xAA1603E2u) continue;                    // mov x2, x22

    uint32_t bl4 = img->text[i + 6];
    if ((bl4 & 0xFC000000u) != 0x94000000u) continue;       // BL

    uint32_t cbz_w0 = img->text[i + 7];
    if ((cbz_w0 & 0xFF00001Fu) != 0x34000000u) continue;    // cbz w0, ...

    uintptr_t bl1_pc = (uintptr_t)&img->text[i];
    uintptr_t bl3_pc = (uintptr_t)&img->text[i + 3];
    *si_fn_out      = vcc_bl_target(bl1_pc, bl1);
    *prewarm_fn_out = vcc_bl_target(bl3_pc, bl3);
    return bl1_pc;
  }
  return 0;
}

static int vcc_addr_in_data(const vcc_image_t *img, uintptr_t addr) {
  for (unsigned i = 0; i < img->data_range_count; i++) {
    if (addr >= img->data_ranges[i].start &&
        addr <  img->data_ranges[i].end) return 1;
  }
  return 0;
}

// Decode ARM64 ADRP immediate from the instruction word.
// Returns the absolute page-aligned target of `adrp Xn, <page>`.
static uintptr_t vcc_adrp_target(uintptr_t adrp_pc, uint32_t adrp) {
  int64_t immlo = (adrp >> 29) & 0x3;
  int64_t immhi = (adrp >> 5) & 0x7ffff;
  int64_t imm = (immhi << 2) | immlo;
  if (imm & (1LL << 20)) imm |= ~((1LL << 21) - 1);
  return (adrp_pc & ~(uintptr_t)0xfffULL) + (uintptr_t)(imm << 12);
}

// Find a global by scanning __text for `adrp Xn, page; ldr Xm, [Xn, #offset]`.
// Tallies hits per resolved target address; accepts only candidates that
// fall inside one of CMCapture's writable data segments. Returns the
// most-hit candidate, or 0 if no candidate qualifies / there is a tie.
//
// `offset` is the byte offset within the page (must be a multiple of 8).
static uintptr_t vcc_find_data_xref(const vcc_image_t *img, unsigned offset) {
  if (!img->text || !img->text_words) return 0;
  if ((offset & 7) || offset > 0x7FF8) return 0;
  uint32_t scaled_imm = (offset / 8) & 0xfff;

  enum { MAX_CANDS = 16 };
  struct { uintptr_t addr; unsigned hits; } cands[MAX_CANDS];
  unsigned n_cands = 0;

  for (size_t i = 1; i < img->text_words; i++) {
    uint32_t ldr = img->text[i];
    // 64-bit LDR (immediate, unsigned offset): bits 31..22 = 1111100101
    if ((ldr & 0xFFC00000u) != 0xF9400000u) continue;
    if (((ldr >> 10) & 0xfff) != scaled_imm) continue;
    uint32_t rn = (ldr >> 5) & 0x1f;
    uint32_t adrp = img->text[i - 1];
    // ADRP: bits 31..24 fixed = 1xx10000 (mask 0x9F000000 == 0x90000000)
    if ((adrp & 0x9F000000u) != 0x90000000u) continue;
    if ((adrp & 0x1f) != rn) continue;
    uintptr_t adrp_pc = (uintptr_t)&img->text[i - 1];
    uintptr_t target = vcc_adrp_target(adrp_pc, adrp) + offset;
    if (!vcc_addr_in_data(img, target)) continue;

    unsigned k;
    for (k = 0; k < n_cands; k++) {
      if (cands[k].addr == target) { cands[k].hits++; break; }
    }
    if (k == n_cands && n_cands < MAX_CANDS) {
      cands[n_cands].addr = target;
      cands[n_cands].hits = 1;
      n_cands++;
    }
  }

  unsigned best = 0, best_hits = 0;
  int tie = 0;
  for (unsigned i = 0; i < n_cands; i++) {
    if (cands[i].hits > best_hits) {
      best_hits = cands[i].hits;
      best = i;
      tie = 0;
    } else if (cands[i].hits == best_hits) {
      tie = 1;
    }
  }
  if (best_hits == 0) {
    vcc_log(@"  xref scan #%u: no in-data candidates", offset);
    return 0;
  }
  if (tie) {
    vcc_log(@"  xref scan #%u: %u candidates tied at %u hits — refusing to pick",
            offset,
            n_cands,
            best_hits);
    return 0;
  }
  vcc_log(@"  xref scan #%u: %u candidates, winner 0x%lx with %u hits",
          offset,
          n_cands,
          (unsigned long)cands[best].addr,
          best_hits);
  return cands[best].addr;
}

// arm64e ISA class-pointer mask, per libobjc's objc-private.h:
// `#define ISA_MASK 0x00007ffffffffff8ULL`. Bits 0-2 are isa flags
// (has_assoc / has_cxx_dtor / is_indexed), bits 3-46 are the class
// pointer (44 bits), bits 47-63 are PAC + magic-signature bits.
#define VCC_ISA_CLASS_MASK 0x00007FFFFFFFFFF8ULL

// Returns YES if the value stored at `slot_addr` is a pointer to a
// heap-allocated CFArray instance. Uses malloc_zone_from_ptr to
// confirm the candidate pointer was returned by malloc (safe for any
// 64-bit value; never dereferences) before reading its isa. CFArray
// instances are always heap allocations from the default malloc zone,
// so a non-heap value can't be _sSourceList.
static BOOL vcc_slot_value_is_cfarray(uintptr_t slot_addr) {
  if (!slot_addr) return NO;
  // The slot addresses read here are always in CMCapture's __DATA /
  // __DATA_CONST segments (filtered upstream by vcc_addr_in_data) so the read
  // itself is safe — those pages are mapped read-something into the process.
  uintptr_t val_ptr = *(uintptr_t *)slot_addr;
  if (!val_ptr) return NO;
  if (val_ptr < 0x100000000ULL || val_ptr > 0x800000000000ULL) return NO;
  // malloc_zone_from_ptr returns NULL for non-malloc pointers — this
  // is the safe pre-deref guard. CFArray instances are always heap-
  // allocated, so any candidate whose slot value isn't heap-owned is
  // definitionally not _sSourceList.
  malloc_zone_t *zone = malloc_zone_from_ptr((const void *)val_ptr);
  if (!zone) return NO;
  // Now safe to dereference: the value is a confirmed heap allocation.
  uintptr_t isa = *(uintptr_t *)val_ptr;
  uintptr_t isa_class = isa & VCC_ISA_CLASS_MASK;
  if (!isa_class) return NO;
  static const char *array_classes[] = {
      "__NSCFArray", "__NSArrayM", "__NSArrayI", "__NSArray0",
      "__NSSingleObjectArrayI", "NSArray", "NSMutableArray",
      "NSCFArray", NULL,
  };
  for (unsigned i = 0; array_classes[i]; i++) {
    Class c = objc_getClass(array_classes[i]);
    if (!c) continue;
    uintptr_t c_class = ((uintptr_t)c) & VCC_ISA_CLASS_MASK;
    if (isa_class == c_class) return YES;
  }
  return NO;
}

// Walk a function's body and collect every (BL <X> ; adrp + str x0,
// [Xn, #imm]) pair into `out_addrs`, returning the count. Useful for
// extracting the data-global init sequence of a static-init block —
// each pair represents one "store the result of a function call into
// a static global" site. The init block for CMCapture's source-list
// statics emits one such pair per global it initializes; the first
// one is `_sSourceList`.
static unsigned vcc_collect_call_then_store_globals(
    uintptr_t func,
    unsigned maxInsns,
    unsigned lookahead,
    uintptr_t *out_addrs,
    unsigned cap) {
  if (!func || !out_addrs || !cap) return 0;
  func = (uintptr_t)ptrauth_strip((void *)func, ptrauth_key_function_pointer);
  uint32_t *ip = (uint32_t *)func;
  unsigned n = 0;
  for (unsigned i = 0; i < maxInsns && n < cap; i++) {
    uint32_t insn = ip[i];
    if ((insn & 0xFC000000u) != 0x94000000u) continue;  // BL
    for (unsigned j = 1; j <= lookahead && i + j + 1 < maxInsns; j++) {
      uint32_t adrp = ip[i + j];
      if ((adrp & 0x9F000000u) != 0x90000000u) continue;
      uint32_t rd_adrp = adrp & 0x1Fu;
      uint32_t str = ip[i + j + 1];
      if ((str & 0xFFC00000u) != 0xF9000000u) continue;
      uint32_t rt = str & 0x1Fu;
      uint32_t rn = (str >> 5) & 0x1Fu;
      uint32_t off = ((str >> 10) & 0xFFFu) * 8;
      if (rt != 0) continue;
      if (rn != rd_adrp) continue;
      uintptr_t adrp_pc = (uintptr_t)&ip[i + j];
      uintptr_t target = vcc_adrp_target(adrp_pc, adrp) + off;
      // Dedup
      BOOL dup = NO;
      for (unsigned k = 0; k < n; k++) {
        if (out_addrs[k] == target) { dup = YES; break; }
      }
      if (!dup) out_addrs[n++] = target;
      break;
    }
  }
  return n;
}

// Resolve a CFString constant by symbol name.
static CFStringRef vcc_cfconst(const char *symname) {
  void **slot = dlsym(RTLD_DEFAULT, symname);
  if (!slot) {
    vcc_log(@"  dlsym FAIL: %s", symname);
    return NULL;
  }
  return (CFStringRef)*slot;
}

// Resolve a function symbol by name. On arm64e dlsym returns a PAC-signed
// pointer signed with key IA + discriminator 0 (the standard C ABI signing
// schema) — callable directly as a C function pointer. Returns NULL on miss.
static void *vcc_dlsym_fn(const char *name) {
  void *p = dlsym(RTLD_DEFAULT, name);
  if (!p) vcc_log(@"  dlsym FAIL: %s", name);
  return p;
}
