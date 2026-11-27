"""kcptr.py <kc> <va>... | kcptr.py <kc> --meta <va> — decode DYLD_CHAINED_PTR_64_KERNEL_CACHE rebases in a kernelcache.

Layout (mach-o/fixup-chains.h, dyld_chained_ptr_64_kernel_cache_rebase):
    target:30, cacheLevel:2, diversity:16, addrDiv:1, key:2, next:12, isAuth:1
Non-auth pointer = KC_BASE + target. KC_BASE = 0xfffffff007004000 (the kernelcache's lowest vmaddr, where __TEXT begins),
NOT 0xfffffff007000000: control check on IOHIDFamily __mod_init_func gives 37/37 targets inside the kext's __text
with 0x…7004000 and 35/37 with 0x…7000000. Authenticated pointers (isAuth=1) are not decoded.
"""
import sys, struct

KC_BASE = 0xfffffff007004000


def load(K):
    import allseg
    return allseg.load(K)


def seg(segs, v):
    for x in segs:
        if x[3] <= v < x[3] + x[4]:
            return x


def rd(f, segs, v):
    x = seg(segs, v)
    if not x or not x[5]:
        return None
    return struct.unpack_from('<Q', f, x[5] + v - x[3])[0]


def ptr(f, segs, v):
    r = rd(f, segs, v)
    if r is None or r >> 63:
        return None
    return KC_BASE + (r & 0x3fffffff)


def cstr(f, segs, v):
    x = seg(segs, v)
    if not x or not x[5]:
        return None
    o = x[5] + v - x[3]
    return f[o:o + 160].split(b'\0')[0].decode(errors='replace')


def owner(segs, v):
    x = seg(segs, v)
    return None if not x else '%s %s,%s' % (x[0], x[1], x[2])


if __name__ == '__main__':
    f, segs = load(sys.argv[1])
    if sys.argv[2] == '--meta':
        mc = int(sys.argv[3], 16)
        for i in range(int(sys.argv[4]) if len(sys.argv) > 4 else 16):
            p = ptr(f, segs, mc + 8 * i)
            if p is None:
                print('  +%#05x  none/zero/auth' % (i * 8))
                continue
            t = cstr(f, segs, p)
            extra = ('  -> "%s"' % t[:60]) if t and seg(segs, p)[2] == '__cstring' else ''
            print('  +%#05x %#x  %-52s%s' % (i * 8, p, owner(segs, p), extra))
    else:
        for a in sys.argv[2:]:
            va = int(a, 16)
            r = rd(f, segs, va)
            p = None if r is None or r >> 63 else KC_BASE + (r & 0x3fffffff)
            print('%#x raw=%s -> %s %s' % (va, 'None' if r is None else '%#018x' % r, '-' if p is None else hex(p),
                                           '' if p is None else owner(segs, p)))
