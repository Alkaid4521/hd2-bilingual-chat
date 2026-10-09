"""Read the first-chance exception out of a Windows minidump: code, address, faulting module.

  python tools/dump_info.py <dump> [...]

WER only keeps the *last* exception signature, and 0xc0000026 (invalid disparity) is the classic
signature of a fault raised while the first fault was being handled -- it tells you nothing about
the real one.  This reads the exception stream directly and maps the address onto the module list,
so today's crash can be compared with the buckets that predate the mod.
"""
import struct
import sys

MINIDUMP_HEADER = '<4sIIII'
DIRECTORY = '<III'
EXCEPTION_STREAM = '<II'          # ThreadId, __alignment; the record follows
EXCEPTION_RECORD = '<IIQQII15Q'   # code, flags, record, address, nparams, pad, params
MODULE = '<QIIII52sII8s8s8s'        # base, size, checksum, timestamp, name_rva, versioninfo,
#                                    cv, misc, reserved0, reserved1  (= 108 bytes)

MODULE_NAMES = {3: 'thread-list', 4: 'module-list', 6: 'exception', 9: 'memory64',
                15: 'misc-info'}


def read(path, rva, size):
    with open(path, 'rb') as f:
        f.seek(rva)
        return f.read(size)


def utf16(data):
    return data.decode('utf-16-le', 'replace').rstrip('\0')


def streams(path):
    head = read(path, 0, struct.calcsize(MINIDUMP_HEADER))
    magic, version, count, dir_rva, checksum = struct.unpack(MINIDUMP_HEADER, head)
    if magic != b'MDMP':
        raise SystemExit('%s is not a minidump (%r)' % (path, magic))
    blob = read(path, dir_rva, count * struct.calcsize(DIRECTORY))
    out = {}
    for i in range(count):
        kind, size, rva = struct.unpack_from(DIRECTORY, blob, i * struct.calcsize(DIRECTORY))
        out.setdefault(kind, (size, rva))
    return out


def modules(path, location):
    size, rva = location
    blob = read(path, rva, size)
    total = struct.unpack_from('<I', blob, 0)[0]
    step = struct.calcsize(MODULE)
    out = []
    for i in range(total):
        fields = struct.unpack_from(MODULE, blob, 4 + i * step)
        base, image_size, name_rva = fields[0], fields[1], fields[4]
        text = read(path, name_rva, 4)
        length = struct.unpack('<I', text)[0]
        name = utf16(read(path, name_rva + 4, length))
        out.append((base, image_size, name))
    return out


def owner(mods, address):
    for base, size, name in mods:
        if base <= address < base + size:
            return '%s+0x%x' % (name.rsplit('\\', 1)[-1], address - base)
    return 'no module (address 0x%x)' % address


def stack_scan(path, table, context_loc, mods, want=4096):
    """no unwinding: read the faulting thread's stack and name every return address in it"""
    size, rva = context_loc
    ctx = read(path, rva, size)
    if len(ctx) < 0x100:
        return None, []
    rsp, rip = struct.unpack_from('<Q', ctx, 0x98)[0], struct.unpack_from('<Q', ctx, 0xF8)[0]
    if 5 not in table:
        return (rsp, rip), []
    blob = read(path, table[5][1], table[5][0])
    total = struct.unpack_from('<I', blob, 0)[0]
    frames = []
    for i in range(total):
        start, dsize, drva = struct.unpack_from('<QII', blob, 4 + i * 16)
        if not (start <= rsp < start + dsize):
            continue
        offset = rsp - start
        take = min(want, dsize - offset)
        stack = read(path, drva + offset, take)
        # a stack region that the stack pointer sits at the bottom of is a stack overflow
        frames.append('region [%#x, %#x)  rsp is %#x above the low end'
                      % (start, start + dsize, rsp - start))
        for j in range(0, len(stack) - 8, 8):
            value = struct.unpack_from('<Q', stack, j)[0]
            name = owner(mods, value)
            if 'no module' not in name:
                frames.append('%#x %s' % (rsp + j, name))
        break
    return (rsp, rip), frames


def report(path):
    table = streams(path)
    print('== %s ==' % path)
    print('   streams: ' + ', '.join(sorted(
        MODULE_NAMES.get(k, 'type%d' % k) for k in table)))
    mods = []
    if 4 in table:
        mods = modules(path, table[4])
    if 6 not in table:
        print('   no exception stream')
    else:
        size, rva = table[6]
        blob = read(path, rva, size)
        thread = struct.unpack_from('<I', blob, 0)[0]
        fields = struct.unpack_from(EXCEPTION_RECORD, blob, struct.calcsize(EXCEPTION_STREAM))
        code, flags, record, address, nparams = fields[:5]
        params = fields[6:]
        print('   exception thread=%d code=0x%08x flags=%#x address=%#x -> %s'
              % (thread, code, flags, address, owner(mods, address)))
        print('   parameters: ' + ' '.join('%#x' % p for p in params[:max(nparams, 1)]))
        ctx_loc = struct.unpack_from('<II', blob, struct.calcsize(EXCEPTION_STREAM)
                                     + struct.calcsize(EXCEPTION_RECORD))
        regs, frames = stack_scan(path, table, ctx_loc, mods)
        if regs:
            print('   rsp=%#x rip=%#x   stack return addresses (raw scan):' % regs)
            for line in frames[:18]:
                print('     ' + line)
    hot = [m for m in mods if any(k in m[2].lower() for k in
                                  ('dxgi', 'reshade', 'shadertoggler', 'nvoglv', 'lua51',
                                   'helldivers2.exe', 'game.dll'))]
    print('   modules loaded: %d' % len(mods))
    for base, size, name in sorted(hot, key=lambda m: m[2]):
        print('     %#018x %8d  %s' % (base, size, name))


if __name__ == '__main__':
    for dump in sys.argv[1:]:
        try:
            report(dump)
        except Exception as exc:                                   # noqa: BLE001
            print('== %s ==\n   FAILED: %s' % (dump, exc))
