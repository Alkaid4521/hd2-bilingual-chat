"""Compile-only check of the addon Lua with the game's LuaJIT (bin/lua51.dll).

  python tools/lua_syntax_check.py [file ...]        (default: src/bilingual_chat.lua)

Point HD2_LUAJIT_DLL at your lua51.dll, or keep the game in one of the usual Steam libraries.
"""
import ctypes
import os
import sys

CANDIDATES = [
    os.environ.get('HD2_LUAJIT_DLL'),
    r'C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll',
    r'D:\SteamLibrary\steamapps\common\Helldivers 2\bin\lua51.dll',
    r'E:\SteamLibrary\steamapps\common\Helldivers 2\bin\lua51.dll',
]
LUA_DLL = next((path for path in CANDIDATES if path and os.path.isfile(path)), None)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def check(path):
    if not LUA_DLL:
        raise SystemExit('lua51.dll not found: set HD2_LUAJIT_DLL to <game>\\bin\\lua51.dll')
    lib = ctypes.CDLL(LUA_DLL)
    lib.luaL_newstate.restype = ctypes.c_void_p
    lib.luaL_loadbuffer.restype = ctypes.c_int
    lib.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
    lib.lua_tolstring.restype = ctypes.c_char_p
    lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
    state = lib.luaL_newstate()
    assert state, 'luaL_newstate failed'
    source = open(path, 'rb').read()
    rc = lib.luaL_loadbuffer(state, source, len(source), ('@' + os.path.basename(path)).encode())
    if rc != 0:
        size = ctypes.c_size_t()
        message = lib.lua_tolstring(state, -1, ctypes.byref(size))
        print('FAIL %s: %s' % (path, message.decode('utf-8', 'replace')))
        return False
    print('OK   %s (%d bytes compiled)' % (path, len(source)))
    return True


if __name__ == '__main__':
    targets = sys.argv[1:] or [os.path.join(ROOT, 'src', 'bilingual_chat.lua')]
    sys.exit(0 if all([check(path) for path in targets]) else 1)
