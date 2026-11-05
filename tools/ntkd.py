#!/usr/bin/env python3
"""A minimal NT 4.0 kernel debugger client for the board's NT (no ALPHAKD/Wine needed).

NT boots with OSLOADOPTIONS "/DEBUG /DEBUGPORT=COM1 /BAUDRATE=115200"; COM1 goes out on the
MiSTer UART (OSD P5 Serial port = COM1) and socat on the MiSTer serves /dev/ttyS1 on TCP:
    ssh root@MISTER 'socat TCP-LISTEN:5150,reuseaddr /dev/ttyS1,raw,echo=0,b115200 &'
    tools/ntkd.py MISTER[:5150] [LOGFILE] [BREAKPOINT...]
It speaks the serial KD protocol just enough to keep the kernel going and show what it says:
it acknowledges every packet, prints DbgPrint output (DEBUG_IO), and answers each state change
with a continue: image loads/unloads (with their names) are DBG_CONTINUE'd, exceptions are
printed (code, address, parameters, first/second chance) and passed back as not handled, so
NT behaves as without a debugger. Ctrl-C quits.
BREAKPOINTs (kernel addresses, hex) are set at every boot (when ntoskrnl's load is reported); a
hit logs the process, the argument registers a0-a2 and ra from the reported context, then the
breakpoint moves to the next instruction and back after it, so it stays armed (the first two
instructions must be straight-line, as in a prologue); A@B (a function's ret at A, its entry
at B) re-arms A from B instead, and v0 is logged with the arguments. A 'u' prefix (u77db14c0) marks a user-mode
address in a shared system DLL (user32, kernel32: the same address in every process): those are set
when tga.dll's load is reported, in csrss, after win32k. Layouts are the NT 4.0 32-bit ones
(windbgkd.h); the raw state-change words are dumped too, to check them.
"""
import socket, struct, sys, time

PACKET_LEADER, CONTROL_LEADER, BREAKIN = 0x30303030, 0x69696969, 0x62626262
T_STATE_CHANGE, T_MANIPULATE, T_DEBUG_IO, T_ACK, T_RESEND, T_RESET = 1, 2, 3, 4, 5, 6
INITIAL_ID, SYNC_ID = 0x80800000, 0x00000800
DBG_CONTINUE, DBG_EXCEPTION_NOT_HANDLED = 0x00010002, 0x80010001
STATES = {0x3030: 'exception', 0x3031: 'load symbols'}
CODES = {0xC0000005: 'ACCESS_VIOLATION', 0x80000003: 'BREAKPOINT', 0x80000004: 'SINGLE_STEP',
         0xC000001D: 'ILLEGAL_INSTRUCTION', 0xC0000094: 'INTEGER_DIVIDE_BY_ZERO',
         0xC0000095: 'INTEGER_OVERFLOW', 0x80000002: 'DATATYPE_MISALIGNMENT',
         0xC000008E: 'FLOAT_DIVIDE_BY_ZERO', 0xC0000090: 'FLOAT_INVALID_OPERATION',
         0xC0000091: 'FLOAT_OVERFLOW', 0xC0000093: 'FLOAT_UNDERFLOW', 0xC000008F: 'FLOAT_INEXACT_RESULT',
         0xC0000096: 'PRIVILEGED_INSTRUCTION', 0xC00000FD: 'STACK_OVERFLOW',
         0xC0000006: 'IN_PAGE_ERROR', 0xC0000025: 'NONCONTINUABLE_EXCEPTION',
         0xC0000026: 'INVALID_DISPOSITION', 0xE06D7363: 'C++ exception'}

host = sys.argv[1] if len(sys.argv) > 1 else '192.168.99.143'
port = 5150
if ':' in host:
    host, port = host.split(':'); port = int(port)
log = open(sys.argv[2], 'a') if len(sys.argv) > 2 else None
ARGS = [a for a in sys.argv[3:] if not a.startswith('scan=')]
BPS = [int(a.split('@')[0], 16) for a in ARGS if not a.startswith('u')]
REARM = {int(a.lstrip('u').split('@')[0], 16): int(a.split('@')[1], 16) for a in ARGS if '@' in a}   # A@B: re-arm A from B
UBPS = [int(a[1:].split('@')[0], 16) for a in ARGS if a.startswith('u')]   # user-mode: set at the display driver's load
bp_handle = {}                  # address -> the kernel's handle
bp_step = {}                    # address+4 -> the breakpoint it stands in for
caller_pid = []                 # ExitWindowsEx callers (winsrv breakpoint)
ubp_wait = set()                # late breakpoints whose code page was not resident yet


def out(s):
    line = time.strftime('%H:%M:%S ') + s
    print(line, flush=True)
    if log:
        log.write(line + '\n'); log.flush()


s = socket.create_connection((host, port))
s.settimeout(1.0)
buf = bytearray()
next_id = INITIAL_ID


def recv_some():
    global last, next_id
    while True:
        try:
            d = s.recv(4096)
            break
        except socket.timeout:
            # our last packet was not acknowledged: the kernel expects the other packet id
            # (a client restarted in the middle of an exchange); flip it and send again
            if last is not None and not acked:
                pid = struct.unpack_from('<I', last, 8)[0] ^ 1
                last = last[:8] + struct.pack('<I', pid) + last[12:]
                next_id = pid ^ 1
                s.sendall(last)
    if not d:
        raise SystemExit('connection closed')
    buf.extend(d)


def take(n):
    while len(buf) < n:
        recv_some()
    r = bytes(buf[:n]); del buf[:n]
    return r


def send_control(ptype, pid):
    s.sendall(struct.pack('<IHHII', CONTROL_LEADER, ptype, 0, pid, 0))


last = None


acked = True


def send_packet(ptype, data):
    global next_id, last, acked
    last = struct.pack('<IHHII', PACKET_LEADER, ptype, len(data), next_id, sum(data) & 0xFFFFFFFF) + data + b'\xAA'
    acked = False
    s.sendall(last)
    next_id ^= 1


def manipulate_continue(status):
    # DBGKD_MANIPULATE_STATE: ApiNumber, ProcessorLevel, Processor, ReturnStatus, u (Continue:
    # ContinueStatus), padded to the 32-bit structure's size
    # (shorter than the kernel's structure gets a resend request: Alpha's is larger than x86's;
    # bytes past it are message data, ignored by a continue)
    d = struct.pack('<IHHII', 0x3136, 0, 0, 0, status) + b'\0' * 112
    send_packet(T_MANIPULATE, d)


def state_change(d):
    new, plev, proc, nproc, thread, pc = struct.unpack_from('<IHHIII', d, 0)
    st = STATES.get(new, hex(new))
    if new == 0x3031:
        plen, base, pid, csum, size, unload = struct.unpack_from('<IIIIIB', d, 20)
        name = d[-plen:].split(b'\0')[0].decode('latin1', 'replace') if plen else '?'
        out('%s %s base %08x size %08x pid %x' % ('UNLOAD' if unload else 'LOAD  ', name, base, size, pid))
        return DBG_CONTINUE
    if new == 0x3030:
        code, flags, rec, addr, npar = struct.unpack_from('<IIIII', d, 20)
        par = struct.unpack_from('<%dI' % min(npar, 15), d, 40)
        first = struct.unpack_from('<I', d, 100)[0]
        out('EXCEPTION %08x %s at %08x (pc %08x thread %08x) params %s %s' % (
            code, CODES.get(code, ''), addr, pc, thread, ' '.join('%08x' % p for p in par),
            'first chance' if first else 'SECOND CHANCE'))
        out('  raw ' + d[:160].hex())
        if code == 0x80000003 and SCAN and not SCANNED:
            SCANNED.append(1); scan_stack(thread)
        return DBG_CONTINUE if code == 0x80000003 else DBG_EXCEPTION_NOT_HANDLED
    out('state %s pc %08x raw %s' % (st, pc, d[:64].hex()))
    return DBG_CONTINUE


pending = []                    # state changes that arrived while a memory read waited for its reply


def read_packet():
    """the next data packet (type, data), acknowledged; control packets are handled here"""
    global next_id
    if pending:
        return pending.pop(0)
    while True:
        while True:
            b = take(1)[0]
            if b in (0x30, 0x69, 0x62):
                rest = take(3)
                if rest == bytes([b]) * 3:
                    leader = b
                    break
                buf[:0] = rest
        if leader == 0x62:
            continue                                    # a break-in byte stream: ignore
        ptype, count, pid, csum = struct.unpack('<HHII', take(12))
        if leader == 0x69:
            if ptype == T_ACK and last is not None and pid == struct.unpack_from('<I', last, 8)[0]:
                globals()['acked'] = True
            if ptype == T_RESET:
                next_id = INITIAL_ID
                send_control(T_RESET, 0)
                out('reset')
            elif ptype == T_RESEND:
                out('kernel asks for a resend')
                if last:
                    s.sendall(last)
            continue
        data = take(count) if count else b''
        take(1)
        if count > 4096 or sum(data) & 0xFFFFFFFF != csum:
            send_control(T_RESEND, 0)
            continue
        send_control(T_ACK, pid)
        return ptype, data


def read_mem(addr, n):
    """DbgKdReadVirtualMemoryApi: n bytes at addr (b'' when the kernel cannot read them)"""
    send_packet(T_MANIPULATE, struct.pack('<IHHIIII', 0x3130, 0, 0, 0, addr, n, 0) + b'\0' * 104)
    while True:
        ptype, d = read_packet()
        if ptype == T_MANIPULATE and struct.unpack_from('<I', d, 0)[0] == 0x3130:
            got = struct.unpack_from('<I', d, 20)[0]
            return d[len(d) - got:] if got else b''
        if ptype == T_STATE_CHANGE:
            # the kernel ran on and reports a new state instead: it will not answer this read;
            # keep the state change for the main loop and give up the read
            pending.append((ptype, d))
            out('(a state change while waiting for memory: the read is dropped)')
            return b''
        out('(packet type %d while waiting for memory)' % ptype)


def u32(addr):
    m = read_mem(addr, 4)
    return struct.unpack('<I', m)[0] if len(m) == 4 else None


def who(thread):
    """the process of a thread: KTHREAD.ApcState.Process (+0x44), then a printable image
    name inside its EPROCESS"""
    proc = u32(thread + 0x44)
    if proc is None:
        return 'thread %08x: unreadable' % thread
    e = read_mem(proc, 0x400)
    names = []
    for i in range(0, len(e) - 16):
        w = e[i:i + 16].split(b'\0')[0]
        if len(w) >= 5 and (w.lower().endswith(b'.exe') or w.lower().endswith(b'.com')) and \
                all(32 < c < 127 for c in w) and (i == 0 or e[i - 1] == 0):
            names.append('%s@+%x' % (w.decode(), i))
    pids = ['pid %x @+%x' % (struct.unpack_from('<I', e, o)[0], o) for o in range(0, min(len(e), 0x200), 4)
            if caller_pid and struct.unpack_from('<I', e, o)[0] in caller_pid]
    return 'thread %08x process %08x image %s%s' % (thread, proc, ', '.join(names) or '?',
                                                    (' [' + ', '.join(pids) + ']') if pids else '')


def write_bp(addr):
    send_packet(T_MANIPULATE, struct.pack('<IHHIII', 0x3134, 0, 0, 0, addr, 0) + b'\0' * 108)
    while True:
        ptype, d = read_packet()
        if ptype == T_MANIPULATE and struct.unpack_from('<I', d, 0)[0] == 0x3134:
            st, h = struct.unpack_from('<I', d, 8)[0], struct.unpack_from('<I', d, 16)[0]
            if st != 0:
                out('breakpoint at %08x refused: %08x' % (addr, st))
                return None
            return h


def restore_bp(h):
    send_packet(T_MANIPULATE, struct.pack('<IHHII', 0x3135, 0, 0, 0, h) + b'\0' * 112)
    while True:
        ptype, d = read_packet()
        if ptype == T_MANIPULATE and struct.unpack_from('<I', d, 0)[0] == 0x3135:
            return


SCAN = [int(a[5:], 16) for a in sys.argv[3:] if a.startswith('scan=')]     # scan=ADDR: at the first breakpoint, dump the stack spots holding ADDR
SCANNED = []


def scan_stack(thread):
    """the stopped thread's whole kernel stack (12 KB below KTHREAD.InitialStack): every longword
    equal to one of the SCAN addresses (an exception PC) with the 24 longwords around it: an
    EXCEPTION_RECORD (code, flags, record, address, nparams, params) or a trap frame / CONTEXT"""
    top = u32(thread + 0x18)
    if not top:
        out('  scan: no stack top'); return
    sp = top - 0x3000
    mem = b''
    a = sp
    while a < top:
        m = read_mem(a, 0x400)
        if len(m) != 0x400:
            out('  scan: read at %08x gave %d bytes' % (a, len(m))); break
        mem += m; a += 0x400
    out('  scan: stack %08x..%08x read %x bytes, looking for %s' % (sp, a, len(mem), ' '.join('%08x' % x for x in SCAN)))
    open('scratch/ntkd/stack_%08x.bin' % sp, 'wb').write(mem); out('  scan: the stack is in scratch/ntkd/stack_%08x.bin' % sp)
    for off in range(0, len(mem) - 4, 4):
        w = struct.unpack_from('<I', mem, off)[0]
        if w in SCAN:
            lo = max(0, off - 48); words = struct.unpack_from('<%dI' % ((min(len(mem), off + 48) - lo) // 4), mem, lo)
            out('  scan: %08x holds %08x: %s' % ((sp & ~0xFF) + off, w, ' '.join('%08x' % x for x in words)))


def context_regs(d, pc):
    """r0-r31 from the reported Alpha CONTEXT: it ends ... IntZero, Fpcr, SoftFpcr, Fir"""
    key = struct.pack('<q', pc - (1 << 32) if pc & 0x80000000 else pc)
    i = d.rfind(key)                # Fir is near the end (an earlier copy of the PC sits in the FP area)
    if i < 0:
        return None
    base = i - 16 - 32 * 8
    return [struct.unpack_from('<Q', d, base + 8 * r)[0] for r in range(32)]


def get_context():
    """DbgKdGetContextApi: the current processor's CONTEXT (with the reply's header in front)"""
    send_packet(T_MANIPULATE, struct.pack('<IHHI', 0x3132, 0, 0, 0) + b'\0' * 116)
    while True:
        ptype, d = read_packet()
        if ptype == T_MANIPULATE and struct.unpack_from('<I', d, 0)[0] == 0x3132:
            return d


def step_bpt(thread, addr):
    """a hard-coded breakpoint (DbgBreakPoint's bpt, or the callkd of DbgBreakPointWithStatus,
    which KeBugCheckEx calls before the blue screen with v0 = 16h, a0 = 1): on Alpha the kernel reports Fir at the bpt
    itself and continuing re-executes it (the system hangs in the debugger), so log the caller
    and move Fir past it with DbgKdSetContextApi, as a debugger does"""
    ctx = get_context()
    key = struct.pack('<q', addr - (1 << 32) if addr & 0x80000000 else addr)
    i = ctx.rfind(key)
    r = context_regs(ctx, addr)
    if i < 0 or not r:
        out('  hard-coded breakpoint at %08x: no context, left as it is' % addr)
        return
    out('BPT %08x (hard-coded) v0 %08x a0 %08x a1 %08x a2 %08x ra %08x sp %08x; %s' % (
        addr, r[0] & 0xFFFFFFFF, r[16] & 0xFFFFFFFF, r[17] & 0xFFFFFFFF, r[18] & 0xFFFFFFFF,
        r[26] & 0xFFFFFFFF, r[30] & 0xFFFFFFFF, who(thread)))
    sp = r[30] & 0xFFFFFFFF
    st = read_mem(sp, 0x100)
    if st:
        out('  stack %08x: %s' % (sp, ' '.join('%08x' % v for v in struct.unpack_from('<%dI' % (len(st) // 4), st))))
    nxt = struct.pack('<q', addr + 4 - (1 << 32) if addr & 0x80000000 else addr + 4)
    ctx = struct.pack('<I', 0x3133) + ctx[4:8] + struct.pack('<I', 0) + ctx[12:i] + nxt + ctx[i + 8:]
    send_packet(T_MANIPULATE, ctx)
    while True:
        ptype, d = read_packet()
        if ptype == T_MANIPULATE and struct.unpack_from('<I', d, 0)[0] == 0x3133:
            if struct.unpack_from('<I', d, 8)[0]:
                out('  set context refused: %08x' % struct.unpack_from('<I', d, 8)[0])
            return


def modules():
    """the current process's loaded modules from its PEB (0x7FFDF000): Ldr (+0xC) ->
    InLoadOrderModuleList (+0xC); entries: DllBase +0x18, SizeOfImage +0x20, BaseDllName +0x2C"""
    ldr = u32(0x7FFDF000 + 0xC)
    if not ldr:
        return 'no PEB/Ldr'
    head = ldr + 0xC
    e, res = u32(head), []
    while e and e != head and len(res) < 40:
        ent = read_mem(e, 0x34)
        if len(ent) < 0x34:
            res.append('?%08x' % e); break
        base, size = struct.unpack_from('<II', ent, 0x18)[0], struct.unpack_from('<I', ent, 0x20)[0]
        ln, _, buf_ = struct.unpack_from('<HHI', ent, 0x2C)
        name = read_mem(buf_, min(ln, 64)).decode('utf-16le', 'replace')
        res.append('%s@%08x+%x' % (name, base, size))
        e = struct.unpack_from('<I', ent, 0)[0]
    return ' '.join(res)


def arm_waiting():
    """set the late breakpoints once their code page can be read (pageable code is often not
    resident yet: a breakpoint 'set' there never takes effect)"""
    for a in sorted(ubp_wait):
        if len(read_mem(a, 4)) == 4:
            if bp_handle.get(a) is not None:
                restore_bp(bp_handle[a])
            bp_handle[a] = write_bp(a)
            ubp_wait.discard(a)
            out('breakpoint %08x set (%s)' % (a, read_mem(a, 4).hex()))


def bp_hit(d, thread, addr):
    """a breakpoint (or its stand-in) hit: True when it was ours"""
    if addr in bp_handle and bp_handle[addr] is not None:
        ctx = get_context()
        if not getattr(bp_hit, 'dumped', False):
            out('  context reply (%d bytes): %s' % (len(ctx), ctx.hex()))
            bp_hit.dumped = True
        r = context_regs(ctx, addr)
        args = ('v0 %08x a0 %08x a1 %08x a2 %08x ra %08x' % (r[0] & 0xFFFFFFFF, r[16] & 0xFFFFFFFF, r[17] & 0xFFFFFFFF,
                                                             r[18] & 0xFFFFFFFF, r[26] & 0xFFFFFFFF)) if r else 'no context'
        out('BREAK %08x %s; %s' % (addr, args, who(thread)))
        if addr == 0x801917D0 and r:            # DbgkForwardException(ExceptionRecord, DebugException, SecondChance)
            er = read_mem(r[16] & 0xFFFFFFFF, 80)
            if len(er) == 80:
                code, flags, _, eaddr, npar = struct.unpack_from('<IIIII', er, 0)
                par = struct.unpack_from('<%dI' % min(npar, 15), er, 20)
                out('  USER EXCEPTION %08x %s at %08x params %s (%s, %s)' % (
                    code, CODES.get(code, ''), eaddr, ' '.join('%08x' % p for p in par),
                    'debug port' if r[17] & 1 else 'exception port', 'second chance' if r[18] & 1 else 'first chance'))
                if not (r[18] & 1):
                    out('  fault address readable here: %s' % (read_mem(eaddr, 4).hex() or 'no'))
                    out('  modules: ' + modules())
        if addr in (0x80132A50, 0x80134EF0) and r:   # NtCreateFile / NtOpenFile: the name (a2 = OBJECT_ATTRIBUTES)
            oa = read_mem(r[18] & 0xFFFFFFFF, 12)
            if len(oa) == 12:
                us = read_mem(struct.unpack_from('<I', oa, 8)[0], 8)
                if len(us) == 8:
                    ln, _, bp = struct.unpack('<HHI', us)
                    out('  file ' + read_mem(bp, min(ln, 256)).decode('utf-16le', 'replace'))
        if addr == 0x5FF9CAC0 and r:            # winsrv!SrvExitWindowsEx(CSR_API_MSG *): who asked
            m = read_mem(r[16] & 0xFFFFFFFF, 64)
            if len(m) >= 48:
                pid, tid = struct.unpack_from('<II', m, 8)
                caller_pid.append(pid)
                out('  ExitWindowsEx from pid %x tid %x, flags %x; message %s' % (pid, tid, struct.unpack_from('<I', m, 40)[0], m.hex()))
        restore_bp(bp_handle[addr]); bp_handle[addr] = None
        nxt = REARM.get(addr, addr + 4)
        bp_step[nxt] = (addr, write_bp(nxt))
        return True
    if addr in bp_step:
        orig, h = bp_step.pop(addr)
        if h is not None:
            restore_bp(h)
        bp_handle[orig] = write_bp(orig)
        return True
    return False


out('connected to %s:%d' % (host, port))
send_control(T_RESET, 0)
while True:
    ptype, data = read_packet()
    if ptype == T_DEBUG_IO:
        api = struct.unpack_from('<I', data, 0)[0]
        if api == 0x3230:
            txt = data[16:].decode('latin1', 'replace').rstrip('\0')
            for ln in txt.splitlines():
                out('DbgPrint: ' + ln)
        else:
            out('debug io api %x (GetString: answering nothing)' % api)
            send_packet(T_DEBUG_IO, struct.pack('<IHHII', 0x3231, 0, 0, 0, 0))
    elif ptype == T_STATE_CHANGE:
        new, _, _, _, thread, pc = struct.unpack_from('<IHHIII', data, 0)
        if new == 0x3030 and struct.unpack_from('<I', data, 20)[0] == 0x80000003 and \
                bp_hit(data, thread, struct.unpack_from('<I', data, 32)[0]):
            arm_waiting()
            manipulate_continue(DBG_CONTINUE)
            continue
        st = state_change(data)
        if new == 0x3030 and struct.unpack_from('<I', data, 20)[0] == 0x80000003 and \
                read_mem(struct.unpack_from('<I', data, 32)[0], 4) in (b'\x80\0\0\0', b'\xad\0\0\0'):
            step_bpt(thread, struct.unpack_from('<I', data, 32)[0])
        if new == 0x3031 and struct.unpack_from('<I', data, 24)[0] == 0x80080000 and BPS:
            bp_handle.clear(); bp_step.clear()          # a new boot: the old handles are gone
            for a in BPS:
                bp_handle[a] = write_bp(a)
            out('breakpoints set: ' + ' '.join('%08x' % a for a in BPS))
        if new == 0x3031 and UBPS and data.find(b'tga.dll') >= 0 and not data[40]:
            ubp_wait.update(UBPS)
        arm_waiting()
        if new == 0x3030 or (new == 0x3031 and struct.unpack_from('<I', data, 24)[0] == 0xFFFFFFFF):
            # an exception, or the 'unload all' NtShutdownSystem sends: who is it
            out('  ' + who(thread))
            out('  state change raw: ' + data.hex())
            # the system call's trap frame is at the top of the kernel stack: user-mode code
            # addresses there (aligned values in 0x01000000-0x7FFE0000) show the caller
            top = u32(thread + 0x18)                    # KTHREAD.InitialStack
            if top:
                ks = read_mem(top - 0x400, 0x400)
                hits = ['%x:%08x' % (0x400 - o, struct.unpack_from('<I', ks, o)[0]) for o in range(0, len(ks) - 3, 4)
                        if 0x01000000 <= struct.unpack_from('<I', ks, o)[0] < 0x7FFE0000 and
                        struct.unpack_from('<I', ks, o)[0] & 3 == 0]
                out('  kernel stack top %08x, user addresses (offset below top:value): %s' % (top, ' '.join(hits)))
        manipulate_continue(st)
    else:
        out('packet type %d, %d bytes: %s' % (ptype, len(data), data[:32].hex()))
        if ptype == T_MANIPULATE:
            # a reply left over from a client that quit mid-exchange: the kernel waits for us
            manipulate_continue(DBG_CONTINUE)
