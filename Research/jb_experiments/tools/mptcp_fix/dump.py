#!/tmp/jbresearch/venv/bin/python
# dump.py <kc> <start_va> <n_ins> : capstone listing of a fixed range, stops at ret
import sys
import kdiff
kc,start,n=sys.argv[1],int(sys.argv[2],16),int(sys.argv[3])
f,kb,secs=kdiff.load(kc,'com.apple.kernel')
for pc,mn,ops in kdiff.dis(f,secs,start,n):
    print(f'{pc:#x}  {mn:8} {ops}')
