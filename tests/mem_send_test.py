"""Offline test of Bilingual Chat's automatic send, without the game.

The harness owns the memory layout the addon expects and *plays the game*: whenever the addon
writes manager+0x139B8 = 1 and manager+0x1E0F = 1 it consumes them, clears the input box and
pushes the box text into the chat ring -- exactly what the real chat panel update does.

  phase 1  the game reacts  -> the translation must be sent and end up in the ring
  phase 2  the game ignores -> the text must stay in the box (prefill fallback), and the log must
                              say so

  python tests/mem_send_test.py      (needs the game's bin/lua51.dll; override with HD2_LUAJIT_DLL)
"""
import ctypes
import os
import struct
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANDIDATE_DLLS = [
    os.environ.get('HD2_LUAJIT_DLL'),
    r'C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll',
    r'D:\SteamLibrary\steamapps\common\Helldivers 2\bin\lua51.dll',
    r'E:\SteamLibrary\steamapps\common\Helldivers 2\bin\lua51.dll',
]
LUA_DLL = next((path for path in CANDIDATE_DLLS if path and os.path.isfile(path)), None)
ADDON = os.environ.get('BC_ADDON', os.path.join(ROOT, 'src', 'bilingual_chat.lua'))

ROOT_GLOBAL_A = 0x346D538
RING_OFFSET = 0x4F7080
RING_STRIDE = 0x4B4
RING_META = 0x12D00
BODY_OFFSET = 0xB4
NAME_OFFSET = 0x14
MANAGER_OFFSET = 0x14498
INPUT_OFFSET = 0x16D4
PANEL_STATE_OFFSET = 0x139B8
SUBMIT_FLAG_OFFSET = 0x1E0F
EVENT_CHAT = 0x1C12037F
PLAYER = 'Alkaid\u6447\u5149'
FIRST = '\u524d\u65b9\u6709\u654c\u4eba'
SECOND = '\u6211\u5728\u8fd9\u91cc'


def main():
    if not LUA_DLL:
        raise SystemExit('lua51.dll not found: set HD2_LUAJIT_DLL to <game>\\bin\\lua51.dll')
    try:
        sys.stdout.reconfigure(errors='replace')
    except Exception:
        pass
    module = ctypes.create_string_buffer(56 * 1024 * 1024)
    root = ctypes.create_string_buffer(8 * 1024 * 1024)
    module_at, root_at = ctypes.addressof(module), ctypes.addressof(root)
    input_at = root_at + MANAGER_OFFSET + INPUT_OFFSET
    panel_at = root_at + MANAGER_OFFSET + PANEL_STATE_OFFSET
    flag_at = root_at + MANAGER_OFFSET + SUBMIT_FLAG_OFFSET
    struct.pack_into('<Q', module, ROOT_GLOBAL_A, root_at)
    struct.pack_into('<II', root, RING_OFFSET + RING_META, 0, 0)
    emulate = [True]

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
        meta = ctypes.string_at(root_at + RING_OFFSET + RING_META, 8)
        return int.from_bytes(meta[:4], 'little')

    def push_ring(body):
        index = ring_count()
        record = root_at + RING_OFFSET + (index % 64) * RING_STRIDE
        ctypes.memset(record, 0, RING_STRIDE)
        ctypes.memmove(record, struct.pack('<I', EVENT_CHAT), 4)
        ctypes.memmove(record + NAME_OFFSET, PLAYER.encode('utf-8'), len(PLAYER.encode('utf-8')))
        ctypes.memmove(record + BODY_OFFSET, body.encode('utf-8'), len(body.encode('utf-8')))
        struct.pack_into('<II', root, RING_OFFSET + RING_META, index + 1, index + 1)

    def game_tick():
        """what the chat panel update does with the two state bytes"""
        if byte(panel_at) == 1 and byte(flag_at) == 1:
            ctypes.c_ubyte.from_address(panel_at).value = 0
            ctypes.c_ubyte.from_address(flag_at).value = 0
            if not emulate[0]:
                return
            held = box()
            ctypes.memset(input_at, 0, 0x100)
            if held:
                push_ring(held)

    lib = ctypes.CDLL(LUA_DLL)
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

    prelude = '''
LOGS = {}
_G.CowboyBingusModLoader = { api = 1, open_log = function(name)
  return { write = function(self, s) LOGS[#LOGS+1] = s end, flush = function() end }
end }
_G.update = function() end
__HD2_BC_TEST = { base = %d, hwnd = 0x10001, wndproc = 0x20001,
  translate = function(src) return 'EN_OF(' .. src .. ')' end }
''' % module_at
    run(prelude)
    source = open(ADDON, 'rb').read()
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

    def ring_bodies():
        out = []
        for index in range(ring_count()):
            record = root_at + RING_OFFSET + (index % 64) * RING_STRIDE
            body = ctypes.string_at(record + BODY_OFFSET, 0x200).split(b'\0')[0]
            if body:
                out.append(body.decode('utf-8', 'replace'))
        return out

    def send_one(text, wait=40):
        set_input(text)
        frames(4)
        set_input('')
        frames(2)
        push_ring(text)
        frames(wait)

    frames(4)
    mark = len(logs())

    send_one(FIRST)                      # phase 1: the game takes the send
    phase1_log = logs()[mark:]
    phase1_box = box()
    phase1_ring = ring_bodies()

    emulate[0] = False                   # phase 2: the game ignores it -> prefill fallback
    mark2 = len(logs())
    send_one(SECOND)
    phase2_log = logs()[mark2:]
    phase2_box = box()

    for title, body in (('phase 1 log', phase1_log), ('phase 2 log', phase2_log)):
        print('---- %s ----' % title)
        for line in body.splitlines():
            if any(k in line for k in ('OWN', 'TRANSLATE', 'SEND', 'MSEND', 'PREFILL', 'FAULT')):
                print(line[:150])
    print('box after phase 1 : %r' % phase1_box)
    print('ring after phase 1: %r' % phase1_ring)
    print('box after phase 2 : %r' % phase2_box)
    print('-' * 72)
    checks = [
        ("the player's line was recognised", 'OWN message' in phase1_log),
        ('the translation was written into the box', 'SEND wrote' in phase1_log),
        ('the two state bytes were written', 'MSEND armed' in phase1_log),
        ('the send was confirmed', 'MSEND ok sent=1' in phase1_log),
        ('the box was empty afterwards', phase1_box == ''),
        ('the translation is a real chat message', 'EN_OF(%s)' % FIRST in ' '.join(phase1_ring)),
        ('the ring echo was not translated again', phase1_log.count('OWN message') == 1
         and 'PREFILL ready' not in phase1_log),
        ('phase 2 left the text in the box', phase2_box.startswith('EN_OF(')),
        ('phase 2 reported the fallback', 'MSEND failed' in phase2_log),
        ('no fault in either phase', 'FAULT' not in phase1_log and 'FAULT' not in phase2_log),
    ]
    ok = True
    for name, passed in checks:
        print('%s %s' % ('PASS' if passed else 'FAIL', name))
        ok = ok and passed
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
