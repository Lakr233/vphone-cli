"""kc.py — helpers to read words from a fileset kernelcache by VA (correct section resolution)."""
import struct,re,subprocess
class KC:
    def __init__(self,path):
        self.f=open(path,'rb').read()
        o=subprocess.run(['xcrun','otool','-l',path],capture_output=True,text=True).stdout
        self.kfo=int(re.search(r'vmaddr 0x([0-9a-f]+)\n\s+fileoff (\d+)\n\s+entry_id\s+com\.apple\.kernel\s',o).group(2))
        f=self.f; ncmds=struct.unpack_from('<I',f,self.kfo+16)[0]; off=self.kfo+32; self.secs=[]
        for _ in range(ncmds):
            cmd,cs=struct.unpack_from('<II',f,off)
            if cmd==0x19:
                for s in range(struct.unpack_from('<I',f,off+64)[0]):
                    so=off+72+s*80; a,sz,sfo=struct.unpack_from('<QQI',f,so+32)
                    if sfo: self.secs.append((a,sz,sfo))
            off+=cs
    def off(self,va):
        for a,sz,sfo in self.secs:
            if a<=va<a+sz: return sfo+(va-a)
        raise ValueError(hex(va))
    def words(self,va,n): o=self.off(va); return list(struct.unpack_from('<%dI'%n,self.f,o))
    def start(self,va,maxback=0x800):
        o=self.off(va)
        for b in range(0,maxback,4):
            w=struct.unpack_from('<I',self.f,o-b)[0]
            if (w&0xfffffc1f)==0xd503233f or (w&0xfffffc1f)==0xd503237f: return va-b
        return None
