"""Offline test of the inbound path (translation under another player's line).

The harness owns the memory layout and also lays out a *fake UI*: one of the 64 widget slots gets
a property table whose body entry (key 0x7518C954) points at exactly the ring buffer the mod is
watching, which is how the mod is supposed to find the row.  A foreign, non-Chinese line is pushed
into the ring; the mod must

  * ignore its own line (learned first),
  * queue the foreign line, translate it through the injected hook,
  * resolve the row by the body pointer,
  * and in the default probe mode *write nothing* -- the property value must still be the ring
    buffer afterwards.

  python tests/inbound_probe_test.py        (needs the game's bin/lua51.dll)
"""
import ctypes
import os
import struct
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault('BC_ADDON', os.path.join(ROOT, 'work', 'bilingual_chat_1.1.0.lua'))
os.environ['HD2BC_INBOUND'] = 'probe'
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mem_send_test as H  # noqa: E402

WIDGET_BASE_OFFSET = 0x4390
WIDGET_STRIDE = 0x3D8
PROP_TABLE_OFFSET = 0x220
PROP_COUNT_OFFSET = 0x158
PROP_ENTRY_SIZE = 0x18
BODY_KEY = 0x7518C954
OTHER_KEY = 0x1234ABCD
ROW = 7
FOREIGN = 'for democracy'
FOREIGN_NAME = 'Teammate'


def main():
    if not H.LUA_DLL:
        raise SystemExit('lua51.dll not found: set HD2_LUAJIT_DLL')
    try:
        sys.stdout.reconfigure(errors='replace')
    except Exception:
        pass
    module = ctypes.create_string_buffer(56 * 1024 * 1024)
    root = ctypes.create_string_buffer(8 * 1024 * 1024)
    module_at, root_at = ctypes.addressof(module), ctypes.addressof(root)
    manager_at = root_at + H.MANAGER_OFFSET
    input_at = manager_at + H.INPUT_OFFSET
    panel_at = manager_at + H.PANEL_STATE_OFFSET
    flag_at = manager_at + H.SUBMIT_FLAG_OFFSET
    slot_at = manager_at + WIDGET_BASE_OFFSET + ROW * WIDGET_STRIDE
    struct.pack_into('<Q', module, H.ROOT_GLOBAL_A, root_at)
    struct.pack_into('<II', root, H.RING_OFFSET + H.RING_META, 0, 0)
    emulate = [True]
    body_pointer = [0]

    def byte(at):
        return ctypes.c_ubyte.from_address(at).value

    def set_input(value):
        ctypes.memset(input_at, 0, 0x100)
        if value:
            blob = value.encode('utf-8')
            ctypes.memmove(input_at, blob, len(blob))

    def box():
        return ctypes.string_at(input_at, 0x100).split(b'\0')[0].decode('utf-8', 'replace')

    def ring_count():
        meta = ctypes.string_at(root_at + H.RING_OFFSET + H.RING_META, 8)
        return int.from_bytes(meta[:4], 'little')

    def push_ring(body, name):
        index = ring_count()
        record = root_at + H.RING_OFFSET + (index % 64) * H.RING_STRIDE
        ctypes.memset(record, 0, H.RING_STRIDE)
        ctypes.memmove(record, struct.pack('<I', H.EVENT_CHAT), 4)
        ctypes.memmove(record + H.NAME_OFFSET, name.encode('utf-8'), len(name.encode('utf-8')))
        ctypes.memmove(record + H.BODY_OFFSET, body.encode('utf-8'), len(body.encode('utf-8')))
        struct.pack_into('<II', root, H.RING_OFFSET + H.RING_META, index + 1, index + 1)
        return index

    def put_u32(at, value):
        ctypes.memmove(at, struct.pack('<I', value), 4)

    def put_u64(at, value):
        ctypes.memmove(at, struct.pack('<Q', value), 8)

    def lay_out_row(index):
        """one row whose body property points at the ring buffer of <index>

        The lookup rule only promises that inside a slot a dword equal to the body key carries the
        value 8 bytes later, so that is what this fake layout provides -- plus a decoy key with a
        different value that must not win.
        """
        target = root_at + H.RING_OFFSET + (index % 64) * H.RING_STRIDE + H.BODY_OFFSET
        ctypes.memset(slot_at, 0, 0x620)
        # entry 0: another property
        put_u32(slot_at + PROP_TABLE_OFFSET, OTHER_KEY)
        put_u32(slot_at + PROP_TABLE_OFFSET + 4, 1)
        put_u64(slot_at + PROP_TABLE_OFFSET + 8, 0)
        # entry 1: the body property -> the ring buffer
        off = PROP_TABLE_OFFSET + PROP_ENTRY_SIZE
        put_u32(slot_at + off, BODY_KEY)
        put_u32(slot_at + off + 4, 1)
        put_u64(slot_at + off + 8, target)
        # decoy: same key far away in the slot, pointing at nothing
        put_u32(slot_at + 0x300, BODY_KEY)
        put_u64(slot_at + 0x308, 0x1234)
        body_pointer[0] = target
        return target

    def entry_value():
        off = slot_at + PROP_TABLE_OFFSET + PROP_ENTRY_SIZE + 8
        return ctypes.c_uint64.from_address(off).value

    def game_tick():
        if byte(panel_at) == 1 and byte(flag_at) == 1:
            ctypes.c_ubyte.from_address(panel_at).value = 0
            ctypes.c_ubyte.from_address(flag_at).value = 0
            if not emulate[0]:
                return
            held = box()
            ctypes.memset(input_at, 0, 0x100)
            if held:
                push_ring(held, H.PLAYER)

    lib = ctypes.CDLL(H.LUA_DLL)
    lib.luaL_newstate.restype = ctypes.c_void_p
    lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lib.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
    lib.luaL_loadbuffer.restype = ctypes.c_int
    lib.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
    lib.lua_pcall.restype = ctypes.c_int
    lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
    lib.lua_tolstring.restype = ctypes.c_char_p
    lib.lua_getfield.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
    lib.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
    state = lib.luaL_newstate()
    lib.luaL_openlibs(state)

    def run(chunk):
        blob = chunk.encode()
        if lib.luaL_loadbuffer(state, blob, len(blob), b'@chunk') != 0:
            size = ctypes.c_size_t()
            raise SystemExit('load: ' + lib.lua_tolstring(state, -1, ctypes.byref(size)).decode())
        if lib.lua_pcall(state, 0, 0, 0) != 0:
            size = ctypes.c_size_t()
            raise SystemExit('run: ' + lib.lua_tolstring(state, -1, ctypes.byref(size)).decode())

    run('''
LOGS = {}
_G.CowboyBingusModLoader = { api = 1, open_log = function(name)
  return { write = function(self, s) LOGS[#LOGS+1] = s end, flush = function() end }
end }
_G.update = function() end
__HD2_BC_TEST = { base = %d, hwnd = 0x10001, wndproc = 0x20001,
  translate = function(src) return 'ZH_OF(' .. src .. ')' end }
''' % module_at)
    source = open(H.ADDON, 'rb').read()
    if lib.luaL_loadbuffer(state, source, len(source), b'@addon') != 0:
        size = ctypes.c_size_t()
        raise SystemExit('addon: ' + lib.lua_tolstring(state, -1, ctypes.byref(size)).decode())
    if lib.lua_pcall(state, 0, 0, 0) != 0:
        size = ctypes.c_size_t()
        raise SystemExit('init: ' + lib.lua_tolstring(state, -1, ctypes.byref(size)).decode())

    def frames(count, sleep=0.05):
        for _ in range(count):
            lib.lua_getfield(state, -10002, b'update')
            if lib.lua_pcall(state, 0, 0, 0) != 0:
                size = ctypes.c_size_t()
                raise SystemExit('update: ' + lib.lua_tolstring(state, -1, ctypes.byref(size)).decode())
            game_tick()
            time.sleep(sleep)

    def logs():
        run('LOGS_JOINED = table.concat(LOGS, "")')
        lib.lua_getfield(state, -10002, b'LOGS_JOINED')
        size = ctypes.c_size_t()
        out = lib.lua_tolstring(state, -1, ctypes.byref(size)).decode('utf-8', 'replace')
        lib.lua_settop(state, 0)
        return out

    frames(4)
    # learn the player's own name the way the game does: type, send, see it come back in the ring
    set_input('你好队友')
    frames(4)
    set_input('')
    frames(2)
    push_ring('你好队友', H.PLAYER)
    frames(20)
    mark = len(logs())

    index = push_ring(FOREIGN, FOREIGN_NAME)
    lay_out_row(index)
    frames(30)
    new_log = logs()[mark:]
    value = entry_value()

    for line in new_log.splitlines():
        if 'INBOUND' in line or 'FAULT' in line:
            print(line[:170])
    print('ring index of the foreign line : %d' % index)
    print('body pointer the row points at : 0x%x' % body_pointer[0])
    print('property value afterwards       : 0x%x' % value)
    print('-' * 72)
    checks = [
        ('the own line was recognised', 'OWN message' in logs()[:mark]),
        ('the foreign line was queued', 'INBOUND queued' in new_log),
        ('it was translated', 'INBOUND translated' in new_log),
        ('the row was resolved by pointer', 'INBOUND probe' in new_log and 'slot=%d' % ROW in new_log),
        ('the translation is reported', 'INBOUND ready' in new_log and 'ZH_OF(%s)' % FOREIGN in new_log),
        ('probe mode wrote nothing', value == body_pointer[0]),
        ('no fault', 'FAULT' not in new_log),
    ]
    ok = True
    for name, passed in checks:
        print('%s %s' % ('PASS' if passed else 'FAIL', name))
        ok = ok and passed
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
