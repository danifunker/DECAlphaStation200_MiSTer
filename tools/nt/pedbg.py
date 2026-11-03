import struct, sys
def pe(path):
    d=open(path,'rb').read()
    o=struct.unpack_from('<I',d,0x3c)[0]
    nsec=struct.unpack_from('<H',d,o+6)[0]; optsz=struct.unpack_from('<H',d,o+20)[0]
    base=struct.unpack_from('<I',d,o+24+28)[0]
    secs=[]
    for i in range(nsec):
        s=o+24+optsz+40*i
        name=d[s:s+8].rstrip(b'\0').decode(); vs,va,rs,rp=struct.unpack_from('<IIII',d,s+8)
        secs.append((name,va,vs,rp,rs))
    return d,base,secs
def dbg_syms(path):
    d=open(path,'rb').read()
    nsec,exp,dbgsz=struct.unpack_from('<III',d,0x18)
    off=0x30+nsec*40+exp
    syms={}
    for i in range(dbgsz//28):
        ch,ts,ma,mi,typ,sz,addr,ptr=struct.unpack_from('<IIHHIIII',d,off+i*28)
        if typ!=1: continue
        N,lva=struct.unpack_from('<II',d,ptr)
        symoff=ptr+lva; stroff=symoff+N*18
        i=0
        while i<N:
            e=d[symoff+i*18:symoff+i*18+18]
            if e[:4]==b'\0\0\0\0':
                so=struct.unpack_from('<I',e,4)[0]; nm=d[stroff+so:d.index(b'\0',stroff+so)].decode('latin1')
            else: nm=e[:8].rstrip(b'\0').decode('latin1')
            val,sec,t2,cls,naux=struct.unpack_from('<IhHBB',e,8)
            if sec>0: syms[nm]=(sec,val)
            i+=1+naux
    return syms
drv,dbgf=sys.argv[1],sys.argv[2]
d,base,secs=pe(drv); syms=dbg_syms(dbgf)
name,va,vs,rp,rs=[s for s in secs if s[0]=='.text'][0]
open(drv+'.text','wb').write(d[rp:rp+rs])
with open(drv+'.syms','w') as f:
    for nm,(sec,val) in sorted(syms.items(), key=lambda x:(x[1][0],x[1][1])):
        f.write('%d %08x %s\n'%(sec,base+val,nm))
print(drv,hex(base),[(s[0],hex(s[1])) for s in secs],len(syms),'text',hex(base+va))
