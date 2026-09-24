// The signing corpus, as a program rather than as whatever /bin/ls happens to
// be on this machine's macOS. It is never run; only its bytes are signed.
//
// It is deliberately not empty. A main() that only returns 0 compiles to a
// __TEXT small enough that a signature's page table is one page, and a
// one-page CodeDirectory exercises none of the offset arithmetic that a real
// binary does. The array below pushes __TEXT past 4 KiB so there are several
// page hashes to get right.

#include <stdio.h>

static const char padding[8192] = "vphone-sign fixture";

int main(int argc, char **argv)
{
    (void)argv;
    printf("%d %c\n", argc, padding[argc & 0x1fff]);
    return 0;
}
