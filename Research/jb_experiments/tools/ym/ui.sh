#!/bin/bash
# usage: ui.sh -> flat UI tree of the frontmost app
/tmp/ym/rpc.sh ui.tree '{"nested":false,"visible_only":true,"max_elements":300}' | python3 -c "
import json,sys
d=json.load(sys.stdin)
def p(e,dep=0):
    print(dep, e.get('role'), '|', (e.get('text') or '')[:70], '|', (e.get('identifier') or '')[:50], '|', e.get('frame'))
    for c in e.get('children',[]) or []: p(c,dep+1)
r=d.get('result',d)
if isinstance(r,dict):
    for k in ('elements','tree'):
        if k in r:
            for e in r[k]: p(e)
    if not any(k in r for k in ('elements','tree')): print(json.dumps(r)[:1500])
else:
    for e in r: p(e)
"
