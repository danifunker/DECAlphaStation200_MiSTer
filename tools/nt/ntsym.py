import struct, bisect, sys
d=open(sys.argv[1],'rb').read()
imgbase=struct.unpack_from('<I',d,0x10)[0]
nsec,exp,dbgsz=struct.unpack_from('<III',d,0x18)
off=0x30+nsec*40+exp
syms=[]
for i in range(dbgsz//28):
    ch,ts,ma,mi,typ,sz,addr,ptr=struct.unpack_from('<IIHHIIII',d,off+i*28)
    if typ!=1: continue
    N,lva=struct.unpack_from('<II',d,ptr); so=ptr+lva; st=so+N*18; k=0
    while k<N:
        e=d[so+k*18:so+k*18+18]
        if e[:4]==b'\0\0\0\0':
            o=struct.unpack_from('<I',e,4)[0]; nm=d[st+o:d.index(b'\0',st+o)].decode('latin1')
        else: nm=e[:8].rstrip(b'\0').decode('latin1')
        val,sec,t2,cls,naux=struct.unpack_from('<IhHBB',e,8)
        if sec>0 and not nm.startswith(('.', '$', '__imp', '\x7f')): syms.append((imgbase+val,nm))
        k+=1+naux
syms.sort(); A=[s[0] for s in syms]
for a in sys.argv[2:]:
    pc=int(a,16); i=bisect.bisect_right(A,pc)-1
    print(hex(pc), syms[i][1], '+'+hex(pc-syms[i][0]))
