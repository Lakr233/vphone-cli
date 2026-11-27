"""kcx.py — read cstrings anywhere in a fileset kernelcache; find adrp+add xrefs from com.apple.kernel __text."""
import sys,struct,re,subprocess
def entries(path):
    f=open(path,'rb').read()
    o=subprocess.run(['xcrun','otool','-l',path],capture_output=True,text=True).stdout
    out=[]
    for m in re.finditer(r'cmd LC_FILESET_ENTRY\n(?:.*\n){0,4}?\s+vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id (\S+)',o):
        out.append((m.group(3),int(m.group(1),16),int(m.group(2))))
    return f,out
def sections(f,fo):
    ncmds=struct.unpack_from('<I',f,fo+16)[0]; off=fo+32; out=[]
    for _ in range(ncmds):
        cmd,cs=struct.unpack_from('<II',f,off)
        if cmd==0x19:
            seg=f[off+8:off+24].rstrip(b'\0').decode()
            for s in range(struct.unpack_from('<I',f,off+64)[0]):
                so=off+72+s*80; out.append((seg,f[so:so+16].rstrip(b'\0').decode(),*struct.unpack_from('<QQI',f,so+32)))
        off+=cs
    return out
def cstr(f,va,secs_all):
    for a,sz,fo in secs_all:
        if fo and a<=va<a+sz: return f[fo+va-a:fo+va-a+100].split(b'\0')[0].decode('latin1')
    return None
if __name__=='__main__':
    f,E=entries(sys.argv[1]); S=[]
    for eid,vb,fo in E: S+= [(a,sz,sfo) for (_,_,a,sz,sfo) in sections(f,fo)]
    for va in sys.argv[2:]: print(va,repr(cstr(f,int(va,16),S)))
