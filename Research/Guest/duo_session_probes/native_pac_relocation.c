#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
#include "../../../VPhoneGuestComponents/MISFix/MISFixDetour.c"
void MISFixNote(const char *format, ...) { (void)format; }
const char *MISFixCallerImage(const void *address) { (void)address; return "test"; }
extern uint64_t reference_sign(uint64_t);
extern char reference_pac_site;
int main(void) {
    uint32_t *code = mmap(NULL, 16384, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0);
    assert(code != MAP_FAILED);
    code[0] = 0xAA1E03E9; // mov x9, lr
    code[1] = 0xAA0003FE; // mov lr, x0
    unsigned n = vpRelocate(0xDAC1A7FEu, (uint64_t)&reference_pac_site, code+2);
    assert(n == 8);
    code[2+n] = 0xAA1E03E0; // mov x0, lr
    code[3+n] = 0xAA0903FE; // mov lr, x9
    code[4+n] = 0xD65F03C0; // ret
    assert(mprotect(code,16384,PROT_READ|PROT_EXEC)==0);
    sys_icache_invalidate(code,16384);
    uint64_t (*relocated)(uint64_t) = (void *)code;
    for (uint64_t i=1;i<=4096;i++) {
        uint64_t input = 0x100000000ull + i*16;
        uint64_t expected = reference_sign(input);
        uint64_t actual = relocated(input);
        if (expected != actual) { fprintf(stderr,"PAC mismatch at %llu\n",i); return 1; }
    }
    puts("PASS: 4096 relocated signatures match native PACIBSPPC at original PC");
    return 0;
}
