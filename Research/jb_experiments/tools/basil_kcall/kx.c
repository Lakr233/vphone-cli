// kx: kernel-call driver for the kcall10 cave (syscall 439): x0..x6 = args, result = full 64-bit x0.
// usage: kx <hex runtime target> [hex a0 .. hex a6]
// Raw svc: libc syscall() returns int and truncates kernel pointers to 32 bits.
// The result line is appended to /private/var/tmp/kx.out (no printf): the root PTY can lose lines.
// A garbage target is a guaranteed kernel panic, so the argument is parsed strictly.
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static uint64_t kcall10(uint64_t target, const uint64_t a[7])
{
    register uint64_t x0 __asm__("x0") = target;
    register uint64_t x1 __asm__("x1") = a[0];
    register uint64_t x2 __asm__("x2") = a[1];
    register uint64_t x3 __asm__("x3") = a[2];
    register uint64_t x4 __asm__("x4") = a[3];
    register uint64_t x5 __asm__("x5") = a[4];
    register uint64_t x6 __asm__("x6") = a[5];
    register uint64_t x7 __asm__("x7") = a[6];
    register uint64_t x16 __asm__("x16") = 439;
    __asm__ volatile("svc #0x80"
                     : "+r"(x0)
                     : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x6), "r"(x7), "r"(x16)
                     : "memory", "cc");
    return x0;
}

int main(int argc, char **argv)
{
    if (argc < 2 || argc > 9) {
        return 2;
    }
    char *end;
    uint64_t target = strtoull(argv[1], &end, 16);
    if (*end) {
        return 2;
    }
    uint64_t a[7] = {0};
    for (int i = 0; i < argc - 2; i++) {
        a[i] = strtoull(argv[i + 2], &end, 16);
        if (*end) {
            return 2;
        }
    }
    uint64_t r = kcall10(target, a);
    char out[96];
    int n = snprintf(out, sizeof out, "r=0x%016llx\n", (unsigned long long)r);
    int fd = open("/private/var/tmp/kx.out", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, out, n);
        close(fd);
    }
    return (int)(r & 0x7f);
}
