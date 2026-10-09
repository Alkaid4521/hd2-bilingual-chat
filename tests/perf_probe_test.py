"""Frame budget probe: end-to-end check on the game's LuaJIT.

Loads the packed Lua (work/deployed_check.lua -- the bytes that were written into the game slot, or
src/bilingual_chat.lua when the packaging step has not run), gives it the two globals the loader
would give it, then drives _G.update from here with a sleep in between, with PERF_EVERY/PERF_SLOW
turned down so the lines appear within a second.

  python tests/perf_probe_test.py

It cannot show what the game costs; it proves the probe reports and that what it prints is plausible
(our own span stays small, and the gap between frames picks up the wall time we inserted).
"""
import ctypes
import os
import re
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLL = next((p for p in [os.environ.get('HD2_LUAJIT_DLL'),
                        r'E:\SteamLibrary\steamapps\common\Helldivers 2\bin\lua51.dll']
            if p and os.path.isfile(p)), None)
PAYLOAD = os.path.join(ROOT, 'work', 'deployed_check.lua')
if not os.path.isfile(PAYLOAD):
    PAYLOAD = os.path.join(ROOT, 'src', 'bilingual_chat.lua')
FRAMES = 30
SLEEP = 0.008
# the game's lua51.dll does not export the getglobal/setglobal macros
GLOBALS = -10002

PRELUDE = r'''
LOG = {}
GAME_UPDATE = function() end
rawset(_G, 'update', GAME_UPDATE)
rawset(_G, 'CowboyBingusModLoader', {
  api = 1,
  open_log = function(name)
    return {
      write = function(self, text) LOG[#LOG + 1] = text end,
      flush = function(self) end,
    }
  end,
})
'''


class Lua:
    def __init__(self, dll):
        lib = self.lib = ctypes.CDLL(dll)
        lib.luaL_newstate.restype = ctypes.c_void_p
        lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
        lib.luaL_loadstring.restype = ctypes.c_int
        lib.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lib.luaL_loadbuffer.restype = ctypes.c_int
        lib.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
                                        ctypes.c_char_p]
        lib.lua_pcall.restype = ctypes.c_int
        lib.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
        lib.lua_pcall.restype = ctypes.c_int
        lib.lua_tolstring.restype = ctypes.c_char_p
        lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
        lib.lua_getfield.restype = ctypes.c_int
        lib.lua_getfield.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
        lib.lua_rawgeti.restype = ctypes.c_int
        lib.lua_rawgeti.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        lib.lua_pushnumber.restype = None
        lib.lua_pushnumber.argtypes = [ctypes.c_void_p, ctypes.c_double]
        lib.lua_settop.restype = None
        lib.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.state = lib.luaL_newstate()
        assert self.state, 'luaL_newstate failed'
        lib.luaL_openlibs(self.state)

    def error(self, where):
        size = ctypes.c_size_t()
        text = self.lib.lua_tolstring(self.state, -1, ctypes.byref(size))
        print('%s: %s' % (where, text.decode('utf-8', 'replace') if text else '?'))
        return None

    def run(self, source, where, args=0, results=0):
        lib = self.lib
        if lib.luaL_loadbuffer(self.state, source, len(source), b'@' + where.encode()) != 0:
            return self.error('load ' + where)
        if lib.lua_pcall(self.state, args, results, 0) != 0:
            return self.error('run ' + where)
        return True

    def update(self, dt):
        lib = self.lib
        lib.lua_getfield(self.state, GLOBALS, b'update')
        lib.lua_pushnumber(self.state, dt)
        if lib.lua_pcall(self.state, 1, 0, 0) != 0:
            return self.error('update')
        return True

    def log_lines(self):
        lib = self.lib
        lib.lua_getfield(self.state, GLOBALS, b'LOG')
        out, index = [], 1
        while True:
            lib.lua_rawgeti(self.state, -1, index)
            size = ctypes.c_size_t()
            text = lib.lua_tolstring(self.state, -1, ctypes.byref(size))
            lib.lua_settop(self.state, -2)
            if not text:
                break
            out.append(text.decode('utf-8', 'replace'))
            index += 1
        lib.lua_settop(self.state, -1)
        return out


def main():
    if not DLL:
        raise SystemExit('lua51.dll not found: set HD2_LUAJIT_DLL')
    if not os.path.isfile(PAYLOAD):
        raise SystemExit('no payload at %s -- run tools/install_live.py first' % PAYLOAD)
    os.environ['HD2BC_PERF_EVERY'] = '0.2'
    os.environ['HD2BC_PERF_SLOW'] = '0.0001'
    os.environ['HD2BC_MODEL'] = 'test'
    lua = Lua(DLL)
    if lua.run(PRELUDE.encode(), 'prelude') is None:
        return 1
    source = open(PAYLOAD, 'rb').read()
    if lua.run(source, 'addon', results=0) is None:
        return 1
    head = lua.log_lines()
    print('addon log head: %s' % (head[0].strip() if head else '(nothing)'))
    if not head or 'START version=' not in head[0]:
        print('FAIL the addon did not load')
        return 1
    for _ in range(FRAMES):
        if lua.update(1.0 / 60.0) is None:
            return 1
        time.sleep(SLEEP)
    lines = lua.log_lines()
    perf = [line for line in lines if 'PERF' in line]
    failed = 0
    print('%d log lines, %d of them PERF' % (len(lines), len(perf)))
    for line in perf[:2]:
        print('  ' + line.strip())
    if perf:
        print('PASS the probe reports frames')
    else:
        print('FAIL no PERF line at all')
        failed += 1
    summary = [line for line in perf if 'frames=' in line]
    if summary:
        print('PASS ' + summary[-1].strip().split(' ', 2)[-1])
        ours = re.search(r'ours_max=([\d.]+)ms', summary[-1])
        game = re.search(r'game_max=([\d.]+)ms', summary[-1])
        ours = float(ours.group(1)) if ours else None
        game = float(game.group(1)) if game else None
        if ours is not None and ours < 20:
            print('PASS our own span stays small (ours_max=%.1fms)' % ours)
        else:
            print('FAIL our own span looks wrong (ours_max=%s)' % ours)
            failed += 1
        if game is not None and game >= SLEEP * 1000 * 0.5:
            print('PASS the gap picks up the wall time between frames (game_max=%.1fms)' % game)
        else:
            print('FAIL the gap does not look like wall time (game_max=%s)' % game)
            failed += 1
    else:
        print('FAIL no summary line')
        failed += 1
    print('------------------------------------------------------------------------')
    print('%d problem(s)' % failed)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
