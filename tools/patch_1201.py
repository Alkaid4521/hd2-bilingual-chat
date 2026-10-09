"""Post-1.2.0 fixes found by reading the 20:22 session log.  Every replacement must hit exactly once.

  python tools/patch_1201.py

  1. pcall returns (true, first, second) -- the inbound code read the status from the second value,
     so every successful widget write looked like a failure.
  2. the helper exits after HD2BC_HELPER_IDLE and the mod never started it again, so a session that
     went quiet for 15 minutes silently fell back to curl for the rest of the night.
  3. the workbench (a 4 Hz file poll) and the inbound self test are debugging aids: off by default.
  4. the hook's own thread id and the send -> ring latency are logged, because both are needed to
     judge a crash dump and to answer "did the game really take that message".
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.path.join(ROOT, 'src', 'bilingual_chat.lua')
JS = os.path.join(ROOT, 'helper', 'hd2bc_helper.js')

PATCHES = [
    (JS,
     "      warm_at = Date.now();\n",
     "      warm_at = Date.now();\n      last = Date.now();\n"),

    (LUA,
     "  local function file_exists(path)\n",
     "  -- the thread this hook runs on, logged once.  A crash dump names its faulting thread, so\n"
     "  -- this is what separates \"our frame\" from \"some engine worker thread\" instead of guessing.\n"
     "  local function thread_id()\n"
     "   local at = k.GetProcAddress(k.GetModuleHandleA('kernel32.dll'), 'GetCurrentThreadId')\n"
     "   if at == nil or at == ffi.NULL then return 0 end\n"
     "   return tonumber(ffi.cast('uint32_t (*)(void)', at)())\n"
     "  end\n\n"
     "  local function file_exists(path)\n"),

    (LUA,
     "  local helper_state, helper_proc, helper_at = 'idle', nil, 0\n",
     "  local helper_state, helper_proc, helper_at = 'idle', nil, 0\n"
     "  local helper_restarts = 0\n"),

    (LUA,
     "   elseif helper_state == 'ready' then\n"
     "    if helper_proc and k.WaitForSingleObject(helper_proc, 0) == 0 then\n"
     "     helper_state = 'unavailable'\n"
     "     self.line('HELPER process exited, staying on curl')\n"
     "    end\n"
     "   end\n",
     "   elseif helper_state == 'ready' then\n"
     "    if helper_proc and k.WaitForSingleObject(helper_proc, 0) == 0 then\n"
     "     -- the helper exits on idle (and when its parent disappears).  A session that stayed quiet\n"
     "     -- for a quarter of an hour must not silently lose the fast lane for the rest of the night.\n"
     "     helper_restarts = helper_restarts + 1\n"
     "     if helper_restarts <= 3 then\n"
     "      helper_state = 'idle'\n"
     "      self.line(string.format('HELPER exited, starting it again (restart %d of 3)',\n"
     "       helper_restarts))\n"
     "      start_helper()\n"
     "     else\n"
     "      helper_state = 'unavailable'\n"
     "      self.line('HELPER exited too often, staying on curl')\n"
     "     end\n"
     "    end\n"
     "   end\n"),

    (LUA,
     "    self.line(string.format('ARMED mode=%s prefix=%s transport=%s', mode, prefix, transport))\n",
     "    self.line(string.format('ARMED mode=%s prefix=%s transport=%s tid=%d', mode, prefix,\n"
     "     transport, thread_id()))\n"),

    (LUA,
     "  .. ' self=' .. (os.getenv('HD2BC_INBOUND_SELF') or 'on(default)')\n",
     "  .. ' self=' .. (os.getenv('HD2BC_INBOUND_SELF') or 'off(default)')\n"),

    (LUA,
     "  .. ' workbench=' .. (os.getenv('HD2BC_WORKBENCH') or 'on(default)'))\n",
     "  .. ' workbench=' .. (os.getenv('HD2BC_WORKBENCH') or 'off(default)'))\n"),
]


def main():
    for path, old, new in PATCHES:
        text = io.open(path, encoding='utf-8', newline='').read()
        hits = text.count(old)
        if hits != 1:
            print('FAILED %s: %d hits for %r' % (os.path.basename(path), hits, old[:60]))
            return 1
        io.open(path, 'w', encoding='utf-8', newline='').write(text.replace(old, new, 1))
        print('ok     %s <= %r' % (os.path.basename(path), old.strip()[:58]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
