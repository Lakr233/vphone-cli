// A dylib rather than a program. It differs from hello.c in the two places
// this signer has to get right on its own: MH_DYLIB rather than MH_EXECUTE,
// and an executable segment whose flags do not carry the main-binary bit.

#include <stddef.h>

static const char padding[8192] = "vphone-sign fixture (dylib)";

size_t vphone_fixture_length(void);

size_t vphone_fixture_length(void)
{
    size_t n = 0;
    while (n < sizeof(padding) && padding[n] != '\0') n++;
    return n;
}
