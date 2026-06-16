/*
 * libvcamcaptured — synthetic camera source injection in cameracaptured.
 *
 * Loaded into `/usr/libexec/cameracaptured` via the systemhook ->
 * TweakLoader chain (TweakLoader.m's `kVPhoneAllowedDaemonPaths`).
 *
 * Strategy (iOS 26.x):
 *   1. AVF clients query `+[AVCaptureDevice devicesWithMediaType:]`.
 *   2. That bottoms out at `FigCaptureSourceRemoteCopyCaptureSources(1)`
 *      which XPC-calls cameracaptured's
 *      `_captureSourceServer_handleCopySourcesMessage`.
 *   3. The daemon iterates `_sSourceList` (CFMutableArrayRef in
 *      CMCapture's __DATA_DIRTY.__bss) under `_sSourceListLock` and
 *      serializes each via `_captureSourceServer_createSerializedSource`.
 *   4. We build a synthetic source using Apple's own
 *      `FigCaptureSourceCreateFromBacking` — which produces a proper
 *      CMBaseObject with valid PAC-signed vtable — then append it to
 *      `_sSourceList` under the lock.
 *   5. Post the Darwin notification subscribed-to by AVF clients so they
 *      drop their cached device list and re-query.
 *
 * Version portability:
 *   No hardcoded image VMAs. All CMCapture addresses are recovered at
 *   runtime via:
 *     - dlsym for exported functions (FigCaptureSourceServerStart,
 *       FigCaptureSourceCreateFromBacking, FigSimpleMutexLock/Unlock,
 *       CMBaseObjectGetVTable).
 *     - getsectiondata to map CMCapture's __text bounds.
 *     - Structural xref pattern scan of __text to find the
 *       `_sSourceList` / `_sSourceListLock` slots:
 *         `adrp Xn, <page>; ldr Xm, [Xn, #<imm>]`
 *       where #imm matches the slot's per-page offset (compiler emits the
 *       same instruction pair from every xref site, so we expect multiple
 *       matches; we accept only when all matches agree).
 */

#import <CoreFoundation/CoreFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <notify.h>
#include <ptrauth.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

// MARK: - shared frame layout (matches vphoned_vcam.h)
//
// cameracaptured's sandbox blocks AF_VSOCK socket creation, so the frame
// receiver lives in vphoned (root, has vsock perms). vphoned writes
// frames into a shared mmap and posts a Darwin notification; we map the
// file read-only, subscribe to the notification, and copy out the latest
// frame on each fire.

#define VCC_SHM_PATH                                                           \
  "/var/jb/var/mobile/Library/vphone-vcam-frame.shm"
#define VCC_NOTIFY_NAME "com.vphone.vcam.frame"
#define VCC_SHM_HEADER_SIZE 64
#define VCC_SHM_MAX_PIXELS (8 * 1024 * 1024)
#define VCC_SHM_TOTAL_SIZE                                                     \
  (VCC_SHM_HEADER_SIZE + VCC_SHM_MAX_PIXELS)

typedef struct __attribute__((packed)) {
  uint64_t seq;
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;
  uint32_t pixel_format;
  uint32_t _reserved;
  uint64_t timestamp_ns;
  uint64_t frame_index;
  uint32_t pixels_length;
  uint32_t _pad;
} vcc_shm_header_t;

// MARK: - sentinel logging

static NSString *const kSentinelPath =
    @"/var/jb/var/mobile/Library/vcamcaptured.log";

static void vcc_log(NSString *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
  va_end(args);
  NSString *line = [NSString
      stringWithFormat:@"%@ [vcamcaptured:%d:%@] %@\n",
                       [NSDate.date description], getpid(),
                       NSProcessInfo.processInfo.processName ?: @"?", msg];
  NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
  if (!data.length) return;
  int fd = open(kSentinelPath.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd >= 0) {
    (void)write(fd, data.bytes, data.length);
    close(fd);
  }
  NSLog(@"vcamcaptured: %@", msg);
}

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
      self_task, (vm_address_t)page_start, span, FALSE,
      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
  if (kr == KERN_SUCCESS) {
    uint32_t nop = 0xD503201Fu;
    ((uint32_t *)pc)[0] = nop;
    ((uint32_t *)pc)[1] = nop;
    kr = vm_protect(self_task, (vm_address_t)page_start, span, FALSE,
                    VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr == KERN_SUCCESS) {
      sys_icache_invalidate((void *)pc, 8);
      vcc_log(@"  vm_protect+COPY patch OK @ 0x%lx",
              (unsigned long)pc);
      return 1;
    }
    vcc_log(@"  vm_protect restore RX failed: %d (page=0x%lx)",
            kr, (unsigned long)page_start);
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
  kr = vm_protect(self_task, scratch, span, FALSE,
                  VM_PROT_READ | VM_PROT_EXECUTE);
  if (kr != KERN_SUCCESS) {
    vcc_log(@"  vm_protect RX scratch failed: %d", kr);
    vm_deallocate(self_task, scratch, span);
    return 0;
  }
  vm_address_t target = (vm_address_t)page_start;
  vm_prot_t cur_prot = 0, max_prot = 0;
  kr = vm_remap(self_task, &target, span, 0,
                VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                self_task, scratch, FALSE,
                &cur_prot, &max_prot, VM_INHERIT_NONE);
  if (kr != KERN_SUCCESS) {
    vcc_log(@"  vm_remap FIXED|OVERWRITE failed: %d (cur=0x%x max=0x%x)",
            kr, cur_prot, max_prot);
    vm_deallocate(self_task, scratch, span);
    return 0;
  }
  sys_icache_invalidate((void *)pc, 8);
  vcc_log(@"  vm_remap OK: page=0x%lx span=%zu (cur=0x%x max=0x%x)",
          (unsigned long)page_start, (size_t)span, cur_prot, max_prot);
  return 1;
}

// Patch a single 32-bit ARM64 instruction word at `pc` to `new_word`.
// Uses the same vm_protect(VM_PROT_COPY) → write → vm_protect(RX) →
// icache flush dance as vcc_patch_two_nops. Verifies the original word
// matches `expected_word` before writing so an iOS version skew doesn't
// silently corrupt the wrong code. Returns 1 on success.
static int vcc_patch_word(uintptr_t pc, uint32_t expected_word,
                           uint32_t new_word) {
  uint32_t cur = ((const uint32_t *)pc)[0];
  if (cur != expected_word) {
    vcc_log(@"  patch_word @ 0x%lx: expected 0x%08x, found 0x%08x — skip",
            (unsigned long)pc, expected_word, cur);
    return 0;
  }
  uintptr_t page_size = (uintptr_t)getpagesize();
  uintptr_t page_start = pc & ~(page_size - 1);
  uintptr_t end = pc + 4;
  uintptr_t page_end = ((end + page_size - 1) & ~(page_size - 1));
  vm_size_t span = (vm_size_t)(page_end - page_start);
  mach_port_t self_task = mach_task_self();

  kern_return_t kr = vm_protect(
      self_task, (vm_address_t)page_start, span, FALSE,
      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
  if (kr != KERN_SUCCESS) {
    vcc_log(@"  patch_word vm_protect+COPY failed: %d", kr);
    return 0;
  }
  ((uint32_t *)pc)[0] = new_word;
  kr = vm_protect(self_task, (vm_address_t)page_start, span, FALSE,
                  VM_PROT_READ | VM_PROT_EXECUTE);
  if (kr != KERN_SUCCESS) {
    vcc_log(@"  patch_word restore RX failed: %d", kr);
    return 0;
  }
  sys_icache_invalidate((void *)pc, 4);
  vcc_log(@"  patch_word OK @ 0x%lx: 0x%08x -> 0x%08x",
          (unsigned long)pc, expected_word, new_word);
  return 1;
}

// Scan the image's __text for every occurrence of `needle` and rewrite
// each to `replacement` via vcc_patch_word. Replaces hardcoded image
// VMAs for patches whose addresses we don't know per-build but whose
// instruction encoding is a stable fingerprint (e.g. `mov w20, #-12783`
// MOVN encodings used for error-prep). Returns the count patched.
static unsigned vcc_scan_and_patch(const vcc_image_t *img,
                                    uint32_t needle, uint32_t replacement,
                                    const char *what) {
  if (!img->text || !img->text_words) return 0;
  unsigned hits = 0;
  for (size_t i = 0; i < img->text_words; i++) {
    if (img->text[i] != needle) continue;
    uintptr_t pc = (uintptr_t)&img->text[i];
    if (vcc_patch_word(pc, needle, replacement)) hits++;
  }
  vcc_log(@"  scan_and_patch %s (0x%08x -> 0x%08x): %u hit(s)",
          what ? what : "?", needle, replacement, hits);
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
            offset, n_cands, best_hits);
    return 0;
  }
  vcc_log(@"  xref scan #%u: %u candidates, winner 0x%lx with %u hits",
          offset, n_cands, (unsigned long)cands[best].addr, best_hits);
  return cands[best].addr;
}

// Read a pointer-sized value from `addr` and store in `*out`. The
// slot addresses we feed this function are always in CMCapture's
// __DATA / __DATA_CONST segments (filtered upstream by
// vcc_addr_in_data) so the read itself is safe — those pages are
// mapped read-something into the process. Wrapped in a function for
// future swap-in of a safer reader if the constraint changes.
static BOOL vcc_safe_read_ptr(uintptr_t addr, uintptr_t *out) {
  if (!addr || !out) return NO;
  *out = *(uintptr_t *)addr;
  return YES;
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
  uintptr_t val_ptr = 0;
  if (!vcc_safe_read_ptr(slot_addr, &val_ptr)) return NO;
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
    uintptr_t func, unsigned maxInsns, unsigned lookahead,
    uintptr_t *out_addrs, unsigned cap) {
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

// MARK: - synthetic source construction

static id vcc_build_backing(void) {
  Class backingClass = NSClassFromString(@"FigCaptureSourceBacking");
  if (!backingClass) {
    vcc_log(@"  FigCaptureSourceBacking class missing");
    return nil;
  }
  CFStringRef k_uid  = vcc_cfconst("kFigCaptureSourceAttributeKey_UniqueID");
  CFStringRef k_dt   = vcc_cfconst("kFigCaptureSourceAttributeKey_DeviceType");
  CFStringRef k_ln   = vcc_cfconst("kFigCaptureSourceAttributeKey_LocalizedName");
  CFStringRef k_mid  = vcc_cfconst("kFigCaptureSourceAttributeKey_ModelID");
  CFStringRef k_pos  = vcc_cfconst("kFigCaptureSourceAttributeKey_Position");
  CFStringRef k_st   = vcc_cfconst("kFigCaptureSourceAttributeKey_SourceType");
  CFStringRef k_cdid = vcc_cfconst("kFigCaptureSourceAttributeKey_CaptureDeviceID");
  if (!k_uid || !k_dt) {
    vcc_log(@"  required attr keys missing");
    return nil;
  }

  NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
  attrs[(__bridge NSString *)k_uid] = @"vphone:vcam:0";
  // DeviceType: empirical sweep
  //   - 1 (BuiltInWideAngleCamera): Camera.app routes to the real ISP /
  //     hardware path and fails immediately because no hardware backs
  //     us — viewfinder stream pool isn't even spun up.
  //   - 2: Camera.app's Photo/Video tabs use the generic / soft path
  //     and at least start the FigCameraViewfinderStream init pool
  //     (~2000/sec) before stalling at openWithDestination:. This is
  //     where we have a chance to inject a destination.
  // Keep 2 until the inject-destination shape is figured out.
  attrs[(__bridge NSString *)k_dt]  = @(2);
  if (k_ln)  attrs[(__bridge NSString *)k_ln]  = @"vphone Virtual Camera";
  if (k_mid) attrs[(__bridge NSString *)k_mid] = @"vphone-vcam-1";
  if (k_pos) attrs[(__bridge NSString *)k_pos] = @(1);
  // sourceType MUST be 1 (video) for the daemon's media-type filter to
  // include this source in a vide-typed FigCaptureSourceRemoteCopyCaptureSources
  // request. Without it, attrs[SourceType] = nil → intValue = 0 → fails
  // the tbnz w8 gate in handleCopySourcesMessage.
  if (k_st)  attrs[(__bridge NSString *)k_st]  = @(1);
  // captureSession_buildGraphWithConfiguration (CMCapture vmaddr 0x1ae2b1910)
  // iterates the source list and calls
  // _FigCaptureSourceGetAttribute(source, kFigCaptureSourceAttributeKey_CaptureDeviceID)
  // then -[NSMutableArray addObject:] with the result. If the key is missing
  // the call returns nil and the array throws NSInvalidArgumentException
  // ("object cannot be nil") inside -[__NSArrayM insertObject:atIndex:] —
  // which kills cameracaptured as soon as any AVCaptureSession references
  // our synth.
  //
  // The value must be a string, NOT a number. -[BWFigCaptureDeviceVendor
  // _createDevice:reason:clientPID:figCaptureDevice:] sends isEqualToString:
  // to it; an NSNumber raises "unrecognized selector". Use a unique opaque
  // string outside whatever pattern Apple uses for hardware cameras.
  if (k_cdid) attrs[(__bridge NSString *)k_cdid] = @"vphone:vcam:device:0";

  // After hooking _FigCaptureSourceGetAttribute via lldb we observed
  // Camera.app's graph builder also queries these 5 boolean / scheme keys
  // against our synth. Provide explicit values so the builder doesn't bail
  // on a nil capability check. Verified order observed via lldb:
  //   SmartCameraSupported, StillImageNoiseReductionAndFusionScheme,
  //   MidFrameSynchronizationNotSupported, TimeOfFlightAssistedAutoFocusSupported,
  //   StructuredLightAssistedAutoFocusSupported
  NSString *(^figKeyN)(const char *) = ^NSString *(const char *symname) {
    void **slot = dlsym(RTLD_DEFAULT, symname);
    if (slot && *slot) return (__bridge NSString *)(CFStringRef)(*slot);
    const char *cs = symname;
    const char *u = strrchr(cs, '_');
    if (u) cs = u + 1;
    return [NSString stringWithUTF8String:cs];
  };
  attrs[figKeyN("kFigCaptureSourceAttributeKey_SmartCameraSupported")] = @NO;
  attrs[figKeyN("kFigCaptureSourceAttributeKey_StillImageNoiseReductionAndFusionScheme")] = @(0);
  attrs[figKeyN("kFigCaptureSourceAttributeKey_MidFrameSynchronizationNotSupported")] = @NO;
  attrs[figKeyN("kFigCaptureSourceAttributeKey_TimeOfFlightAssistedAutoFocusSupported")] = @NO;
  attrs[figKeyN("kFigCaptureSourceAttributeKey_StructuredLightAssistedAutoFocusSupported")] = @NO;

  // Construct a FigCaptureSourceVideoFormat via its private init taking a
  // stream format dictionary. Required keys recovered by reversing
  // `-[FigCaptureSourceFormat formatDescription]` + `-format` + `-dimensions`:
  //   "Name"            (NSString)  -- required by base init's cbz guard
  //   "Width"           (NSNumber)  -- becomes dimensions.width
  //   "Height"          (NSNumber)  -- becomes dimensions.height
  //   "PixelFormatType" (NSNumber)  -- 4cc fed to CMVideoFormatDescriptionCreate
  // All other keys read by the subclass init fall through to default
  // (0/nil) values via objectForKeyedSubscript: chains.
  NSArray *formats = @[];
  Class fmtClass = NSClassFromString(@"FigCaptureSourceVideoFormat");
  if (fmtClass) {
    // Resolve the canonical CFString constants by name when possible (some
    // are defined in a private framework not in the dyld exports trie, so
    // we fall back to the plain string after the Fig naming convention).
    NSString *(^figKey)(const char *) = ^NSString *(const char *symname) {
      void **slot = dlsym(RTLD_DEFAULT, symname);
      if (slot && *slot) return (__bridge NSString *)(CFStringRef)(*slot);
      // Convention: kFigSupportedFormat_VideoMinFrameRate → "VideoMinFrameRate"
      const char *cs = symname;
      const char *u = strrchr(cs, '_');
      if (u) cs = u + 1;
      return [NSString stringWithUTF8String:cs];
    };
    // Publish TWO formats: one BGRA, one 420v at the same 1280x720
    // dimensions. Clients that filter on BGRA (e.g. Loupe / Magnifier)
    // see one; clients that pick the canonical ISP pixel format (AVF's
    // _preferredFormatForPreset: matcher for AVCaptureSessionPresetHigh)
    // pick the 420v one. Same preset list + frame-rate range on both.
    NSDictionary *commonKeys = @{
      @"DefaultActiveFormat" : @NO,  // overridden on the active one
      figKey("kFigSupportedFormat_VideoMinFrameRate") : @(1),
      figKey("kFigSupportedFormat_VideoMaxFrameRate") : @(60),
      // -[FigCaptureSourceVideoFormat maxZoomFactor] takes a fast path that
      // returns 1.0 for raw bayer formats; for BGRA (our case) it falls to
      // a fancy path that reads stabilizationTypeOverrideForCinematic / -ForStandard
      // and consults a dimension-table when either equals 3. Setting this
      // key to 3 makes the table apply (returns 16.0 for 1280-wide formats),
      // which keeps -[AVCaptureFigVideoDevice setVideoZoomFactor:] from
      // throwing "out-of-range [1, activeFormat.videoMaxZoomFactor]" when
      // Camera.app sets a default zoom > 1.0.
      @"VideoStabilizationTypeOverrideForStandard" : @(3),
      // Without AVCaptureSessionPresets, -[AVCaptureDevice
      // supportsAVCaptureSessionPreset:] returns NO for every preset
      // (canAddInput=False everywhere except InputPriority). Camera.app
      // uses High/Photo — list them all so common AVF clients pass.
      @"AVCaptureSessionPresets" : @[
        @"AVCaptureSessionPresetHigh",
        @"AVCaptureSessionPreset1280x720",
        @"AVCaptureSessionPreset640x480",
        @"AVCaptureSessionPresetMedium",
        @"AVCaptureSessionPresetLow",
        @"AVCaptureSessionPresetPhoto",
        @"AVCaptureSessionPreset352x288",
      ],
    };
    NSMutableDictionary *bgra_fmt = [@{
      @"Name"            : @"vphone-vcam-720p-bgra",
      @"Width"           : @1280,
      @"Height"          : @720,
      @"PixelFormatType" : @(0x42475241u),  // 'BGRA'
    } mutableCopy];
    [bgra_fmt addEntriesFromDictionary:commonKeys];

    NSMutableDictionary *y420v_fmt = [@{
      @"Name"            : @"vphone-vcam-720p-420v",
      @"Width"           : @1280,
      @"Height"          : @720,
      @"PixelFormatType" : @(0x34323076u),  // '420v'
      // Mark 420v as default — it's what AVF's preset matcher prefers
      // when picking _setActiveFormat: under standard presets.
      @"DefaultActiveFormat" : @YES,
    } mutableCopy];
    [y420v_fmt addEntriesFromDictionary:commonKeys];
    y420v_fmt[@"DefaultActiveFormat"] = @YES;  // re-set after the merge

    SEL fmtInitSel = NSSelectorFromString(
        @"initWithFigCaptureStreamFormatDictionary:");
    NSMutableArray *formatObjs = [NSMutableArray array];
    for (NSDictionary *fmtDict in @[ bgra_fmt, y420v_fmt ]) {
      id fmtAlloc = ((id (*)(Class, SEL))objc_msgSend)(fmtClass,
                                                         @selector(alloc));
      id fmtObj = nil;
      if (fmtAlloc) {
        fmtObj = ((id (*)(id, SEL, id))objc_msgSend)(fmtAlloc, fmtInitSel,
                                                       fmtDict);
      }
      vcc_log(@"  FigCaptureSourceVideoFormat (%@) = %p",
              fmtDict[@"Name"], fmtObj);
      if (fmtObj) [formatObjs addObject:fmtObj];
    }
    formats = formatObjs;
  } else {
    vcc_log(@"  FigCaptureSourceVideoFormat class missing");
  }

  SEL initSel = NSSelectorFromString(
      @"initWithMediaType:attributes:cachedProperties:formats:"
      @"missingFormatNames:synchronizedStreamUniqueIDs:"
      @"unsynchronizedStreamUniqueIDs:");
  id alloced = ((id (*)(Class, SEL))objc_msgSend)(backingClass,
                                                    @selector(alloc));
  if (!alloced) return nil;
  uint32_t mediaTypeVideo = 0x76696465;  // 'vide'
  id backing = ((id (*)(id, SEL, uint32_t, id, id, id, id, id, id))objc_msgSend)(
      alloced, initSel, mediaTypeVideo, attrs,
      [NSMutableDictionary dictionary], formats, @[], @[], @[]);
  vcc_log(@"  backing = %p (attrs.count=%lu formats.count=%lu)",
          backing, (unsigned long)attrs.count,
          (unsigned long)formats.count);
  return backing;
}

// FigCaptureSourceCreateFromBacking signature (5 args):
//   (CFAllocatorRef allocator, FigCaptureSourceBacking *backing,
//    audit_token_t *token, int unused_x3, FigCaptureSource **outSource)
typedef int (*VCC_CreateFn)(CFAllocatorRef, id, void *, int, void **);

static void *vcc_create_synthetic_source(VCC_CreateFn create_fn, id backing) {
  audit_token_t self_token;
  mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
  kern_return_t kr = task_info(mach_task_self(), TASK_AUDIT_TOKEN,
                               (task_info_t)&self_token, &count);
  if (kr != KERN_SUCCESS) {
    vcc_log(@"  task_info(TASK_AUDIT_TOKEN) failed: %d", kr);
    return NULL;
  }

  void *outSource = NULL;
  int ret = create_fn(kCFAllocatorDefault, backing, &self_token, 0, &outSource);
  vcc_log(@"  CreateFromBacking ret=0x%x outSource=%p", (unsigned)ret,
          outSource);
  return outSource;
}

// Walk the synthetic's PAC-signed vtable to call CopyProperty (vtable[6]) for
// confirmation of the contract methods. This is purely diagnostic; uses only
// dlsym-resolvable anchors (CMBaseObjectGetVTable) and standard PAC builtins.
static void vcc_probe_contract(void *source) {
  void *(*CMBaseObjectGetVTable)(void *) =
      (void *(*)(void *))vcc_dlsym_fn("CMBaseObjectGetVTable");
  if (!CMBaseObjectGetVTable) return;
  void *V = CMBaseObjectGetVTable(source);
  vcc_log(@"  CMBaseObjectGetVTable(synth) = %p", V);
  if (!V) return;

  // Auth the vtable pointer (data key A, address-blended discriminator).
  void **vtable_slot = (void **)((char *)V + 8);
  void *real_vtable_signed = *vtable_slot;
  uintptr_t vt_disc =
      __builtin_ptrauth_blend_discriminator(vtable_slot, 47377);
  void *real_vtable = __builtin_ptrauth_auth(real_vtable_signed,
                                              ptrauth_key_asda, vt_disc);
  vcc_log(@"  real_vtable @ %p", real_vtable);

  // Auth method6 (instruction key A) then resign for the C ABI call.
  void **method6_slot = (void **)((char *)real_vtable + 48);
  void *method6_signed = *method6_slot;
  uintptr_t m6_disc =
      __builtin_ptrauth_blend_discriminator(method6_slot, 38693);
  void *method6 = __builtin_ptrauth_auth_and_resign(
      method6_signed, ptrauth_key_asia, m6_disc,
      ptrauth_key_function_pointer, 0);
  vcc_log(@"  CopyProperty (vtable[6]) @ %p", method6);

  typedef int (*VCC_CopyPropFn)(void *src, CFStringRef key,
                                 CFAllocatorRef alloc, CFTypeRef *out);
  VCC_CopyPropFn copyProp = (VCC_CopyPropFn)method6;

  CFStringRef k_attrs = vcc_cfconst(
      "kFigCaptureSourceProperty_AttributesDictionary");
  CFStringRef k_fmts  = vcc_cfconst("kFigCaptureSourceProperty_Formats");

  CFTypeRef outAttrs = NULL;
  int e1 = copyProp(source, k_attrs, kCFAllocatorDefault, &outAttrs);
  vcc_log(@"  CopyProperty(AttributesDictionary) ret=%d out=%p (%@)",
          e1, outAttrs, outAttrs);
  if (outAttrs) CFRelease(outAttrs);

  CFTypeRef outFmts = NULL;
  int e2 = copyProp(source, k_fmts, kCFAllocatorDefault, &outFmts);
  vcc_log(@"  CopyProperty(Formats) ret=%d out=%p (count=%ld)",
          e2, outFmts,
          outFmts && CFGetTypeID(outFmts) == CFArrayGetTypeID()
              ? CFArrayGetCount(outFmts) : -1);
  if (outFmts) CFRelease(outFmts);
}

// MARK: - _sSourceList manipulation

static void vcc_install_synthetic(void) {
  vcc_image_t img;
  int rc = vcc_image_resolve(&img, "FigCaptureSourceServerStart");
  if (rc != 0) {
    vcc_log(@"  image resolve failed rc=%d", rc);
    return;
  }
  vcc_log(@"  CMCapture mh=%p slide=0x%lx text=%p words=%zu nsyms=%u",
          img.mh, (unsigned long)img.slide, img.text, img.text_words,
          img.nsyms);

  // DSC strips per-image LC_SYMTAB names to "<redacted>" — symtab walking
  // by name doesn't work. Recover the two private function addresses via
  // a structural pattern scan of __text for the daemon's filter chain.
  uintptr_t si_fn_addr = 0, prewarm_fn_addr = 0;
  uintptr_t hit_pc =
      vcc_find_filter_chain(&img, &si_fn_addr, &prewarm_fn_addr);
  vcc_log(@"  filter-chain scan: pc=0x%lx si_fn=0x%lx prewarm_fn=0x%lx",
          (unsigned long)hit_pc, (unsigned long)si_fn_addr,
          (unsigned long)prewarm_fn_addr);

  // Patch the per-source ownership/prewarming filter that runs inside the
  // iteration loop of handleCopySourcesMessage. Without these patches,
  // every source is rejected unless its ClientBundleIdentifier property
  // matches the requesting client's signing-id AND PrewarmingEnabled is
  // YES — which is never true for our synthetic source nor for the daemon
  // bring-up source against a non-Camera.app client.
  uintptr_t per_source_pc = vcc_find_per_source_filter(&img);
  if (per_source_pc) {
    int ok = vcc_patch_two_nops(per_source_pc);
    vcc_log(@"  per-source NOP patch %s @ 0x%lx",
            ok ? "OK" : "FAILED", (unsigned long)per_source_pc);
  } else {
    vcc_log(@"  per-source filter not located — daemon will skip our source");
  }

  if (prewarm_fn_addr) {
    typedef CFTypeRef (*PrewarmFn)(void);
    PrewarmFn pf = (PrewarmFn)ptrauth_sign_unauthenticated(
        (void *)prewarm_fn_addr, ptrauth_key_function_pointer, 0);
    CFTypeRef setv = pf();
    vcc_log(@"  prewarming allowlist set = %p (%@)",
            setv, (__bridge id)setv);

    // Patch the daemon's prewarming-bundle allowlist so EVERY XPC client
    // passes the `[set containsObject:clientSI]` gate in
    // _captureSourceServer_handleCopySourcesMessage. We don't mutate the
    // set's contents — we object_setClass it to a dynamically-built
    // subclass whose -containsObject: implementation always returns YES.
    // This is __DATA-clean (no __TEXT writes, no TXM concerns) and
    // limited to this single singleton instance.
    if (setv) {
      id theSet = (__bridge id)setv;
      Class origCls = object_getClass(theSet);
      Class allowCls = objc_allocateClassPair(
          origCls, "vcc_AlwaysAllowSet", 0);
      if (allowCls) {
        IMP yesImp = imp_implementationWithBlock(
            ^BOOL(__unused id self_, __unused id obj) { return YES; });
        Method orig = class_getInstanceMethod(origCls,
                                              @selector(containsObject:));
        const char *types = orig ? method_getTypeEncoding(orig) : "B@:@";
        class_addMethod(allowCls, @selector(containsObject:), yesImp, types);
        objc_registerClassPair(allowCls);
        object_setClass(theSet, allowCls);
        vcc_log(@"  swizzled set's class -> vcc_AlwaysAllowSet (orig=%s)",
                class_getName(origCls));
      } else {
        vcc_log(@"  objc_allocateClassPair returned nil (already registered?)");
      }
    }
  }


  // Force daemon's source-server init so `_sSourceList` is allocated.
  void *start_fn = vcc_dlsym_fn("FigCaptureSourceServerStart");
  if (start_fn) {
    ((void (*)(void))start_fn)();
    vcc_log(@"  called FigCaptureSourceServerStart()");
  }

  // Resolve _sSourceList structurally:
  //
  //   LC_SYMTAB → __captureSourceServer_initializeStatics_block_invoke
  //     (the dispatch_once init body — static text symbol, retained
  //      in the on-device DSC nlist even when static *data* symbols
  //      like `_sSourceList` itself are stripped)
  //     → BL CFArrayCreateMutable inside the block body
  //     → adrp+str x0, [Xn, #imm]  ← stores into _sSourceList
  //
  // Every link is a structural ARM64 pattern, so the chain is stable
  // across iOS revisions. The static-init function naming convention
  // (`<class>_initializeStatics_block_invoke`) has been used by Apple
  // since the iOS 14 era and persists through 26.x.
  uintptr_t fnCFArrayCreate = (uintptr_t)dlsym(RTLD_DEFAULT,
                                                "CFArrayCreateMutable");
  // The on-device nlist exports static text symbols with leading
  // underscores. Block-invoke names take one extra underscore vs the
  // outer C symbol — try the canonical first, plus a triple-_ variant
  // some clangs emit.
  static const char *kInitBlockNames[] = {
      "__captureSourceServer_initializeStatics_block_invoke",
      "___captureSourceServer_initializeStatics_block_invoke",
      NULL,
  };
  uintptr_t blockInvoke = 0;
  for (unsigned i = 0; kInitBlockNames[i]; i++) {
    blockInvoke = vcc_lookup_lc_symtab(&img, kInitBlockNames[i]);
    if (blockInvoke) {
      vcc_log(@"  init-statics block-invoke (%s) @ 0x%lx",
              kInitBlockNames[i], (unsigned long)blockInvoke);
      break;
    }
  }
  // If the symbol is stripped on-device (typical for the DSC), walk
  // the structural chain rooted at FigCaptureSourceServerStart to
  // find the dispatch_once block-invoke. The chain is:
  //
  //   FigCaptureSourceServerStart  (exported, addr known)
  //     `cmn x?, #0x1 ; b.ne <wrapper>`     (onceToken check)
  //   wrapper                       (`.cold.1`, static; addr from b.ne)
  //     `bl <cold.1>`               (we land here from b.ne; target IS cold.1)
  //   cold.1                        (5–6 instructions, static)
  //     `adrp x0,...; add x0, x0, ...`  (onceToken pointer)
  //     `adrp x1,...; add x1, x1, ...`  (block-constant pointer)
  //     `bl <dispatch_once stub>`
  //   block constant                (struct __Block_literal in __DATA_CONST)
  //     +0x10 = invoke pointer (PAC-signed; raw bytes are the function
  //                             address before signature stripping)
  if (!blockInvoke) {
    uintptr_t fnFigStart = (uintptr_t)dlsym(RTLD_DEFAULT,
                                            "FigCaptureSourceServerStart");
    if (fnFigStart) {
      fnFigStart = (uintptr_t)ptrauth_strip((void *)fnFigStart,
                                             ptrauth_key_function_pointer);
      uint32_t *ip = (uint32_t *)fnFigStart;
      uintptr_t coldWrapper = 0;
      // Step 1: find `cmn x?, #0x1; b.ne <target>` and decode target.
      // CMN (immediate) 64-bit, no shift:
      //   1011 0001 00ii iiii iiii iinn nnn1 1111
      // mask 0xFFC0001F, match 0xB100001F.
      // B.NE: 0101 0100 iiii iiii iiii iiii iii0 0001
      //   mask 0xFF00001F, match 0x54000001.
      for (unsigned i = 0; i < 256 && !coldWrapper; i++) {
        uint32_t cmn = ip[i];
        if ((cmn & 0xFFC0001Fu) != 0xB100001Fu) continue;
        // imm12 in bits[21:10]
        uint32_t imm = (cmn >> 10) & 0xFFFu;
        if (imm != 1) continue;
        if (i + 1 >= 256) continue;
        uint32_t bne = ip[i + 1];
        if ((bne & 0xFF00001Fu) != 0x54000001u) continue;
        int32_t imm19 = (int32_t)((bne & 0x00FFFFE0u) << 8) >> 11;
        coldWrapper = (uintptr_t)&ip[i + 1] + (intptr_t)imm19;
      }
      if (!coldWrapper) {
        vcc_log(@"  cmn+b.ne onceToken-check pattern not found in "
                @"FigCaptureSourceServerStart");
      } else {
        vcc_log(@"  cold-wrapper site @ 0x%lx", (unsigned long)coldWrapper);
        // Step 2: cold wrapper starts with `bl <cold.1>`. Decode.
        uint32_t bl = *(uint32_t *)coldWrapper;
        uintptr_t cold1 = 0;
        if ((bl & 0xFC000000u) == 0x94000000u) {
          int32_t imm26 = (int32_t)((bl & 0x03FFFFFFu) << 6) >> 4;
          cold1 = coldWrapper + (intptr_t)imm26;
          vcc_log(@"  cold.1 @ 0x%lx", (unsigned long)cold1);
        }
        // Step 3: walk cold.1 looking for the LAST `adrp x1,...; add x1,
        // x1, #imm` pair BEFORE the dispatch_once `bl`. That's the block
        // constant. cold.1 is typically only 5–6 instructions long.
        if (cold1) {
          uint32_t *cip = (uint32_t *)cold1;
          uintptr_t blockConst = 0;
          for (unsigned i = 0; i < 16; i++) {
            uint32_t add = cip[i];
            if ((add & 0xFF800000u) != 0x91000000u) continue;
            if ((add & 0x1Fu) != 1) continue;        // ADD x1, ...
            if (((add >> 5) & 0x1Fu) != 1) continue;
            uint32_t add_imm = (add >> 10) & 0xFFFu;
            // Walk back for matching adrp x1
            for (unsigned k = 1; k <= 4 && k <= i; k++) {
              uint32_t adrp = cip[i - k];
              if ((adrp & 0x9F000000u) != 0x90000000u) continue;
              if ((adrp & 0x1Fu) != 1) continue;
              uintptr_t adrp_pc = (uintptr_t)&cip[i - k];
              blockConst = vcc_adrp_target(adrp_pc, adrp) + add_imm;
              break;
            }
            if (blockConst) break;
          }
          if (!blockConst) {
            vcc_log(@"  block-constant adrp+add not found in cold.1");
          } else {
            vcc_log(@"  block constant @ 0x%lx", (unsigned long)blockConst);
            // Step 4: read invoke pointer at offset 0x10 within the
            // block constant. PAC-strip and assign as block-invoke.
            uintptr_t rawInvoke = *(uintptr_t *)(blockConst + 0x10);
            blockInvoke = (uintptr_t)ptrauth_strip(
                (void *)rawInvoke, ptrauth_key_function_pointer);
            vcc_log(@"  init block-invoke (via cold.1 chain) @ 0x%lx",
                    (unsigned long)blockInvoke);
          }
        }
      }
    }
  }
  uintptr_t sSourceListAddr = 0;
  if (blockInvoke) {
    uintptr_t globals[8] = {0};
    unsigned ng = vcc_collect_call_then_store_globals(blockInvoke,
                                                       /*maxInsns*/512,
                                                       /*lookahead*/12,
                                                       globals, 8);
    for (unsigned i = 0; i < ng; i++) {
      vcc_log(@"  init-statics global #%u: 0x%lx",
              i, (unsigned long)globals[i]);
    }
    // The init block initializes both `_sSourceListLock` (lock
    // handle) and `_sSourceList` (CFArray) in order. Walk the
    // discovered globals and pick the first one whose slot value
    // is actually a CFArray — that's the source list. The lock
    // entry has a void* mutex handle which malloc_zone validates
    // but isa fails the CFArray-class check.
    uintptr_t symLookup = vcc_lookup_lc_symtab(&img, "_sSourceList");
    if (symLookup) {
      vcc_log(@"  _sSourceList also in LC_SYMTAB at 0x%lx — using",
              (unsigned long)symLookup);
      sSourceListAddr = symLookup;
    } else {
      for (unsigned i = 0; i < ng; i++) {
        if (vcc_slot_value_is_cfarray(globals[i])) {
          uintptr_t val = 0;
          vcc_safe_read_ptr(globals[i], &val);
          vcc_log(@"  _sSourceList chosen (init-store #%u, CFArray @ 0x%lx) at 0x%lx",
                  i, (unsigned long)val, (unsigned long)globals[i]);
          sSourceListAddr = globals[i];
          break;
        }
      }
      if (!sSourceListAddr) {
        vcc_log(@"  no init-store global slot held a CFArray; falling "
                @"back to first init-store");
        if (ng > 0) sSourceListAddr = globals[0];
      }
    }
  } else {
    vcc_log(@"  init-statics block-invoke lookup failed");
  }
  if (!sSourceListAddr) {
    vcc_log(@"  data global resolve failed: _sSourceList not located");
    return;
  }

  // For the lock, the call-anchor approach requires knowing which
  // mutex-create function the daemon uses (FigSimpleMutexCreate / Init
  // / etc. — name varies across iOS). Skip locking entirely: our
  // dispatch_after fires after FigCaptureSourceServerStart's
  // dispatch_once block has finished, and we're the only writer to
  // _sSourceList during this init window.
  CFMutableArrayRef *sSourceListSlot =
      (CFMutableArrayRef *)sSourceListAddr;
  void **sSourceListLockSlot = NULL;
  void *lockPtr = NULL;
  vcc_log(@"  lock acquisition skipped (single-threaded init window)");
  vcc_log(@"  _sSourceList slot @ %p (list=%p), _sSourceListLock slot @ %p (lock=%p)",
          sSourceListSlot, *sSourceListSlot, sSourceListLockSlot, lockPtr);

  // Resolve FigCaptureSourceCreateFromBacking. Marked `external` in
  // CMCapture's symtab — should be in the dyld exports trie.
  void *create_p = vcc_dlsym_fn("FigCaptureSourceCreateFromBacking");
  if (!create_p) {
    vcc_log(@"  abort: FigCaptureSourceCreateFromBacking not dlsym-resolvable");
    return;
  }
  VCC_CreateFn create_fn = (VCC_CreateFn)create_p;

  // FigSimpleMutex helpers — best-effort: we still call them when lockPtr
  // is non-null (the daemon's mutex is alive), but skip when we couldn't
  // safely resolve the lock global. Resolution failure of the lock is
  // not fatal anymore — we operate as a single writer during init.
  void (*FigSimpleMutexLock)(void *) =
      (void (*)(void *))dlsym(RTLD_DEFAULT, "FigSimpleMutexLock");
  void (*FigSimpleMutexUnlock)(void *) =
      (void (*)(void *))dlsym(RTLD_DEFAULT, "FigSimpleMutexUnlock");

  id backing = vcc_build_backing();
  if (!backing) return;
  void *source = vcc_create_synthetic_source(create_fn, backing);
  if (!source) {
    vcc_log(@"  create returned NULL — abort");
    return;
  }

  vcc_probe_contract(source);

  // Dump ALL existing sources' AttributesDictionary so we can mirror what
  // the daemon's stock (bring-up / hardware) sources use for keys like
  // DeviceType, SmartCameraSupported, Streams, Ports, etc.
  {
    if (lockPtr && FigSimpleMutexLock) FigSimpleMutexLock(lockPtr);
    CFMutableArrayRef listSnap = *sSourceListSlot;
    CFIndex cnt = listSnap ? CFArrayGetCount(listSnap) : 0;
    vcc_log(@"  --- existing sources (count=%ld) ---", (long)cnt);
    void *(*CMBaseObjectGetVTable)(void *) =
        (void *(*)(void *))vcc_dlsym_fn("CMBaseObjectGetVTable");
    for (CFIndex i = 0; i < cnt; i++) {
      void *s = (void *)CFArrayGetValueAtIndex(listSnap, i);
      vcc_log(@"    source[%ld] = %p", (long)i, s);
      if (!CMBaseObjectGetVTable) continue;
      void *V = CMBaseObjectGetVTable(s);
      if (!V) continue;
      void **vtable_slot = (void **)((char *)V + 8);
      void *real_vtable_signed = *vtable_slot;
      uintptr_t vt_disc =
          __builtin_ptrauth_blend_discriminator(vtable_slot, 47377);
      void *real_vtable = __builtin_ptrauth_auth(real_vtable_signed,
                                                  ptrauth_key_asda, vt_disc);
      if (!real_vtable) continue;
      void **method6_slot = (void **)((char *)real_vtable + 48);
      void *method6_signed = *method6_slot;
      uintptr_t m6_disc =
          __builtin_ptrauth_blend_discriminator(method6_slot, 38693);
      void *method6 = __builtin_ptrauth_auth_and_resign(
          method6_signed, ptrauth_key_asia, m6_disc,
          ptrauth_key_function_pointer, 0);
      typedef int (*CP)(void *, CFStringRef, CFAllocatorRef, CFTypeRef *);
      CP copyProp = (CP)method6;
      CFStringRef k_attrs = vcc_cfconst(
          "kFigCaptureSourceProperty_AttributesDictionary");
      CFTypeRef out = NULL;
      int e = copyProp(s, k_attrs, kCFAllocatorDefault, &out);
      vcc_log(@"      attrs ret=%d -> %@", e, (__bridge id)out);
      if (out) CFRelease(out);
    }
    if (lockPtr && FigSimpleMutexUnlock) FigSimpleMutexUnlock(lockPtr);
  }

  if (lockPtr && FigSimpleMutexLock) FigSimpleMutexLock(lockPtr);
  CFMutableArrayRef list = *sSourceListSlot;
  if (!list) {
    vcc_log(@"  _sSourceList is NULL (server init not yet allocated it) — abort");
    if (lockPtr && FigSimpleMutexUnlock) FigSimpleMutexUnlock(lockPtr);
    return;
  }
  CFIndex preCount = CFArrayGetCount(list);
  CFArrayAppendValue(list, source);
  CFIndex postCount = CFArrayGetCount(list);
  if (lockPtr && FigSimpleMutexUnlock) FigSimpleMutexUnlock(lockPtr);
  vcc_log(@"  appended source — list %ld -> %ld", (long)preCount,
          (long)postCount);

  CFStringRef notifNameCF = vcc_cfconst(
      "kFigCaptureSourceNotification_SourceInfoArrayChanged");
  if (notifNameCF) {
    char buf[256];
    if (CFStringGetCString(notifNameCF, buf, sizeof(buf),
                           kCFStringEncodingUTF8)) {
      uint32_t status = notify_post(buf);
      vcc_log(@"  notify_post(%s) -> %u", buf, status);
    } else {
      vcc_log(@"  CFStringGetCString failed for notif name");
    }
  } else {
    vcc_log(@"  notif name CFString constant missing");
  }
}

// MARK: - frame-sender endpoint observation
//
// AVF capture clients (Camera.app, AVCaptureSession-using apps) tell the
// daemon "I want frames from camera X" by publishing a FrameSenderEndpoint
// — XPC handler `_captureSourceServer_handlePublishFrameSenderEndpointMessage`
// in CMCapture forwards each publish into the daemon-side class
// `CMCaptureFrameSenderEndpointsServerSideSingleton` via the
// `+addEndpoint:endpointUniqueID:endpointType:endpointPID:endpointProxyPID:
//   endpointAuditToken:endpointProxyAuditToken:endpointCameraUniqueID:`
// class method. Each endpoint carries the requesting client's audit token
// and the camera unique-ID they want frames for. Our synth's unique-ID is
// "vphone:vcam:0", so any endpoint whose cameraUniqueID matches that string
// is a client expecting frames from us.
//
// We swizzle the class method below to log every registration. Once we
// see Camera.app (or rpcserver_ios) publishing an endpoint for our synth,
// we know the next sub-stage is to build a `-[CMCaptureFrameSenderService
// sendFrame:]` call path that pushes CMSampleBuffers built from our shm
// `vcc_latest_frame` into each registered endpoint.
//
// This hook is observation-only; it does not deliver frames yet.

static SEL  vcc_add_endpoint_sel = NULL;
static Method vcc_add_endpoint_method = NULL;
static IMP    vcc_add_endpoint_orig_imp = NULL;

typedef BOOL (*VccAddEndpointFn)(id, SEL,
                                  id /*endpoint*/,
                                  id /*endpointUniqueID*/,
                                  int /*endpointType*/,
                                  int /*endpointPID*/,
                                  int /*endpointProxyPID*/,
                                  audit_token_t * /*auditToken*/,
                                  audit_token_t * /*proxyAuditToken*/,
                                  id /*endpointCameraUniqueID*/);

static BOOL vcc_add_endpoint_hook(id self, SEL _cmd,
                                   id endpoint,
                                   id endpointUniqueID,
                                   int endpointType,
                                   int endpointPID,
                                   int endpointProxyPID,
                                   audit_token_t *auditToken,
                                   audit_token_t *proxyAuditToken,
                                   id endpointCameraUniqueID) {
  vcc_log(@"  +addEndpoint cameraID=%@ pid=%d type=%d endpointUniqueID=%@",
          endpointCameraUniqueID, endpointPID, endpointType, endpointUniqueID);
  if (!vcc_add_endpoint_orig_imp) return NO;
  VccAddEndpointFn orig = (VccAddEndpointFn)vcc_add_endpoint_orig_imp;
  BOOL ok = orig(self, _cmd, endpoint, endpointUniqueID, endpointType,
                  endpointPID, endpointProxyPID, auditToken,
                  proxyAuditToken, endpointCameraUniqueID);
  vcc_log(@"  +addEndpoint orig returned %d", ok);
  return ok;
}

static void vcc_install_endpoint_hook(void) {
  Class cls = NSClassFromString(
      @"CMCaptureFrameSenderEndpointsServerSideSingleton");
  if (!cls) {
    vcc_log(@"  endpoint hook: class missing");
    return;
  }
  vcc_add_endpoint_sel = NSSelectorFromString(
      @"addEndpoint:endpointUniqueID:endpointType:endpointPID:"
      @"endpointProxyPID:endpointAuditToken:endpointProxyAuditToken:"
      @"endpointCameraUniqueID:");
  vcc_add_endpoint_method = class_getClassMethod(cls,
                                                  vcc_add_endpoint_sel);
  if (!vcc_add_endpoint_method) {
    vcc_log(@"  endpoint hook: class_getClassMethod returned NULL");
    return;
  }
  vcc_add_endpoint_orig_imp = method_setImplementation(
      vcc_add_endpoint_method, (IMP)vcc_add_endpoint_hook);
  vcc_log(@"  endpoint hook installed (orig=%p)",
          vcc_add_endpoint_orig_imp);
}

// MARK: - sink-node diagnostic dump
//
// Enumerate the BWImageQueueSinkNode + BWRemoteQueueSinkNode method tables
// at runtime so we can identify the actual init / setup / render selectors
// the session pipeline invokes. The static class-dump on the DSC binary
// returns garbled selptr references — at runtime the selector table is
// resolved, so this dump is reliable. Result lands in the vcamcaptured.log
// file; we use it to pick the right hook target for stage G.

static void vcc_dump_class(const char *name) {
  Class cls = NSClassFromString(@(name));
  if (!cls) {
    vcc_log(@"  class %s NOT FOUND", name);
    return;
  }
  Class super = class_getSuperclass(cls);
  vcc_log(@"  class %s @ %p (super=%s)", name, cls,
          super ? class_getName(super) : "<root>");

  unsigned int count = 0;
  Method *list = class_copyMethodList(cls, &count);
  vcc_log(@"  -- instance methods (%u) --", count);
  for (unsigned i = 0; i < count; i++) {
    Method m = list[i];
    SEL s = method_getName(m);
    IMP imp = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    vcc_log(@"    -[%s %@]  imp=%p types=%s", name,
            NSStringFromSelector(s), (void *)imp,
            types ? types : "?");
  }
  free(list);

  Class meta = object_getClass((id)cls);
  count = 0;
  Method *clist = class_copyMethodList(meta, &count);
  vcc_log(@"  -- class methods (%u) --", count);
  for (unsigned i = 0; i < count; i++) {
    Method m = clist[i];
    SEL s = method_getName(m);
    IMP imp = method_getImplementation(m);
    vcc_log(@"    +[%s %@]  imp=%p", name,
            NSStringFromSelector(s), (void *)imp);
  }
  free(clist);
}

static void vcc_dump_sink_node_methods(void) {
  vcc_log(@"---- sink-node method dump ----");
  vcc_dump_class("BWSinkNode");
  vcc_dump_class("BWImageQueueSinkNode");
  vcc_dump_class("BWRemoteQueueSinkNode");
  vcc_dump_class("BWFigCaptureSession");
  vcc_dump_class("BWFigCaptureDeviceVendor");
  vcc_dump_class("FigCaptureSourceBacking");
  vcc_dump_class("FigCaptureVideoSourceBacking");
  vcc_dump_class("FigCameraViewfinderStream");
  vcc_dump_class("FigCameraViewfinderSessionLocal");
  vcc_dump_class("FigCameraViewfinderLocal");
  vcc_dump_class("BWPreviewTimeMachineSinkNode");
  // Photo-path classes for capturePhoto debugging
  vcc_dump_class("BWStillImageCaptureCoordinator");
  vcc_dump_class("BWStillImageSampleBufferSinkNode");
  vcc_dump_class("BWStillImageProcessorController");
  vcc_dump_class("BWFigCaptureStillImageRequest");
  vcc_dump_class("FigCaptureCameraSourcePipeline");
  vcc_dump_class("FigCaptureSourcePipeline");
  vcc_log(@"---- end sink-node method dump ----");
}

// MARK: - sink observation hooks
//
// Stage G observation pass: swizzle the two sink classes' init + render
// methods. Goals:
//   1) Confirm whether sinks are instantiated when an AVF client opens our
//      synth source (i.e. is the pipeline starved at the SOURCE end or at the
//      configuration end?).
//   2) See whether ANY renderSampleBuffer:forInput: calls fire — if they do,
//      we know the pipeline runs and we just need to substitute the
//      sample-buffer contents.
//   3) Capture sink instance + input identifier on first real call so we can
//      drive them ourselves on a timer if the source-side stays starved.

static NSMutableArray *vcc_captured_sinks = nil;  // weak refs via NSValue
static NSValue *vcc_first_input_ref = nil;
static unsigned long vcc_render_call_count = 0;
static unsigned long vcc_iqsn_init_count = 0;
static unsigned long vcc_rqsn_init_count = 0;

static IMP vcc_iqsn_init_orig = NULL;
static IMP vcc_rqsn_init_orig = NULL;
static IMP vcc_iqsn_render_orig = NULL;
static IMP vcc_rqsn_render_orig = NULL;

typedef id (*VccIqsnInitFn)(
    id self, SEL _cmd,
    BOOL hfrSupport, BOOL ispJitterCompensationEnabled,
    audit_token_t auditToken, id sinkID);

typedef id (*VccRqsnInitFn)(
    id self, SEL _cmd,
    uint32_t mediaType, audit_token_t auditToken, id sinkID,
    id cameraInfoByPortType);

typedef void (*VccRenderFn)(
    id self, SEL _cmd, CMSampleBufferRef cmsb, id input);

static id vcc_iqsn_init_hook(
    id self, SEL _cmd,
    BOOL hfrSupport, BOOL ispJitterCompensationEnabled,
    audit_token_t auditToken, id sinkID) {
  VccIqsnInitFn orig = (VccIqsnInitFn)vcc_iqsn_init_orig;
  id ret = orig(self, _cmd, hfrSupport, ispJitterCompensationEnabled,
                auditToken, sinkID);
  vcc_iqsn_init_count++;
  vcc_log(@"  [IQSN init] -> %p sinkID=%@ count=%lu",
          ret, sinkID, vcc_iqsn_init_count);
  if (ret) {
    if (!vcc_captured_sinks)
      vcc_captured_sinks = [NSMutableArray array];
    [vcc_captured_sinks addObject:[NSValue valueWithPointer:(__bridge void *)ret]];
  }
  return ret;
}

static id vcc_rqsn_init_hook(
    id self, SEL _cmd,
    uint32_t mediaType, audit_token_t auditToken, id sinkID,
    id cameraInfoByPortType) {
  VccRqsnInitFn orig = (VccRqsnInitFn)vcc_rqsn_init_orig;
  id ret = orig(self, _cmd, mediaType, auditToken, sinkID,
                cameraInfoByPortType);
  vcc_rqsn_init_count++;
  vcc_log(@"  [RQSN init] -> %p mediaType=0x%x sinkID=%@ count=%lu",
          ret, mediaType, sinkID, vcc_rqsn_init_count);
  if (ret) {
    if (!vcc_captured_sinks)
      vcc_captured_sinks = [NSMutableArray array];
    [vcc_captured_sinks addObject:[NSValue valueWithPointer:(__bridge void *)ret]];
  }
  return ret;
}

static void vcc_iqsn_render_hook(
    id self, SEL _cmd, CMSampleBufferRef cmsb, id input) {
  vcc_render_call_count++;
  if (vcc_render_call_count <= 5 || (vcc_render_call_count & 63) == 1) {
    vcc_log(@"  [IQSN render] self=%p cmsb=%p input=%p inputCls=%@ #%lu",
            self, cmsb, input, NSStringFromClass([input class]),
            vcc_render_call_count);
    if (input && !vcc_first_input_ref) {
      vcc_first_input_ref = [NSValue valueWithPointer:(__bridge void *)input];
    }
  }
  VccRenderFn orig = (VccRenderFn)vcc_iqsn_render_orig;
  orig(self, _cmd, cmsb, input);
}

static void vcc_rqsn_render_hook(
    id self, SEL _cmd, CMSampleBufferRef cmsb, id input) {
  vcc_render_call_count++;
  if (vcc_render_call_count <= 5 || (vcc_render_call_count & 63) == 1) {
    vcc_log(@"  [RQSN render] self=%p cmsb=%p input=%p inputCls=%@ #%lu",
            self, cmsb, input, NSStringFromClass([input class]),
            vcc_render_call_count);
  }
  VccRenderFn orig = (VccRenderFn)vcc_rqsn_render_orig;
  orig(self, _cmd, cmsb, input);
}

static void vcc_swizzle_method(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) {
    vcc_log(@"  swizzle: -[%s %@] missing", class_getName(cls),
            NSStringFromSelector(sel));
    return;
  }
  *outOrig = method_setImplementation(m, newImp);
  vcc_log(@"  swizzled -[%s %@] (orig imp=%p)", class_getName(cls),
          NSStringFromSelector(sel), *outOrig);
}

// Extra observation: hook -[BWFigCaptureDeviceVendor copyDeviceWithID:forClient:informClientWhenDeviceAvailableAgain:error:]
// to see when an AVF client asks for our device. If this fires, we know the
// session is at least requesting a device for our synth. If it doesn't fire,
// the client never even reached the device-vendor stage (gated upstream).

static IMP vcc_copy_device_orig = NULL;

// Type encoding observed on iOS 26.5 cameracaptured:
//   @40@0:8@16i24B28^i32
// => id (*)(id self, SEL _cmd, NSString *deviceID, int clientPID,
//            BOOL informClient, int *err)
// The earlier disabled stub mis-typed clientPID as `id`, causing ARC to
// emit objc_retain on an integer register and crash inside the hook
// prologue.

typedef id (*VccCopyDeviceFn)(id self, SEL _cmd, NSString *deviceID,
                              int clientPID, BOOL informClient, int *err);

static NSString *const kVccSynthDeviceID = @"vphone:vcam:device:0";
static Class       vcc_synth_device_class = Nil;

// Forward decls.
static void vcc_init_synth_device_class(void);
__attribute__((ns_returns_retained))
static id   vcc_make_synth_device(NSString *deviceID);

static id vcc_copy_device_hook(id self, SEL _cmd, NSString *deviceID,
                               int clientPID, BOOL informClient, int *err) {
  vcc_log(@"  [copyDeviceWithID] deviceID=%@ clientPID=%d inform=%d",
          deviceID, clientPID, informClient);

  if ([deviceID isEqualToString:kVccSynthDeviceID]) {
    id synth = vcc_make_synth_device(deviceID);
    if (err) *err = 0;
    vcc_log(@"  [copyDeviceWithID] -> synth %p (class=%s err=0)",
            synth, object_getClassName(synth));
    return synth;
  }

  VccCopyDeviceFn orig = (VccCopyDeviceFn)vcc_copy_device_orig;
  id ret = orig(self, _cmd, deviceID, clientPID, informClient, err);
  int errval = err ? *err : 0;
  vcc_log(@"  [copyDeviceWithID] returned %p (err=%d)", ret, errval);
  return ret;
}

// MARK: - synthetic FigCaptureDevice subclass
//
// Subclass `BWFigCaptureDevice` at runtime via objc_allocateClassPair, then
// instantiate via +alloc. We write the deviceID NSString directly into the
// inherited ivar slot. Ivar offsets are resolved at synth-class init time
// via the ObjC runtime (class_getInstanceVariable + ivar_getOffset) so
// the layout follows whatever Apple ships, not a hardcoded 26.5 value.
//
// To prevent the crash in
// `-[BWFigCaptureDevice _copyProperty:requireSupported:error:]` (where the
// inherited body would deref the NULL figCaptureDevice via
// CMBaseObjectGetVTable), we OVERRIDE the public ObjC wrappers
// (-copyProperty:error:, -getProperty:error:, -copyPropertyIfSupported:error:)
// in our subclass so they never call _copyProperty:. Each override returns
// canned values for known properties and sets *err=-12787 ("property not
// supported") for everything else.

// Resolved at synth-class init. -1 until populated; vcc_init_synth_device_class
// refuses to register the synth class if resolution fails so we never write
// to a stale offset.
static ptrdiff_t kBWFigCaptureDevice_deviceID_Offset = -1;

// Resolve an instance-variable offset by name on `cls`, trying each
// candidate in `names` (NULL-terminated) until one matches. Returns -1
// if none match. Logs the outcome so a future iOS rename surfaces in
// the install log instead of silently writing to a wrong slot.
static ptrdiff_t vcc_resolve_ivar(Class cls, const char *what,
                                   const char *const *names) {
  if (!cls) {
    vcc_log(@"  ivar %s: class missing", what ? what : "?");
    return -1;
  }
  for (unsigned i = 0; names[i]; i++) {
    Ivar iv = class_getInstanceVariable(cls, names[i]);
    if (iv) {
      ptrdiff_t off = ivar_getOffset(iv);
      vcc_log(@"  ivar %s -> %s @ +0x%lx", what ? what : "?",
              names[i], (long)off);
      return off;
    }
  }
  vcc_log(@"  ivar %s: no candidate matched on %s", what ? what : "?",
          class_getName(cls));
  return -1;
}

// Cached CF constants — resolved lazily from CMCaptureCore / CMCaptureDevice.
static CFStringRef vcc_cf_kClock              = NULL;
static CFStringRef vcc_cf_kUnitInfo           = NULL;

static void vcc_load_synth_cfconsts(void) {
  if (!vcc_cf_kClock) vcc_cf_kClock = vcc_cfconst("kFigCaptureDeviceProperty_Clock");
  if (!vcc_cf_kUnitInfo) vcc_cf_kUnitInfo = vcc_cfconst("kFigCaptureDeviceProperty_UnitInfo");
}

// Returns a CMClockRef (CoreMedia host time clock). Lifetime tied to the
// process — we never release it.
static CFTypeRef vcc_get_host_clock(void) {
  static CFTypeRef cached = NULL;
  if (cached) return cached;
  typedef CFTypeRef (*GetHostClockFn)(void);
  GetHostClockFn fn = (GetHostClockFn)dlsym(RTLD_DEFAULT, "CMClockGetHostTimeClock");
  if (!fn) {
    vcc_log(@"  synth-dev: CMClockGetHostTimeClock missing");
    return NULL;
  }
  cached = fn();
  if (cached) CFRetain(cached);  // keep it alive
  return cached;
}

// copyProperty: follows the +1 "copy" convention — return must be retained.
__attribute__((ns_returns_retained))
static id vcc_synth_copy_property(id self, SEL _cmd, id property, int *err) {
  NSString *propStr = [property description];
  if (vcc_cf_kClock &&
      [(__bridge id)vcc_cf_kClock isEqual:property]) {
    CFTypeRef clk = vcc_get_host_clock();
    if (err) *err = clk ? 0 : -12787;
    vcc_log(@"  [SynthDev copyProperty:Clock] -> %p", clk);
    if (!clk) return nil;
    CFRetain(clk);
    return (__bridge_transfer id)clk;  // +1 retained, ns_returns_retained
  }
  if (err) *err = -12787;
  vcc_log(@"  [SynthDev copyProperty:%@] -> nil (err=-12787)", propStr);
  return nil;
}

__attribute__((ns_returns_retained))
static id vcc_synth_copy_property_if_supported(id self, SEL _cmd,
                                                id property, int *err) {
  NSString *propStr = [property description];
  if (err) *err = 0;
  vcc_log(@"  [SynthDev copyPropertyIfSupported:%@] -> nil", propStr);
  return nil;
}

static int vcc_synth_get_property(id self, SEL _cmd, id property, int *err) {
  NSString *propStr = [property description];
  if (err) *err = -12787;
  vcc_log(@"  [SynthDev getProperty:%@] -> 0 (err=-12787)", propStr);
  return 0;
}

static id vcc_synth_supported_properties(id self, SEL _cmd) {
  // BWFigVideoCaptureDevice expects an NSDictionary here — it queries the
  // returned object via -objectForKeyedSubscript: for property keys (e.g.
  // kFigCaptureDeviceProperty_SupportedSynchronizedStreamsGroups). Returning
  // an NSSet would crash on that selector.
  vcc_log(@"  [SynthDev supportedProperties] -> empty dict");
  return [NSDictionary dictionary];
}

static id vcc_synth_unique_id(id self, SEL _cmd) {
  void **slot = (void **)((char *)(__bridge void *)self
                          + kBWFigCaptureDevice_deviceID_Offset);
  id idVal = (__bridge id)(*slot);
  return idVal;
}

static void vcc_synth_dealloc(id self, SEL _cmd) {
  void **slot = (void **)((char *)(__bridge void *)self
                          + kBWFigCaptureDevice_deviceID_Offset);
  if (*slot) {
    CFRelease((CFTypeRef)*slot);
    *slot = NULL;
  }
  // Skip parent's -dealloc and finish destruction ourselves. ARC marks
  // objc_destructInstance as unavailable, so resolve via dlsym.
  static void *(*destruct)(id) = NULL;
  if (!destruct) destruct = dlsym(RTLD_DEFAULT, "objc_destructInstance");
  if (destruct) destruct(self);
  free((__bridge void *)self);
}

static void vcc_init_synth_device_class(void) {
  if (vcc_synth_device_class) return;
  Class parent = NSClassFromString(@"BWFigCaptureDevice");
  if (!parent) {
    vcc_log(@"  synth-dev: BWFigCaptureDevice class missing");
    return;
  }
  static const char *const kDeviceIDNames[] = {
      "_deviceID", "deviceID", NULL,
  };
  kBWFigCaptureDevice_deviceID_Offset = vcc_resolve_ivar(
      parent, "BWFigCaptureDevice.deviceID", kDeviceIDNames);
  if (kBWFigCaptureDevice_deviceID_Offset < 0) {
    vcc_log(@"  synth-dev: required ivar not found — registration aborted");
    return;
  }
  vcc_load_synth_cfconsts();

  Class cls = objc_allocateClassPair(parent, "VccSynthDevice", 0);
  if (!cls) {
    vcc_log(@"  synth-dev: objc_allocateClassPair failed");
    return;
  }

  class_addMethod(cls, @selector(copyProperty:error:),
                  (IMP)vcc_synth_copy_property, "@@:@^i");
  class_addMethod(cls, @selector(copyPropertyIfSupported:error:),
                  (IMP)vcc_synth_copy_property_if_supported, "@@:@^i");
  class_addMethod(cls, @selector(getProperty:error:),
                  (IMP)vcc_synth_get_property, "i@:@^i");
  class_addMethod(cls, @selector(supportedProperties),
                  (IMP)vcc_synth_supported_properties, "@@:");
  class_addMethod(cls, @selector(uniqueID),
                  (IMP)vcc_synth_unique_id, "@@:");
  class_addMethod(cls, NSSelectorFromString(@"dealloc"),
                  (IMP)vcc_synth_dealloc, "v@:");

  objc_registerClassPair(cls);
  vcc_synth_device_class = cls;
  vcc_log(@"  registered VccSynthDevice : BWFigCaptureDevice (cls=%p)", cls);
}

// MARK: - synthetic FigCaptureStream subclass
//
// Subclass BWFigCaptureStream. Ivar offsets are resolved at synth-class
// init time via the ObjC runtime so the layout follows whatever Apple
// ships. Historical disasm of -[BWFigCaptureStream initWith…] and the
// trivial ivar accessors gave us the slot semantics:
//
//   figCaptureStream  : C handle, leave NULL
//   portType          : NSString
//   uniqueID          : NSString
//   isSpecialDeviceID : BOOL (we don't touch it)
//   property cache    : NSDictionary — DO NOT write a non-dict here.
//             Earlier iteration put a deviceID string in the slot; the
//             inherited -_copyProperty: calls [cache
//             objectForKeyedSubscript:key] unconditionally, and the
//             unrecognized-selector crashed cameracaptured. Leave NULL
//             so the lookup short-circuits to nil.
//   streaming         : BOOL — set to 1 so -streaming returns YES.

static Class vcc_synth_stream_class = Nil;
// Resolved at synth-class init. portType/uniqueID are required (-1 -> abort
// class registration); streaming is optional (-1 -> skip the YES poke).
static ptrdiff_t kBWFigCaptureStream_portType_Offset  = -1;
static ptrdiff_t kBWFigCaptureStream_uniqueID_Offset  = -1;
static ptrdiff_t kBWFigCaptureStream_streaming_Offset = -1;

static CFStringRef vcc_cf_kSupportedFormatsArray = NULL;

__attribute__((ns_returns_retained))
static id vcc_synth_stream_copy_property(id self, SEL _cmd, id property,
                                          int *err) {
  if (!vcc_cf_kSupportedFormatsArray) {
    vcc_cf_kSupportedFormatsArray =
        vcc_cfconst("kFigCaptureStreamProperty_SupportedFormatsArray");
  }
  if (vcc_cf_kSupportedFormatsArray &&
      [(__bridge id)vcc_cf_kSupportedFormatsArray isEqual:property]) {
    if (err) *err = 0;
    // Empirically: empty SupportedFormatsArray returns +1-retained per
    // ns_returns_retained convention. Non-empty arrays (objects or dicts)
    // trip a daemon-side validation that we don't satisfy → isRunning=0.
    // The AVCaptureDevice.formats list is populated separately via
    // -[FigCaptureSourceBacking initWith…formats:…], so the AVF client
    // still sees both formats and selects activeFormat.
    vcc_log(@"  [SynthStream copyProperty:SupportedFormatsArray] -> empty array");
    return [[NSArray alloc] init];
  }
  if (err) *err = -12787;
  vcc_log(@"  [SynthStream copyProperty:%@] -> nil (err=-12787)",
          [property description]);
  return nil;
}

__attribute__((ns_returns_retained))
static id vcc_synth_stream_copy_property_if_supported(id self, SEL _cmd,
                                                       id property, int *err) {
  if (err) *err = 0;
  vcc_log(@"  [SynthStream copyPropertyIfSupported:%@] -> nil",
          [property description]);
  return nil;
}

static int vcc_synth_stream_get_property(id self, SEL _cmd, id property,
                                          int *err) {
  NSString *propStr = [property description];
  // The daemon's session-start path queries PixelSize on the stream and
  // treats err=-12787 as fatal — propagates up to AVCaptureSessionRuntimeError
  // and stops the session. Return 0 with err=0 (supported, zero value) so
  // the check passes. Same defensive default for any other property we
  // haven't otherwise explicitly handled.
  if (err) *err = 0;
  vcc_log(@"  [SynthStream getProperty:%@] -> 0 err=0", propStr);
  return 0;
}

static int vcc_synth_stream_get_property_if_supported(id self, SEL _cmd,
                                                      id property, int *err) {
  if (err) *err = 0;
  vcc_log(@"  [SynthStream getPropertyIfSupported:%@] -> 0 err=0",
          [property description]);
  return 0;
}

// Catches the private _copyProperty:requireSupported:error: path. Same
// effective result as -copyProperty:error: (canned values for known
// keys, -12787 otherwise) — just a 3rd BOOL arg.
static id vcc_synth_stream_underscore_copy_property(id self, SEL _cmd,
                                                     id property,
                                                     BOOL requireSupported,
                                                     int *err) {
  return vcc_synth_stream_copy_property(self, @selector(copyProperty:error:),
                                         property, err);
}

static id vcc_synth_stream_supported_properties(id self, SEL _cmd) {
  return [NSDictionary dictionary];
}

static int vcc_synth_stream_set_property(id self, SEL _cmd, id property,
                                          id value) {
  vcc_log(@"  [SynthStream setProperty:%@] (ignored)", [property description]);
  return 0;
}

static void vcc_synth_stream_dealloc(id self, SEL _cmd) {
  void *p = (__bridge void *)self;
  void **portTypeSlot = (void **)((char *)p + kBWFigCaptureStream_portType_Offset);
  void **uniqueIDSlot = (void **)((char *)p + kBWFigCaptureStream_uniqueID_Offset);
  if (*portTypeSlot) { CFRelease(*portTypeSlot); *portTypeSlot = NULL; }
  if (*uniqueIDSlot) { CFRelease(*uniqueIDSlot); *uniqueIDSlot = NULL; }
  // Skip parent's -dealloc (would touch many uninitialized ivars). Manually
  // destruct + free the storage. ARC blocks direct objc_destructInstance,
  // so resolve via dlsym.
  static void *(*destruct)(id) = NULL;
  if (!destruct) destruct = dlsym(RTLD_DEFAULT, "objc_destructInstance");
  if (destruct) destruct(self);
  free((__bridge void *)self);
}

static void vcc_init_synth_stream_class(void) {
  if (vcc_synth_stream_class) return;
  Class parent = NSClassFromString(@"BWFigCaptureStream");
  if (!parent) {
    vcc_log(@"  synth-stream: BWFigCaptureStream class missing");
    return;
  }
  static const char *const kPortTypeNames[]  = {"_portType", "portType", NULL};
  static const char *const kUniqueIDNames[]  = {"_uniqueID", "uniqueID", NULL};
  static const char *const kStreamingNames[] = {
      "_streaming", "streaming", "_isStreaming", "isStreaming", NULL,
  };
  kBWFigCaptureStream_portType_Offset = vcc_resolve_ivar(
      parent, "BWFigCaptureStream.portType", kPortTypeNames);
  kBWFigCaptureStream_uniqueID_Offset = vcc_resolve_ivar(
      parent, "BWFigCaptureStream.uniqueID", kUniqueIDNames);
  kBWFigCaptureStream_streaming_Offset = vcc_resolve_ivar(
      parent, "BWFigCaptureStream.streaming", kStreamingNames);
  if (kBWFigCaptureStream_portType_Offset < 0 ||
      kBWFigCaptureStream_uniqueID_Offset < 0) {
    vcc_log(@"  synth-stream: required ivar(s) not found — registration aborted");
    return;
  }
  Class cls = objc_allocateClassPair(parent, "VccSynthStream", 0);
  if (!cls) {
    vcc_log(@"  synth-stream: objc_allocateClassPair failed");
    return;
  }
  class_addMethod(cls, @selector(copyProperty:error:),
                  (IMP)vcc_synth_stream_copy_property, "@@:@^i");
  class_addMethod(cls, @selector(copyPropertyIfSupported:error:),
                  (IMP)vcc_synth_stream_copy_property_if_supported, "@@:@^i");
  class_addMethod(cls, @selector(getProperty:error:),
                  (IMP)vcc_synth_stream_get_property, "i@:@^i");
  class_addMethod(cls, @selector(getPropertyIfSupported:error:),
                  (IMP)vcc_synth_stream_get_property_if_supported, "i@:@^i");
  // Also override the underlying _copyProperty:requireSupported:error:
  // so any inherited call path that bypasses the public wrappers (e.g.
  // -getPropertyIfSupported: in older code paths) still lands here
  // instead of crashing on the NULL figCaptureStream vtable deref.
  class_addMethod(cls,
                  NSSelectorFromString(@"_copyProperty:requireSupported:error:"),
                  (IMP)vcc_synth_stream_underscore_copy_property, "@@:@B^i");
  class_addMethod(cls, @selector(supportedProperties),
                  (IMP)vcc_synth_stream_supported_properties, "@@:");
  class_addMethod(cls, @selector(setProperty:value:),
                  (IMP)vcc_synth_stream_set_property, "i@:@@");
  class_addMethod(cls, NSSelectorFromString(@"dealloc"),
                  (IMP)vcc_synth_stream_dealloc, "v@:");
  objc_registerClassPair(cls);
  vcc_synth_stream_class = cls;
  vcc_log(@"  registered VccSynthStream : BWFigCaptureStream (cls=%p)", cls);
}

// Strong references to every manufactured synth stream, so they can't be
// released early by autorelease churn or refcount bugs in our dealloc.
// Memory grows by one stream per session start; acceptable for diagnosis.
static NSMutableArray *vcc_synth_streams_strong_refs = nil;

__attribute__((ns_returns_retained))
static id vcc_make_synth_stream(NSString *uniqueID, NSString *deviceID,
                                  NSString *portType) {
  if (!vcc_synth_stream_class) vcc_init_synth_stream_class();
  if (!vcc_synth_stream_class) return nil;
  // Use +alloc via runtime — ARC-safe (class_createInstance is
  // OBJC_ARC_UNAVAILABLE and the retain-count semantics don't match what
  // ARC expects). Function attributed ns_returns_retained so callers
  // treat the +1 from alloc correctly without autorelease.
  id s = ((id (*)(Class, SEL))objc_msgSend)(vcc_synth_stream_class,
                                              @selector(alloc));
  if (!s) return nil;

  void *p = (__bridge void *)s;
  *(void **)((char *)p + kBWFigCaptureStream_portType_Offset) =
      (void *)CFBridgingRetain([portType copy]);
  *(void **)((char *)p + kBWFigCaptureStream_uniqueID_Offset) =
      (void *)CFBridgingRetain([uniqueID copy]);
  // property-cache NSDictionary ivar intentionally left NULL — the
  // parent class unconditionally sends -objectForKeyedSubscript: to it,
  // and an earlier iteration that stored deviceID there crashed with
  // unrecognized-selector. The deviceID isn't read off the stream by
  // inherited code anyway (only a per-stream BOOL comparison result is).
  (void)deviceID;
  // streaming BOOL — set to 1 so -streaming returns YES. Optional:
  // skip if the ivar isn't present on this build.
  if (kBWFigCaptureStream_streaming_Offset >= 0) {
    *(uint8_t *)((char *)p + kBWFigCaptureStream_streaming_Offset) = 1;
  }

  // Pin so dealloc never runs — diagnostic to isolate the autorelease-
  // pool-drain crash. Each session start leaks one stream.
  if (!vcc_synth_streams_strong_refs) {
    vcc_synth_streams_strong_refs = [NSMutableArray new];
  }
  [vcc_synth_streams_strong_refs addObject:s];

  vcc_log(@"  synth-stream: %p uid=%@ port=%@ devID=%@",
          s, uniqueID, portType, deviceID);
  return s;
}

// MARK: - hook BWFigCaptureDeviceVendor copyStreamsWithUniqueIDs:forDevice:
//
// When forDevice is our synth, manufacture one VccSynthStream per requested
// uniqueID so that the vendor's identity-matching inner loop in
// `-_copyStreamsForAttributes:` produces a result array whose count matches
// the input attributes count.

static IMP vcc_copy_streams_orig = NULL;
typedef id (*VccCopyStreamsFn)(id self, SEL _cmd, NSArray *uniqueIDs,
                                id forDevice, int priority, int *err);

static id vcc_copy_streams_hook(id self, SEL _cmd, NSArray *uniqueIDs,
                                 id forDevice, int priority, int *err) {
  if (forDevice && object_getClass(forDevice) == vcc_synth_device_class) {
    vcc_log(@"  [copyStreamsWithUniqueIDs forDevice:synth] ids=%@", uniqueIDs);
    NSMutableArray *out = [NSMutableArray array];
    void *p = (__bridge void *)forDevice;
    NSString *devID = (__bridge NSString *)(*(void **)((char *)p + kBWFigCaptureDevice_deviceID_Offset));
    for (NSString *uid in uniqueIDs) {
      id s = vcc_make_synth_stream(uid, devID, @"Back");
      if (s) [out addObject:s];
    }
    if (err) *err = 0;
    vcc_log(@"  [copyStreamsWithUniqueIDs] -> %lu streams",
            (unsigned long)out.count);
    return out;
  }
  VccCopyStreamsFn orig = (VccCopyStreamsFn)vcc_copy_streams_orig;
  return orig(self, _cmd, uniqueIDs, forDevice, priority, err);
}

static void vcc_install_copy_streams_hook(void) {
  Class cls = NSClassFromString(@"BWFigCaptureDeviceVendor");
  if (!cls) return;
  SEL sel = NSSelectorFromString(
      @"copyStreamsWithUniqueIDs:forDevice:deviceClientPriority:error:");
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) {
    vcc_log(@"  copyStreams hook: selector missing");
    return;
  }
  vcc_copy_streams_orig = method_setImplementation(m,
                                                    (IMP)vcc_copy_streams_hook);
  vcc_log(@"  swizzled -[BWFigCaptureDeviceVendor copyStreamsWithUniqueIDs:...] orig=%p",
          vcc_copy_streams_orig);
}

static IMP vcc_copy_streams_from_orig = NULL;
typedef id (*VccCopyStreamsFromFn)(id self, SEL _cmd, id fromDevice,
                                    NSArray *positions, NSArray *deviceTypes,
                                    int prio, BOOL allowsLoss, int *err);

static id vcc_copy_streams_from_hook(id self, SEL _cmd, id fromDevice,
                                      NSArray *positions, NSArray *deviceTypes,
                                      int prio, BOOL allowsLoss, int *err) {
  if (fromDevice && object_getClass(fromDevice) == vcc_synth_device_class) {
    vcc_log(@"  [copyStreamsFromDevice:synth positions=%@ deviceTypes=%@]",
            positions, deviceTypes);
    NSMutableArray *out = [NSMutableArray array];
    void *p = (__bridge void *)fromDevice;
    NSString *devID = (__bridge NSString *)(*(void **)((char *)p + kBWFigCaptureDevice_deviceID_Offset));
    NSUInteger count = positions.count;
    for (NSUInteger i = 0; i < count; i++) {
      NSString *uid = [NSString stringWithFormat:@"%@:stream:%lu",
                                                  devID, (unsigned long)i];
      id s = vcc_make_synth_stream(uid, devID, @"Back");
      if (s) [out addObject:s];
    }
    if (err) *err = 0;
    vcc_log(@"  [copyStreamsFromDevice] -> %lu streams",
            (unsigned long)out.count);
    return out;
  }
  VccCopyStreamsFromFn orig = (VccCopyStreamsFromFn)vcc_copy_streams_from_orig;
  return orig(self, _cmd, fromDevice, positions, deviceTypes,
              prio, allowsLoss, err);
}

static void vcc_install_copy_streams_from_hook(void) {
  Class cls = NSClassFromString(@"BWFigCaptureDeviceVendor");
  if (!cls) return;
  SEL sel = NSSelectorFromString(
      @"copyStreamsFromDevice:positions:deviceTypes:deviceClientPriority:allowsStreamControlLoss:error:");
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) {
    vcc_log(@"  copyStreamsFromDevice hook: selector missing");
    return;
  }
  vcc_copy_streams_from_orig = method_setImplementation(m,
                                                         (IMP)vcc_copy_streams_from_hook);
  vcc_log(@"  swizzled -[BWFigCaptureDeviceVendor copyStreamsFromDevice:...] orig=%p",
          vcc_copy_streams_from_orig);
}

__attribute__((ns_returns_retained))
static id vcc_make_synth_device(NSString *deviceID) {
  if (!vcc_synth_device_class) vcc_init_synth_device_class();
  if (!vcc_synth_device_class) return nil;

  // Use +alloc via runtime — ARC-safe. Function attributed
  // ns_returns_retained so ARC treats the alloc'd +1 correctly.
  id d = ((id (*)(Class, SEL))objc_msgSend)(vcc_synth_device_class,
                                              @selector(alloc));
  if (!d) {
    vcc_log(@"  synth-dev: class_createInstance failed");
    return nil;
  }
  // Write deviceID at the runtime-resolved ivar offset via
  // CFBridgingRetain so our -dealloc override CFRelease's it.
  NSString *idCopy = [deviceID copy];
  void *slotBase  = (__bridge void *)d;
  void **slot     = (void **)((char *)slotBase + kBWFigCaptureDevice_deviceID_Offset);
  *slot = (void *)CFBridgingRetain(idCopy);

  // Pin so dealloc never runs — diagnostic to isolate the autorelease
  // pool drain crash. Each session start leaks one synth device.
  static NSMutableArray *vcc_synth_devs_strong_refs = nil;
  if (!vcc_synth_devs_strong_refs) {
    vcc_synth_devs_strong_refs = [NSMutableArray new];
  }
  [vcc_synth_devs_strong_refs addObject:d];

  vcc_log(@"  synth-dev: %p deviceID=%@ (slot@+0x%lx=%p)",
          d, idCopy, (long)kBWFigCaptureDevice_deviceID_Offset, *slot);
  return d;
}

static void vcc_install_device_vendor_hook(void) {
  Class cls = NSClassFromString(@"BWFigCaptureDeviceVendor");
  if (!cls) {
    vcc_log(@"  device-vendor hook: class missing");
    return;
  }
  SEL sel = NSSelectorFromString(
      @"copyDeviceWithID:forClient:informClientWhenDeviceAvailableAgain:error:");
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) {
    vcc_log(@"  device-vendor hook: selector missing");
    return;
  }
  vcc_copy_device_orig = method_setImplementation(m,
                                                    (IMP)vcc_copy_device_hook);
  vcc_log(@"  swizzled -[BWFigCaptureDeviceVendor copyDeviceWithID:...] orig=%p",
          vcc_copy_device_orig);
}

// MARK: - viewfinder stream injection
//
// Camera.app's preview path goes through FigCameraViewfinderStream, NOT
// BWImageQueueSinkNode. The stream exposes -enqueueVideoSampleBuffer: which
// the daemon's normal frame producer calls to deliver each frame to the
// client (Camera.app's AVCaptureVideoPreviewLayer). For our synth source —
// which has no real producer — we hook -[FigCameraViewfinderStream init],
// capture each instance, and drive enqueueVideoSampleBuffer: ourselves on
// a 30 Hz timer, wrapping vcc_latest_frame pixels in a fresh CMSampleBuffer.

// Forward declaration — full definition is later in the file under the
// "shared-frame reader" section.
typedef struct vcc_latest_frame_s {
  pthread_mutex_t lock;
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;
  uint32_t pixel_format;
  uint64_t timestamp_ns;
  uint64_t frame_index;
  uint8_t *pixels;
  size_t   pixels_capacity;
  size_t   pixels_length;
} vcc_latest_frame_t;
extern vcc_latest_frame_t vcc_latest_frame;

// CVPixelBuffer release callback for the malloc'd pixel buffer. Has to be
// a real C function (block isn't compatible with the callback signature).
static void vcc_cv_release_bytes(void *refcon, const void *baseAddress) {
  (void)refcon;
  free((void *)baseAddress);
}

static IMP vcc_vfs_init_orig = NULL;
static IMP vcc_vfs_open_orig = NULL;
static IMP vcc_vfs_close_orig = NULL;
static NSMutableArray *vcc_vf_streams = nil;  // strong refs
static dispatch_source_t vcc_vf_timer = NULL;
static dispatch_queue_t vcc_vf_q = NULL;
static uint64_t vcc_vf_pts_ns = 0;
static uint64_t vcc_vf_enqueue_count = 0;
static uint64_t vcc_vf_enqueue_success = 0;

typedef id (*VccVfsInitFn)(id self, SEL _cmd);
typedef void (*VccVfsOpenFn)(id self, SEL _cmd, id dest);
typedef void (*VccVfsCloseFn)(id self, SEL _cmd);

static _Atomic uint64_t vcc_vfs_init_count = 0;

static id vcc_vfs_init_hook(id self, SEL _cmd) {
  VccVfsInitFn orig = (VccVfsInitFn)vcc_vfs_init_orig;
  id ret = orig(self, _cmd);
  // Throttled — Camera.app spins ~2000 inits/sec without ever opening
  // (session config silently incomplete). Log every 1024th to keep the log
  // file usable.
  uint64_t n = atomic_fetch_add(&vcc_vfs_init_count, 1) + 1;
  if ((n & 0x3ff) == 1) {
    vcc_log(@"  [VFS init] -> %p (total=%llu)",
            ret, (unsigned long long)n);
  }
  return ret;
}

static void vcc_vfs_open_hook(id self, SEL _cmd, id dest) {
  vcc_log(@"  [VFS open] self=%p dest=%@", self, dest);
  VccVfsOpenFn orig = (VccVfsOpenFn)vcc_vfs_open_orig;
  orig(self, _cmd, dest);
  if (!vcc_vf_streams) vcc_vf_streams = [NSMutableArray array];
  [vcc_vf_streams addObject:self];
  vcc_log(@"  [VFS open] captured stream %p (total=%lu)",
          self, (unsigned long)vcc_vf_streams.count);
}

static void vcc_vfs_close_hook(id self, SEL _cmd) {
  vcc_log(@"  [VFS close] self=%p", self);
  if (vcc_vf_streams) [vcc_vf_streams removeObject:self];
  VccVfsCloseFn orig = (VccVfsCloseFn)vcc_vfs_close_orig;
  orig(self, _cmd);
}

// Build a CMSampleBuffer wrapping the latest shm frame. Caller must
// CFRelease the result.
static CMSampleBufferRef vcc_build_cmsb_from_shm(void) {
  pthread_mutex_lock(&vcc_latest_frame.lock);
  uint32_t w = vcc_latest_frame.width;
  uint32_t h = vcc_latest_frame.height;
  uint32_t bpr = vcc_latest_frame.bytes_per_row;
  size_t len = vcc_latest_frame.pixels_length;
  if (!len || !w || !h || !bpr) {
    pthread_mutex_unlock(&vcc_latest_frame.lock);
    return NULL;
  }
  void *pixels = malloc(len);
  if (!pixels) {
    pthread_mutex_unlock(&vcc_latest_frame.lock);
    return NULL;
  }
  memcpy(pixels, vcc_latest_frame.pixels, len);
  pthread_mutex_unlock(&vcc_latest_frame.lock);

  CVPixelBufferRef pb = NULL;
  CVReturn cvr = CVPixelBufferCreateWithBytes(
      kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
      pixels, bpr, vcc_cv_release_bytes, NULL, NULL, &pb);
  if (cvr != kCVReturnSuccess || !pb) {
    free(pixels);
    return NULL;
  }

  CMVideoFormatDescriptionRef desc = NULL;
  OSStatus s = CMVideoFormatDescriptionCreateForImageBuffer(
      kCFAllocatorDefault, pb, &desc);
  if (s != noErr || !desc) {
    CVPixelBufferRelease(pb);
    return NULL;
  }

  // Monotonic PTS at 30 fps. The viewfinder's internal jitter buffer
  // discards frames whose PTS doesn't advance, so we increment per call.
  vcc_vf_pts_ns += 33333333ull;  // 1/30s in nanoseconds
  CMSampleTimingInfo timing = {
      .duration = CMTimeMake(1, 30),
      .presentationTimeStamp = CMTimeMake((int64_t)vcc_vf_pts_ns, 1000000000),
      .decodeTimeStamp = kCMTimeInvalid,
  };

  CMSampleBufferRef cmsb = NULL;
  s = CMSampleBufferCreateForImageBuffer(
      kCFAllocatorDefault, pb, true, NULL, NULL, desc, &timing, &cmsb);
  CFRelease(desc);
  CVPixelBufferRelease(pb);
  if (s != noErr || !cmsb) return NULL;
  return cmsb;
}

static void vcc_vf_drive_once(void) {
  if (!vcc_vf_streams || vcc_vf_streams.count == 0) return;
  CMSampleBufferRef cmsb = vcc_build_cmsb_from_shm();
  if (!cmsb) return;
  SEL sel = NSSelectorFromString(@"enqueueVideoSampleBuffer:");
  for (id stream in [vcc_vf_streams copy]) {
    int ret = ((int (*)(id, SEL, CMSampleBufferRef))objc_msgSend)(
        stream, sel, cmsb);
    vcc_vf_enqueue_count++;
    if (ret == 0) vcc_vf_enqueue_success++;
    if ((vcc_vf_enqueue_count & 29) == 1) {
      vcc_log(@"  [VFS drive] enqueue ret=%d (count=%llu ok=%llu)",
              ret,
              (unsigned long long)vcc_vf_enqueue_count,
              (unsigned long long)vcc_vf_enqueue_success);
    }
  }
  CFRelease(cmsb);
}

static void vcc_install_viewfinder_hooks(void) {
  Class cls = NSClassFromString(@"FigCameraViewfinderStream");
  if (!cls) {
    vcc_log(@"  VF hook: class missing");
    return;
  }
  SEL init_sel = NSSelectorFromString(@"init");
  SEL open_sel = NSSelectorFromString(@"openWithDestination:");
  SEL close_sel = NSSelectorFromString(@"close");
  Method m;
  if ((m = class_getInstanceMethod(cls, init_sel))) {
    vcc_vfs_init_orig = method_setImplementation(m, (IMP)vcc_vfs_init_hook);
  }
  if ((m = class_getInstanceMethod(cls, open_sel))) {
    vcc_vfs_open_orig = method_setImplementation(m, (IMP)vcc_vfs_open_hook);
  }
  if ((m = class_getInstanceMethod(cls, close_sel))) {
    vcc_vfs_close_orig = method_setImplementation(m, (IMP)vcc_vfs_close_hook);
  }
  vcc_log(@"  swizzled FigCameraViewfinderStream init/open/close");

  // Drive at 30 Hz. Frames are enqueued only when at least one stream is
  // open AND a fresh shm frame exists (covered by build_cmsb_from_shm).
  vcc_vf_q = dispatch_queue_create("com.vphone.vcam.vfdrive",
                                     DISPATCH_QUEUE_SERIAL);
  vcc_vf_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          vcc_vf_q);
  dispatch_source_set_timer(vcc_vf_timer,
                            dispatch_time(DISPATCH_TIME_NOW, 0),
                            33333333ull, 2000000ull);
  dispatch_source_set_event_handler(vcc_vf_timer, ^{
    @autoreleasepool { vcc_vf_drive_once(); }
  });
  dispatch_resume(vcc_vf_timer);
  vcc_log(@"  viewfinder drive timer armed (30 Hz)");
}

static void vcc_install_sink_observation(void) {
  Class iqsn = NSClassFromString(@"BWImageQueueSinkNode");
  Class rqsn = NSClassFromString(@"BWRemoteQueueSinkNode");
  if (!iqsn || !rqsn) {
    vcc_log(@"  sink obs: classes missing iqsn=%p rqsn=%p", iqsn, rqsn);
    return;
  }

  SEL iqsnInit = NSSelectorFromString(
      @"initWithHFRSupport:ispJitterCompensationEnabled:"
      @"clientAuditToken:sinkID:");
  SEL rqsnInit = NSSelectorFromString(
      @"initWithMediaType:clientAuditToken:sinkID:cameraInfoByPortType:");
  SEL renderSel = @selector(renderSampleBuffer:forInput:);

  vcc_swizzle_method(iqsn, iqsnInit, (IMP)vcc_iqsn_init_hook,
                      &vcc_iqsn_init_orig);
  vcc_swizzle_method(rqsn, rqsnInit, (IMP)vcc_rqsn_init_hook,
                      &vcc_rqsn_init_orig);
  vcc_swizzle_method(iqsn, renderSel, (IMP)vcc_iqsn_render_hook,
                      &vcc_iqsn_render_orig);
  vcc_swizzle_method(rqsn, renderSel, (IMP)vcc_rqsn_render_hook,
                      &vcc_rqsn_render_orig);
}

// MARK: - BWStillImageSampleBufferSinkNode observation + injection
//
// AVCapturePhotoOutput attaches a sampleBufferAvailableHandler block to the
// still-image sink node; the upstream graph normally drives the node by
// calling -renderSampleBuffer:forInput:, which routes the buffer through
// the node's internal logic and ultimately invokes the handler. Our synth
// has no upstream graph that produces frames, so the handler never fires.
//
// First pass: observe. Hook -setSampleBufferAvailableHandler: and
// -initWithInputMediaType:sinkID: to capture the node + the handler
// block per session, so we can later push a CMSampleBuffer ourselves.

static NSMutableArray *vcc_still_sinks = nil;   // strong refs to nodes
static IMP vcc_still_set_handler_orig = NULL;
static IMP vcc_still_init_orig        = NULL;
static IMP vcc_still_render_orig      = NULL;

typedef id  (*VccStillInitFn)(id self, SEL _cmd, id mediaType, id sinkID);
typedef void (*VccStillSetHandlerFn)(id self, SEL _cmd, id handler);
typedef void (*VccStillRenderFn)(id self, SEL _cmd, CMSampleBufferRef sb, id input);

static id vcc_still_init_hook(id self, SEL _cmd, id mediaType, id sinkID) {
  VccStillInitFn orig = (VccStillInitFn)vcc_still_init_orig;
  id ret = orig(self, _cmd, mediaType, sinkID);
  vcc_log(@"  [StillSink init] self=%p mediaType=%@ sinkID=%@",
          ret, mediaType, sinkID);
  if (ret) {
    if (!vcc_still_sinks) vcc_still_sinks = [NSMutableArray new];
    [vcc_still_sinks addObject:ret];
  }
  return ret;
}

static void vcc_still_set_handler_hook(id self, SEL _cmd, id handler) {
  vcc_log(@"  [StillSink setSampleBufferAvailableHandler:] self=%p handler=%p",
          self, handler);
  VccStillSetHandlerFn orig = (VccStillSetHandlerFn)vcc_still_set_handler_orig;
  orig(self, _cmd, handler);
}

static void vcc_still_render_hook(id self, SEL _cmd, CMSampleBufferRef sb,
                                   id input) {
  vcc_log(@"  [StillSink renderSampleBuffer:forInput:] self=%p sb=%p input=%@",
          self, sb, input);
  VccStillRenderFn orig = (VccStillRenderFn)vcc_still_render_orig;
  orig(self, _cmd, sb, input);
}

static void vcc_install_still_sink_observation(void) {
  Class cls = NSClassFromString(@"BWStillImageSampleBufferSinkNode");
  if (!cls) {
    vcc_log(@"  still-sink obs: class missing");
    return;
  }
  SEL initSel = NSSelectorFromString(@"initWithInputMediaType:sinkID:");
  SEL setHSel = @selector(setSampleBufferAvailableHandler:);
  SEL renderSel = @selector(renderSampleBuffer:forInput:);
  vcc_swizzle_method(cls, initSel,
                      (IMP)vcc_still_init_hook, &vcc_still_init_orig);
  vcc_swizzle_method(cls, setHSel,
                      (IMP)vcc_still_set_handler_hook,
                      &vcc_still_set_handler_orig);
  vcc_swizzle_method(cls, renderSel,
                      (IMP)vcc_still_render_hook, &vcc_still_render_orig);
}

// MARK: - BWFigCaptureSession graph callback observation
//
// AVCaptureSession.startRunning → cameracaptured graph build → start → these
// delegate callbacks fire on BWFigCaptureSession. If start fails (error != 0),
// the daemon reports failure back over XPC and client.isRunning stays NO.
// Hook these to see exactly where in the graph startup the failure occurs.

static IMP vcc_sess_didFinishStarting_orig = NULL;
static IMP vcc_sess_didStartSourceNode_orig = NULL;
static IMP vcc_sess_didPrepare_orig = NULL;

typedef void (*VccSessDidFinishStartingFn)(id self, SEL _cmd, id graph, int error);
typedef void (*VccSessDidStartSourceFn)(id self, SEL _cmd, id graph, id node, int error);
typedef void (*VccSessDidPrepareFn)(id self, SEL _cmd, id graph);

static void vcc_sess_didFinishStarting_hook(id self, SEL _cmd, id graph,
                                              int error) {
  vcc_log(@"  [Sess graph:didFinishStartingWithError:] self=%p graph=%p err=%d",
          self, graph, error);
  VccSessDidFinishStartingFn orig =
      (VccSessDidFinishStartingFn)vcc_sess_didFinishStarting_orig;
  orig(self, _cmd, graph, error);
}

static void vcc_sess_didStartSourceNode_hook(id self, SEL _cmd, id graph,
                                              id node, int error) {
  vcc_log(@"  [Sess graph:didStartSourceNode:error:] self=%p graph=%p node=%@ err=%d",
          self, graph, node, error);
  VccSessDidStartSourceFn orig =
      (VccSessDidStartSourceFn)vcc_sess_didStartSourceNode_orig;
  orig(self, _cmd, graph, node, error);
}

static void vcc_sess_didPrepare_hook(id self, SEL _cmd, id graph) {
  vcc_log(@"  [Sess graphDidPrepareNodes:] self=%p graph=%p", self, graph);
  VccSessDidPrepareFn orig =
      (VccSessDidPrepareFn)vcc_sess_didPrepare_orig;
  orig(self, _cmd, graph);
}

static void vcc_install_session_graph_observation(void) {
  Class cls = NSClassFromString(@"BWFigCaptureSession");
  if (!cls) {
    vcc_log(@"  session-graph obs: class missing");
    return;
  }
  vcc_swizzle_method(cls,
                      @selector(graph:didFinishStartingWithError:),
                      (IMP)vcc_sess_didFinishStarting_hook,
                      &vcc_sess_didFinishStarting_orig);
  vcc_swizzle_method(cls,
                      @selector(graph:didStartSourceNode:error:),
                      (IMP)vcc_sess_didStartSourceNode_hook,
                      &vcc_sess_didStartSourceNode_orig);
  vcc_swizzle_method(cls,
                      @selector(graphDidPrepareNodes:),
                      (IMP)vcc_sess_didPrepare_hook,
                      &vcc_sess_didPrepare_orig);
}

// MARK: - BWFigCaptureSession init capture + pipelines extraction
//
// To splice our manual sink into a real session, we need a handle to its
// FigCaptureSessionPipelines instance. Hook the session's init and, post-orig,
// reach into the _pipelines ivar via KVC. Store globally so the next-stage
// injector has a live reference.

static IMP vcc_sess_initWithFigSess_orig = NULL;
typedef id (*VccSessInitWithFigSessFn)(id self, SEL _cmd, void *figSess);

static id vcc_captured_bw_session = nil;       // strong ref to the BWFigCaptureSession
static id vcc_captured_pipelines = nil;        // its _pipelines ivar value

__attribute__((ns_returns_retained))
static id vcc_sess_initWithFigSess_hook(id self, SEL _cmd, void *figSess) {
  VccSessInitWithFigSessFn orig =
      (VccSessInitWithFigSessFn)vcc_sess_initWithFigSess_orig;
  id ret = orig(self, _cmd, figSess);
  if (ret) {
    vcc_captured_bw_session = ret;
    @try {
      vcc_captured_pipelines = [ret valueForKey:@"pipelines"];
    } @catch (NSException *e) {
      @try {
        vcc_captured_pipelines = [ret valueForKey:@"_pipelines"];
      } @catch (NSException *e2) {
        vcc_captured_pipelines = nil;
      }
    }
    vcc_log(@"  [BWFigCaptureSession init] -> self=%p figSess=%p _pipelines=%p (class=%@)",
            ret, figSess, vcc_captured_pipelines,
            NSStringFromClass([vcc_captured_pipelines class]));
  }
  return ret;
}

static void vcc_install_session_init_capture(void) {
  Class cls = NSClassFromString(@"BWFigCaptureSession");
  if (!cls) {
    vcc_log(@"  session-init capture: class missing");
    return;
  }
  vcc_swizzle_method(cls,
                      @selector(initWithFigCaptureSession:),
                      (IMP)vcc_sess_initWithFigSess_hook,
                      &vcc_sess_initWithFigSess_orig);
}

// MARK: - BWFigCaptureSession stillImageCoordinator observation
//
// AVCapturePhotoOutput.capturePhoto → daemon-side BWStillImageCaptureCoordinator
// queues a request and fires these delegate callbacks on BWFigCaptureSession.
// If willBegin… fires but didCapture… doesn't, the photo pipeline received
// the request but couldn't satisfy it (typically because no sample buffer
// arrived for it to wrap into a photo).

static IMP vcc_sess_willBeginPhoto_orig = NULL;
static IMP vcc_sess_willBeginPhotoForSettings_orig = NULL;
static IMP vcc_sess_willPreparePhoto_orig = NULL;
static IMP vcc_sess_willCapturePhoto_orig = NULL;
static IMP vcc_sess_didCapturePhoto_orig = NULL;

typedef void (*VccSessWillBeginPhotoFn)(id self, SEL _cmd, id coord, long settingsID);
typedef void (*VccSessSettingsFn)(id self, SEL _cmd, id coord, id settings);
typedef void (*VccSessWillPrepareFn)(id self, SEL _cmd, id coord, id settings, BOOL clientInitiated);
typedef void (*VccSessWillCaptureFn)(id self, SEL _cmd, id coord, id settings, int err);

static void vcc_sess_willBeginPhoto_hook(id self, SEL _cmd, id coord,
                                          long settingsID) {
  vcc_log(@"  [Sess stillImageCoordinator:willBeginCaptureBeforeResolvingSettingsForID:] coord=%p id=%ld",
          coord, settingsID);
  VccSessWillBeginPhotoFn orig =
      (VccSessWillBeginPhotoFn)vcc_sess_willBeginPhoto_orig;
  orig(self, _cmd, coord, settingsID);
}

static void vcc_sess_willBeginPhotoForSettings_hook(id self, SEL _cmd, id coord,
                                                     id settings) {
  vcc_log(@"  [Sess stillImageCoordinator:willBeginCaptureForSettings:] coord=%p settings=%@",
          coord, settings);
  VccSessSettingsFn orig =
      (VccSessSettingsFn)vcc_sess_willBeginPhotoForSettings_orig;
  orig(self, _cmd, coord, settings);
}

static void vcc_sess_willPreparePhoto_hook(id self, SEL _cmd, id coord,
                                            id settings, BOOL clientInitiated) {
  vcc_log(@"  [Sess stillImageCoordinator:willPrepareStillImageCaptureWithSettings:clientInitiated:] coord=%p settings=%@ ci=%d",
          coord, settings, clientInitiated);
  VccSessWillPrepareFn orig =
      (VccSessWillPrepareFn)vcc_sess_willPreparePhoto_orig;
  orig(self, _cmd, coord, settings, clientInitiated);
}

static void vcc_sess_willCapturePhoto_hook(id self, SEL _cmd, id coord,
                                            id settings, int err) {
  vcc_log(@"  [Sess stillImageCoordinator:willCapturePhotoForSettings:error:] coord=%p settings=%@ err=%d",
          coord, settings, err);
  VccSessWillCaptureFn orig =
      (VccSessWillCaptureFn)vcc_sess_willCapturePhoto_orig;
  orig(self, _cmd, coord, settings, err);
}

static void vcc_sess_didCapturePhoto_hook(id self, SEL _cmd, id coord,
                                            id settings) {
  vcc_log(@"  [Sess stillImageCoordinator:didCapturePhotoForSettings:] coord=%p settings=%@",
          coord, settings);
  VccSessSettingsFn orig =
      (VccSessSettingsFn)vcc_sess_didCapturePhoto_orig;
  orig(self, _cmd, coord, settings);
}

static void vcc_install_still_coordinator_observation(void) {
  Class cls = NSClassFromString(@"BWFigCaptureSession");
  if (!cls) {
    vcc_log(@"  still-coord obs: BWFigCaptureSession missing");
    return;
  }
  vcc_swizzle_method(cls,
                      @selector(stillImageCoordinator:willBeginCaptureBeforeResolvingSettingsForID:),
                      (IMP)vcc_sess_willBeginPhoto_hook,
                      &vcc_sess_willBeginPhoto_orig);
  vcc_swizzle_method(cls,
                      @selector(stillImageCoordinator:willBeginCaptureForSettings:),
                      (IMP)vcc_sess_willBeginPhotoForSettings_hook,
                      &vcc_sess_willBeginPhotoForSettings_orig);
  vcc_swizzle_method(cls,
                      @selector(stillImageCoordinator:willPrepareStillImageCaptureWithSettings:clientInitiated:),
                      (IMP)vcc_sess_willPreparePhoto_hook,
                      &vcc_sess_willPreparePhoto_orig);
  vcc_swizzle_method(cls,
                      @selector(stillImageCoordinator:willCapturePhotoForSettings:error:),
                      (IMP)vcc_sess_willCapturePhoto_hook,
                      &vcc_sess_willCapturePhoto_orig);
  vcc_swizzle_method(cls,
                      @selector(stillImageCoordinator:didCapturePhotoForSettings:),
                      (IMP)vcc_sess_didCapturePhoto_hook,
                      &vcc_sess_didCapturePhoto_orig);
}

// MARK: - BWStillImageCoordinatorNode existence detector
//
// If our synth session never instantiates BWStillImageCoordinatorNode, the
// capturePhoto request has nowhere to land. Swizzle its known internal
// method (-_enqueueRequestWithSettings:serviceRequestsIfNecessary:) so we
// detect whether the coordinator exists and ever sees a capture request.

static IMP vcc_still_coord_enqueue_orig = NULL;
typedef void (*VccStillCoordEnqueueFn)(id self, SEL _cmd, id settings, BOOL serviceIfNecessary);

static void vcc_still_coord_enqueue_hook(id self, SEL _cmd, id settings,
                                          BOOL serviceIfNecessary) {
  vcc_log(@"  [StillCoord enqueueRequest] self=%p settings=%@ service=%d",
          self, settings, serviceIfNecessary);
  VccStillCoordEnqueueFn orig =
      (VccStillCoordEnqueueFn)vcc_still_coord_enqueue_orig;
  orig(self, _cmd, settings, serviceIfNecessary);
}

static void vcc_install_still_coord_node_observation(void) {
  Class cls = NSClassFromString(@"BWStillImageCoordinatorNode");
  if (!cls) {
    vcc_log(@"  still-coord-node obs: class missing");
    return;
  }
  vcc_swizzle_method(cls,
                      @selector(_enqueueRequestWithSettings:serviceRequestsIfNecessary:),
                      (IMP)vcc_still_coord_enqueue_hook,
                      &vcc_still_coord_enqueue_orig);
}

// MARK: - FigCaptureStillImageSinkPipeline init detector
//
// Per CMCapture symbols, the still pipeline is constructed via:
//   -[FigCaptureStillImageSinkPipeline initWithConfiguration:captureDevice:
//      sourceOutputsByPortType:captureStatusDelegate:inferenceScheduler:
//      graph:name:]
// Hook this to see if it's called for our synth session, and what its
// arguments look like. If it's never called, the daemon's graph-build code
// decides upstream that no still pipeline is needed (probably based on a
// source attribute). If it's called and returns nil, we can inspect the
// arguments to figure out which is missing.

static IMP vcc_still_pipe_init_orig = NULL;
typedef id (*VccStillPipeInitFn)(id self, SEL _cmd, id config, id device,
                                   id outputsByPortType, id captureStatusDelegate,
                                   id inferenceScheduler, id graph, id name);

__attribute__((ns_returns_retained))
static id vcc_still_pipe_init_hook(id self, SEL _cmd, id config, id device,
                                     id outputsByPortType,
                                     id captureStatusDelegate,
                                     id inferenceScheduler, id graph, id name) {
  vcc_log(@"  [StillPipe init] self=%p config=%@ device=%@ outputs.count=%lu name=%@",
          self, config, device,
          (unsigned long)([outputsByPortType respondsToSelector:@selector(count)]
                          ? [outputsByPortType count] : 0),
          name);
  VccStillPipeInitFn orig = (VccStillPipeInitFn)vcc_still_pipe_init_orig;
  id ret = orig(self, _cmd, config, device, outputsByPortType,
                captureStatusDelegate, inferenceScheduler, graph, name);
  vcc_log(@"  [StillPipe init] -> %p", ret);
  return ret;
}

static void vcc_install_still_pipeline_observation(void) {
  Class cls = NSClassFromString(@"FigCaptureStillImageSinkPipeline");
  if (!cls) {
    vcc_log(@"  still-pipe obs: class missing");
    return;
  }
  SEL sel = NSSelectorFromString(
      @"initWithConfiguration:captureDevice:sourceOutputsByPortType:"
      @"captureStatusDelegate:inferenceScheduler:graph:name:");
  vcc_swizzle_method(cls, sel, (IMP)vcc_still_pipe_init_hook,
                      &vcc_still_pipe_init_orig);
}

// MARK: - FigCaptureSessionPipelines.addStillImageSinkPipelineSessionStorage
//
// Per CMCapture symbols, this is the daemon-side method that registers a
// still-image sink pipeline with the session. If captureSession_buildGraph-
// WithConfiguration's still-pipeline branch ever runs for our synth source,
// this method gets called. If it's never called for our test, the upstream
// gate (parsed still-image sink configurations array empty?) is what we
// need to address.

static IMP vcc_pipelines_addStill_orig = NULL;
typedef void (*VccPipelinesAddStillFn)(id self, SEL _cmd, id storage);

static void vcc_pipelines_addStill_hook(id self, SEL _cmd, id storage) {
  vcc_log(@"  [Pipelines addStillImageSinkPipelineSessionStorage:] self=%p storage=%@",
          self, storage);
  VccPipelinesAddStillFn orig =
      (VccPipelinesAddStillFn)vcc_pipelines_addStill_orig;
  orig(self, _cmd, storage);
}

static void vcc_install_pipelines_addStill_observation(void) {
  Class cls = NSClassFromString(@"FigCaptureSessionPipelines");
  if (!cls) {
    vcc_log(@"  pipelines obs: class missing");
    return;
  }
  vcc_swizzle_method(cls,
                      @selector(addStillImageSinkPipelineSessionStorage:),
                      (IMP)vcc_pipelines_addStill_hook,
                      &vcc_pipelines_addStill_orig);
}

// MARK: - graph-build error suppressors
//
// captureSession_buildGraphWithConfiguration's per-source iteration bails
// to OSStatus -12783 along three known paths on our synth source:
//
//   (1) -[FigCaptureCameraSourcePipeline requiresMasterClock] returns YES,
//       and the post-iteration check (OR of all pipelines' returns) bails
//       on a virtual source that has no real ISP/HW clock.
//   (2) _cs_addObjectToStreamsAttributes returns -12783 when an inherited
//       ivar slot is NULL (called from _FigVideoCaptureSourcesActivate-
//       AndCreateDevices during session activation).
//   (3) -[BWFigVideoCaptureStream initWithCaptureStream:…] sets *errOut
//       = -12783 in its validation-failure path.
//
// (1) is neutralized by rewriting the function's prologue to `mov w0, #0; ret`.
// The function's address is resolved from CMCapture's LC_SYMTAB by name —
// no hardcoded VMA.
//
// (2)+(3) are neutralized by scanning CMCapture's __text for the specific
// MOVN encodings the compiler used to prepare -12783 in w20 / w8, and
// rewriting each to `MOVZ w?, #0`. -12783 is a capture-specific OSStatus
// emitted only by the daemon; over-application is benign because the
// daemon's only consumer in the VM is our synth.

static void vcc_install_csp_requires_master_clock_hook(void) {
  vcc_image_t img;
  if (vcc_image_resolve(&img, "FigCaptureSourceServerStart") != 0) {
    vcc_log(@"  graph-build patches: image resolve failed");
    return;
  }

  // (1) Resolve -[FigCaptureCameraSourcePipeline requiresMasterClock] via
  // LC_SYMTAB. The function is called via direct C dispatch (not in the
  // objc method table on observed builds, so swizzling won't work), so
  // we rewrite its prologue in place. The PAC-signed address from the
  // symtab is stripped before the write.
  static const char *const kReqMCSyms[] = {
      "_-[FigCaptureCameraSourcePipeline requiresMasterClock]",
      "-[FigCaptureCameraSourcePipeline requiresMasterClock]",
      NULL,
  };
  uintptr_t reqMC = 0;
  for (unsigned i = 0; kReqMCSyms[i]; i++) {
    reqMC = vcc_lookup_lc_symtab(&img, kReqMCSyms[i]);
    if (reqMC) {
      vcc_log(@"  requiresMasterClock @ 0x%lx (sym=%s)",
              (unsigned long)reqMC, kReqMCSyms[i]);
      break;
    }
  }
  if (reqMC) {
    uintptr_t target = (uintptr_t)ptrauth_strip(
        (void *)reqMC, ptrauth_key_function_pointer);
    uint32_t insn0 = ((const uint32_t *)target)[0];
    uint32_t insn1 = ((const uint32_t *)target)[1];
    // Sanity anchor: the second prologue insn should be pacibsp on every
    // arm64e build that signs return addresses. Refuse the patch if it
    // isn't — we'd rather skip than rewrite an unrelated function.
    if (insn1 != 0xD503237Fu) {
      vcc_log(@"  requiresMasterClock @ 0x%lx: insn1=0x%08x != pacibsp; skip",
              (unsigned long)target, insn1);
    } else {
      int ok1 = vcc_patch_word(target,     insn0, 0x52800000u);  // mov w0, #0
      int ok2 = vcc_patch_word(target + 4, insn1, 0xd65f03c0u);  // ret
      vcc_log(@"  requiresMasterClock prologue patch @ 0x%lx: %d/%d",
              (unsigned long)target, ok1, ok2);
    }
  } else {
    vcc_log(@"  requiresMasterClock symbol not in LC_SYMTAB; patch skipped");
  }

  // (2) `mov w20, #-12783` (MOVN encoding 0x12863dd4) -> `mov w20, #0`.
  vcc_scan_and_patch(&img, 0x12863dd4u, 0x52800014u,
                     "mov w20, #-12783 -> #0");
  // (3) `mov w8, #-12783` (MOVN encoding 0x12863dc8) -> `mov w8, #0`.
  vcc_scan_and_patch(&img, 0x12863dc8u, 0x52800008u,
                     "mov w8, #-12783 -> #0");
}

// MARK: - Sink node injection — manually-constructed BWStillImageSampleBufferSinkNode
//
// The daemon's session graph for our synth source builds without a still-image
// pipeline → no BWStillImageSampleBufferSinkNode exists → capturePhoto can't
// find a sink to deliver to → -11803 "Cannot Record".
//
// Manually construct a BWStillImageSampleBufferSinkNode at install time.
// Observation pass: prove the class accepts initialization in our daemon
// context. Next iteration adds the wiring path so capturePhoto sees this
// sink and delivers our shm frame through it.

static id vcc_synth_still_sink = nil;
static dispatch_queue_t vcc_still_inject_q = NULL;

static void vcc_construct_still_sink(void) {
  Class cls = NSClassFromString(@"BWStillImageSampleBufferSinkNode");
  if (!cls) {
    vcc_log(@"  manual still-sink: class missing");
    return;
  }
  // Per ipsw symaddr the simpler init is -[BWStillImageSampleBufferSinkNode
  // initWithSinkID:] at static 0x1ae333e20. The full init takes inputMediaType
  // + sinkID. Try the simpler one first.
  SEL sinkIdInit = NSSelectorFromString(@"initWithSinkID:");
  id sinkID = @(0xCAFEBABEull);  // synthetic sinkID, unique to us
  id alloced = ((id (*)(Class, SEL))objc_msgSend)(cls, @selector(alloc));
  if (!alloced) {
    vcc_log(@"  manual still-sink: alloc returned nil");
    return;
  }
  if (![alloced respondsToSelector:sinkIdInit]) {
    vcc_log(@"  manual still-sink: doesn't respond to %@",
            NSStringFromSelector(sinkIdInit));
    // Don't init — leak the alloced bytes (cheaper than crashing)
    return;
  }
  @try {
    vcc_synth_still_sink =
        ((id (*)(id, SEL, id))objc_msgSend)(alloced, sinkIdInit, sinkID);
  } @catch (NSException *e) {
    vcc_log(@"  manual still-sink: init exception: %@", e);
    return;
  }
  vcc_log(@"  manual still-sink: created %p (class=%@)",
          vcc_synth_still_sink,
          NSStringFromClass([vcc_synth_still_sink class]));
  if (!vcc_synth_still_sink) return;

  // Probe properties to make sure we got a usable instance.
  @try {
    SEL hdlrGet = @selector(sampleBufferAvailableHandler);
    if ([vcc_synth_still_sink respondsToSelector:hdlrGet]) {
      id existing =
          ((id (*)(id, SEL))objc_msgSend)(vcc_synth_still_sink, hdlrGet);
      vcc_log(@"  manual still-sink: initial sampleBufferAvailableHandler=%p",
              existing);
    } else {
      vcc_log(@"  manual still-sink: no -sampleBufferAvailableHandler");
    }
  } @catch (NSException *e) {
    vcc_log(@"  manual still-sink: probe exception: %@", e);
  }

  vcc_still_inject_q =
      dispatch_queue_create("com.vphone.vcam.still-inject", DISPATCH_QUEUE_SERIAL);

  // Synthesize a sampleBufferAvailableHandler block and set it on our sink.
  //
  // Per disasm of -[BWStillImageSampleBufferSinkNode renderSampleBuffer:forInput:]
  // at static 0x1ae577428, the block invoke at 0x1ae57758c-590 takes:
  //   x0 = block (auto)
  //   x1 = CMSampleBufferRef sampleBuffer
  //   x2 = BOOL flag (always 0 at this site)
  //   x3 = [x21 requestedSettings] (presumably the AVCapturePhotoSettings)
  //
  // We don't yet have a real XPC reply path; this handler is currently a
  // logging probe that lets us verify our manually-installed handler does
  // fire when we drive -renderSampleBuffer:forInput: ourselves.
  SEL setHandlerSel = @selector(setSampleBufferAvailableHandler:);
  if ([vcc_synth_still_sink respondsToSelector:setHandlerSel]) {
    void (^block)(CMSampleBufferRef, BOOL, id) =
        ^(CMSampleBufferRef sbuf, BOOL flag, id requestedSettings) {
      vcc_log(@"  [SyntheticHandler] sbuf=%p flag=%d settings=%@",
              sbuf, flag, requestedSettings);
      // Extract the image data and write to disk as proof of pipeline integrity.
      if (!sbuf) return;
      CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sbuf);
      if (!pb) {
        vcc_log(@"  [SyntheticHandler] no image buffer");
        return;
      }
      CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
      size_t w = CVPixelBufferGetWidth(pb);
      size_t h = CVPixelBufferGetHeight(pb);
      size_t bpr = CVPixelBufferGetBytesPerRow(pb);
      OSType fmt = CVPixelBufferGetPixelFormatType(pb);
      vcc_log(@"  [SyntheticHandler] pb=%p w=%zu h=%zu bpr=%zu fmt=0x%x",
              pb, w, h, bpr, (unsigned)fmt);
      // Write the raw BGRA bytes to disk for verification.
      // ${TMPDIR}-style path — use /var/mobile/Library/vphone-synth-photo.raw
      // (writable by mobile uid). If that fails, /tmp is also acceptable.
      const char *out_path = "/var/mobile/Library/vphone-synth-photo.bgra";
      uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
      if (base) {
        int fd = open(out_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
          for (size_t y = 0; y < h; y++) {
            (void)write(fd, base + y * bpr, w * 4);
          }
          close(fd);
          vcc_log(@"  [SyntheticHandler] wrote %s (%zu bytes)",
                  out_path, w * h * 4);
        } else {
          vcc_log(@"  [SyntheticHandler] open(%s) failed: %d", out_path, errno);
        }
      }
      CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    };
    @try {
      ((void (*)(id, SEL, id))objc_msgSend)(vcc_synth_still_sink,
                                              setHandlerSel, block);
      vcc_log(@"  manual still-sink: installed synthetic handler block");
    } @catch (NSException *e) {
      vcc_log(@"  manual still-sink: setHandler exception: %@", e);
    }
    // Verify the handler was stored
    @try {
      id stored = ((id (*)(id, SEL))objc_msgSend)(
          vcc_synth_still_sink, @selector(sampleBufferAvailableHandler));
      vcc_log(@"  manual still-sink: post-set sampleBufferAvailableHandler=%p",
              stored);
    } @catch (NSException *e) {
      vcc_log(@"  manual still-sink: getHandler exception: %@", e);
    }
  } else {
    vcc_log(@"  manual still-sink: doesn't respond to setSampleBufferAvailableHandler:");
  }
}

// Trigger-the-handler probe: call -renderSampleBuffer:forInput: on our
// synth sink directly with a synthetic CMSampleBuffer built from
// vcc_latest_frame. If our manually-installed handler fires, we have
// proven the synthetic-handler approach works at the API level.
static void vcc_drive_still_sink_once(void) {
  if (!vcc_synth_still_sink) return;
  CMSampleBufferRef sbuf = vcc_build_cmsb_from_shm();
  if (!sbuf) {
    vcc_log(@"  still-drive: no shm frame yet");
    return;
  }
  SEL renderSel = @selector(renderSampleBuffer:forInput:);
  if (![vcc_synth_still_sink respondsToSelector:renderSel]) {
    vcc_log(@"  still-drive: sink doesn't respond to renderSampleBuffer:forInput:");
    CFRelease(sbuf);
    return;
  }
  vcc_log(@"  still-drive: calling renderSampleBuffer: on sink %p with sbuf=%p",
          vcc_synth_still_sink, sbuf);
  @try {
    ((void (*)(id, SEL, CMSampleBufferRef, id))objc_msgSend)(
        vcc_synth_still_sink, renderSel, sbuf, nil);
    vcc_log(@"  still-drive: render call returned");
  } @catch (NSException *e) {
    vcc_log(@"  still-drive: render exception: %@", e);
  }
  CFRelease(sbuf);
}

// MARK: - FigCaptureSessionParsedConfiguration observation
//
// This is the daemon-side parser that converts the XPC session config into
// the structured configuration the graph builder uses. After init,
// _parsedStillImageSinkConfigurations is populated; if empty, no still
// pipeline will be built.

static IMP vcc_parsed_cfg_init_orig = NULL;
typedef id (*VccParsedCfgInitFn)(id self, SEL _cmd, id sessionCfg,
                                   BOOL clientSetsUserInitiated, id restrictions);

__attribute__((ns_returns_retained))
static id vcc_parsed_cfg_init_hook(id self, SEL _cmd, id sessionCfg,
                                     BOOL clientSetsUserInitiated,
                                     id restrictions) {
  VccParsedCfgInitFn orig = (VccParsedCfgInitFn)vcc_parsed_cfg_init_orig;
  id ret = orig(self, _cmd, sessionCfg, clientSetsUserInitiated, restrictions);
  if (ret) {
    id stillCfgs = nil;
    @try {
      stillCfgs = [ret valueForKey:@"parsedStillImageSinkConfigurations"];
    } @catch (NSException *e) {
      stillCfgs = nil;
    }
    id cameraCfgs = nil;
    @try {
      cameraCfgs = [ret valueForKey:@"parsedCameraSourceConfigurations"];
    } @catch (NSException *e) {
      cameraCfgs = nil;
    }
    vcc_log(@"  [ParsedCfg init] -> %p stillCfgs.count=%lu cameraCfgs.count=%lu",
            ret,
            (unsigned long)(stillCfgs && [stillCfgs respondsToSelector:@selector(count)]
                            ? [stillCfgs count] : 0),
            (unsigned long)(cameraCfgs && [cameraCfgs respondsToSelector:@selector(count)]
                            ? [cameraCfgs count] : 0));
    if (cameraCfgs && [cameraCfgs respondsToSelector:@selector(count)]
        && [cameraCfgs count] > 0) {
      vcc_log(@"  [ParsedCfg] cameraCfgs[0] class=%@",
              NSStringFromClass([[cameraCfgs firstObject] class]));
    }
    if (stillCfgs && [stillCfgs respondsToSelector:@selector(count)]
        && [stillCfgs count] > 0) {
      id stillCfg = [stillCfgs firstObject];
      vcc_log(@"  [ParsedCfg] stillCfgs[0] class=%@ desc=%@",
              NSStringFromClass([stillCfg class]), stillCfg);
      // Dump the still cfg's properties — what does it tell the graph builder?
      id connConfigs = nil, primaryConnConfig = nil, movieCfg = nil, pointCfg = nil;
      @try { connConfigs = [stillCfg valueForKey:@"stillImageConnectionConfigurations"]; } @catch (NSException *e) {}
      @try { primaryConnConfig = [stillCfg valueForKey:@"primaryStillImageConnectionConfiguration"]; } @catch (NSException *e) {}
      @try { movieCfg = [stillCfg valueForKey:@"movieFileVideoConnectionConfiguration"]; } @catch (NSException *e) {}
      @try { pointCfg = [stillCfg valueForKey:@"pointCloudDataConnectionConfiguration"]; } @catch (NSException *e) {}
      vcc_log(@"  [ParsedCfg] stillCfgs[0].connCfgs=%@",
              connConfigs ?: @"(nil)");
      vcc_log(@"  [ParsedCfg] stillCfgs[0].primary=%@", primaryConnConfig ?: @"(nil)");
      // Also dump the camera source config to see what source it's bound to
      id cameraCfg = [cameraCfgs firstObject];
      id sourceID = nil, deviceType = nil, captureDeviceID = nil;
      @try { sourceID = [cameraCfg valueForKey:@"sourceID"]; } @catch (NSException *e) {}
      @try { deviceType = [cameraCfg valueForKey:@"sourceDeviceType"]; } @catch (NSException *e) {}
      @try { captureDeviceID = [cameraCfg valueForKey:@"captureDeviceID"]; } @catch (NSException *e) {}
      vcc_log(@"  [ParsedCfg] cameraCfg sourceID=%@ deviceType=%@ captureDeviceID=%@",
              sourceID ?: @"(nil)", deviceType ?: @"(nil)",
              captureDeviceID ?: @"(nil)");
    }
  }
  return ret;
}

static void vcc_install_parsed_cfg_observation(void) {
  Class cls = NSClassFromString(@"FigCaptureSessionParsedConfiguration");
  if (!cls) {
    vcc_log(@"  parsed-cfg obs: class missing");
    return;
  }
  SEL sel = NSSelectorFromString(
      @"initWithSessionConfiguration:clientSetsUserInitiatedCaptureRequestTime:restrictions:");
  vcc_swizzle_method(cls, sel, (IMP)vcc_parsed_cfg_init_hook,
                      &vcc_parsed_cfg_init_orig);
}

// MARK: - shared-frame reader

// The latest frame copied out of the vphoned-published shm. Mutated only
// from the reader callback thread; readers (AVF stream production, next
// stage) take the lock for the brief duration of a copy.
// (struct vcc_latest_frame_s is forward-declared above as vcc_latest_frame_t
//  for use by the viewfinder injection code.)

vcc_latest_frame_t vcc_latest_frame = {
    .lock = PTHREAD_MUTEX_INITIALIZER,
};

static const uint8_t *vcc_shm_base = NULL;
static uint64_t vcc_last_seq_seen = 0;
static uint64_t vcc_frames_received = 0;

static int vcc_shm_map(void) {
  int fd = open(VCC_SHM_PATH, O_RDONLY);
  if (fd < 0) {
    vcc_log(@"  shm open(%s) failed: %s", VCC_SHM_PATH, strerror(errno));
    return -1;
  }
  struct stat st;
  if (fstat(fd, &st) < 0 || st.st_size < (off_t)VCC_SHM_HEADER_SIZE) {
    vcc_log(@"  shm fstat failed or undersized");
    close(fd);
    return -1;
  }
  void *base = mmap(NULL, VCC_SHM_TOTAL_SIZE, PROT_READ,
                    MAP_SHARED, fd, 0);
  close(fd);
  if (base == MAP_FAILED) {
    vcc_log(@"  shm mmap failed: %s", strerror(errno));
    return -1;
  }
  vcc_shm_base = (const uint8_t *)base;
  vcc_log(@"  shm mapped %s -> %p", VCC_SHM_PATH, vcc_shm_base);
  return 0;
}

// Read the latest frame with seq-stability discipline. Returns 1 on a
// fresh frame, 0 if seq hasn't advanced since last call or a read tore.
static int vcc_shm_read_latest(void) {
  if (!vcc_shm_base) return 0;
  const vcc_shm_header_t *hdr = (const vcc_shm_header_t *)vcc_shm_base;

  uint64_t seq_a = atomic_load_explicit(
      (const _Atomic uint64_t *)&hdr->seq, memory_order_acquire);
  if (seq_a == vcc_last_seq_seen) return 0;
  if (seq_a & 1ull) return 0;  // writer in progress

  uint32_t w   = hdr->width;
  uint32_t h   = hdr->height;
  uint32_t bpr = hdr->bytes_per_row;
  uint32_t fmt = hdr->pixel_format;
  uint64_t ts  = hdr->timestamp_ns;
  uint64_t idx = hdr->frame_index;
  uint32_t pix_len = hdr->pixels_length;

  if (pix_len == 0 || pix_len > VCC_SHM_MAX_PIXELS) return 0;
  if (w == 0 || h == 0 || bpr == 0 || pix_len < (size_t)bpr * h) return 0;

  pthread_mutex_lock(&vcc_latest_frame.lock);
  if (vcc_latest_frame.pixels_capacity < pix_len) {
    free(vcc_latest_frame.pixels);
    vcc_latest_frame.pixels = (uint8_t *)malloc(pix_len);
    vcc_latest_frame.pixels_capacity =
        vcc_latest_frame.pixels ? pix_len : 0;
  }
  if (vcc_latest_frame.pixels) {
    memcpy(vcc_latest_frame.pixels,
           vcc_shm_base + VCC_SHM_HEADER_SIZE, pix_len);
    vcc_latest_frame.pixels_length = pix_len;
    vcc_latest_frame.width = w;
    vcc_latest_frame.height = h;
    vcc_latest_frame.bytes_per_row = bpr;
    vcc_latest_frame.pixel_format = fmt;
    vcc_latest_frame.timestamp_ns = ts;
    vcc_latest_frame.frame_index = idx;
  }
  pthread_mutex_unlock(&vcc_latest_frame.lock);

  // Re-check seq after copy. If it advanced past our snapshot+1 we may
  // have torn — but the writer always sets even seq AFTER pixel write,
  // so seeing the same even seq means our copy was clean.
  uint64_t seq_b = atomic_load_explicit(
      (const _Atomic uint64_t *)&hdr->seq, memory_order_acquire);
  if (seq_b != seq_a) return 0;

  vcc_last_seq_seen = seq_a;
  vcc_frames_received++;
  if ((vcc_frames_received & 29) == 1) {
    vcc_log(@"  shm frame #%llu (idx=%llu) w=%u h=%u bpr=%u fmt=0x%08x",
            (unsigned long long)vcc_frames_received,
            (unsigned long long)idx, w, h, bpr, fmt);
  }
  return 1;
}

static void vcc_start_frame_receiver(void) {
  if (vcc_shm_map() < 0) {
    vcc_log(@"  frame receiver disabled (shm not available yet)");
    return;
  }
  // Subscribe to vphoned's notification. Each fire = one frame ready.
  int token = -1;
  dispatch_queue_t q =
      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  uint32_t status = notify_register_dispatch(
      VCC_NOTIFY_NAME, &token, q,
      ^(__unused int t) {
        @autoreleasepool {
          (void)vcc_shm_read_latest();
        }
      });
  if (status != NOTIFY_STATUS_OK) {
    vcc_log(@"  notify_register_dispatch(%s) failed: %u",
            VCC_NOTIFY_NAME, status);
    return;
  }
  vcc_log(@"  subscribed to %s (token=%d)", VCC_NOTIFY_NAME, token);
}

// MARK: - constructor

__attribute__((constructor)) static void vcc_init(void) {
  @autoreleasepool {
    vcc_log(@"loaded (argv0=%@)",
            NSProcessInfo.processInfo.arguments.firstObject ?: @"?");

    // Schedule install after the daemon has run its own init. The delay
    // gives FigCaptureSourceServerStart's `dispatch_once` block time to
    // allocate _sSourceList before we try to mutate it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                     @autoreleasepool {
                       vcc_install_synthetic();
                       vcc_start_frame_receiver();
                       vcc_install_endpoint_hook();
                       vcc_install_sink_observation();
                       vcc_install_still_sink_observation();
                       vcc_install_session_graph_observation();
                       vcc_install_still_coordinator_observation();
                       vcc_install_still_coord_node_observation();
                       vcc_install_still_pipeline_observation();
                       vcc_install_pipelines_addStill_observation();
                       vcc_install_parsed_cfg_observation();
                       vcc_install_csp_requires_master_clock_hook();
                       vcc_install_session_init_capture();
                       vcc_construct_still_sink();
                       // Probe: drive our manually-installed handler 15s
                       // after install. Gives time for vphoned to produce
                       // shm frames our reader can wrap into a CMSampleBuffer.
                       dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                     (int64_t)(15 * NSEC_PER_SEC)),
                                      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                                      ^{ @autoreleasepool { vcc_drive_still_sink_once(); }});
                       vcc_install_viewfinder_hooks();
                       vcc_dump_sink_node_methods();
                       // Signature corrected against the observed type
                       // encoding @40@0:8@16i24B28^i32 (clientPID is int,
                       // err is int*). Hook is currently observe-only —
                       // calls orig and logs return + err, which lets us
                       // see what client/PID is asking for our device and
                       // confirm the -12780 nil-return path before we add
                       // synthesis logic.
                       vcc_install_device_vendor_hook();
                       vcc_install_copy_streams_hook();
                       vcc_install_copy_streams_from_hook();
                     }
                   });
  }
}
