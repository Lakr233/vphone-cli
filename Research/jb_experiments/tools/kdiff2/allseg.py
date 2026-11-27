"""allseg.py — helper: every segment of every image (kernel + fileset kexts) of a decompressed kernelcache."""
import re,struct
def load(K):
    import subprocess
    f=open(K,'rb').read()
    o=subprocess.run(['xcrun','otool','-l',K],capture_output=True,text=True).stdout
    segs=[]
    for m in re.finditer(r'cmd LC_FILESET_ENTRY\n(?:.*\n){3}?\s+entry_id ([^\n]+)',o):
        pass
    # entry_id line follows vmaddr/fileoff; parse robustly: each LC_FILESET_ENTRY block
    for m in re.finditer(r'cmd LC_FILESET_ENTRY\n(?:[^\n]*\n){1,6}?\s*entry_id ([^\n]+)',o):
        blk=m.group(0); name=m.group(1).strip().split(' ')[0]
        vm=int(re.search(r'vmaddr 0x([0-9a-f]+)',blk).group(1),16); fo=int(re.search(r'fileoff (\d+)',blk).group(1))
        ncmds=struct.unpack_from('<I',f,fo+16)[0]; off=fo+32
        for _ in range(ncmds):
            cmd,cs=struct.unpack_from('<II',f,off)
            if cmd==0x19:
                for s in range(struct.unpack_from('<I',f,off+64)[0]):
                    so=off+72+s*80; a,sz,sfo=struct.unpack_from('<QQI',f,so+32)
                    segs.append((name,f[off+8:off+24].rstrip(b'\0').decode(),f[so:so+16].rstrip(b'\0').decode(),a,sz,sfo))
            off+=cs
    return f,segs
