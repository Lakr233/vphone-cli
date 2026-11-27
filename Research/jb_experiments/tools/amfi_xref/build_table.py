import sys, struct, re, subprocess, json, os
R = os.environ.get('JB_RESEARCH', '/tmp/jbresearch/research')   # dir with q*_x*.txt, prologue.py, output json
I = os.environ.get('JB_IPSW', '/tmp/jbresearch/ipsw')            # dir with x13/, x17/
KC = {'x13': I + '/x13/kc.decomp/kernelcache.release.iphone14.decompressed',
      'x17': I + '/x17/kc.decomp/kernelcache.release.v54.decompressed'}
KEXT = 'com.apple.driver.AppleMobileFileIntegrity'
# parse q1/q2 files -> {tag: [ (str_off, str_va, text, [(xref_off, xref_va)]) ]}
D = {}
for tag in KC:
    rows = []; cur = None
    for fn in (f'{R}/q1_{tag}.txt', f'{R}/q2_{tag}.txt'):
        for l in open(fn):
            if l.startswith('STR '):
                _, so, sva, txt = l.split(' ', 3)
                rows.append((int(so, 16), int(sva, 16), eval(txt), [])); cur = rows[-1]
            elif l.startswith('    XREF') and 'none' not in l:
                _, xo, xv, kind = l.split()
                cur[3].append((int(xo, 16), int(xv, 16), kind))
    D[tag] = rows
json.dump({t: [(a, b, c, d) for a, b, c, d in r] for t, r in D.items()}, open(f'{R}/xref_table.json', 'w'), indent=1)
# prologues
PRO = {}
for tag in KC:
    vas = sorted({x[1] for r in D[tag] for x in r[3]})
    out = subprocess.run([sys.executable, f'{R}/prologue.py', KC[tag], KEXT] + [hex(v) for v in vas], capture_output=True, text=True).stdout
    for l in out.splitlines():
        m = re.match(r'(0x[0-9a-f]+) -> prologue (0x[0-9a-f]+) \((.+?)\) dist=(0x[0-9a-f]+)', l)
        if m: PRO[(tag, int(m.group(1), 16))] = (int(m.group(2), 16), m.group(3), int(m.group(4), 16))
json.dump({f'{t}|{v:#x}': p for (t, v), p in PRO.items()}, open(f'{R}/prologues.json', 'w'), indent=1)
print({t: sum(len(r[3]) for r in D[t]) for t in D}, 'prologues', len(PRO))
