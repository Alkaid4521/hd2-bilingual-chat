-- HD2-Addon: mods/dsh/bilingual_chat9
-- Bilingual chat for Helldivers 2, build 1.2.1.

-- 1.2.1 fixes three things the 20:22 session log exposed: the inbound code read the status of a
-- widget write from the wrong pcall return value (every success looked like a failure, so the
-- placeholder was rewritten five times a second), the helper was never started again after it
-- exited on idle (so a quiet quarter of an hour dropped the session back to curl for good), and the
-- workbench and the self test are off by default again.  It also logs the hook's thread id and how
-- long the game needed to put a sent message into the ring.
--
-- New in 1.2.0: the translation lane was rebuilt in three layers.
--   1. thinking off.  Measured on this endpoint: the same "hello" cost 95 reasoning tokens and
--      1070 ms with thinking on, 1 token and 496 ms with it off (one full sentence: 184 tokens /
--      1491 ms versus 10 tokens / 455 ms).  Every request now asks for no reasoning.
--      HD2BC_THINKING=on brings the old body back.
--   2. one helper process instead of a curl per line.  curl.exe pays a process spawn plus a fresh
--      TLS handshake for every single line (285 ms cold, 67..88 ms once the socket is reused).
--      The mod now starts one node process (helper/hd2bc_helper.js) for the whole session and
--      only exchanges files with it, so every translation after the first rides that connection.
--      curl stays the fallback: no node, a helper that died, or HD2BC_TRANSPORT=curl.
--   3. the row answers immediately.  A teammate's line gets "<INBOUND_LABEL>..." in the frame the
--      message is noticed, the answer replaces it, and a request that fails or times out takes the
--      placeholder back off again.  HD2BC_INBOUND_PLACEHOLDER=0 turns off only this layer.
--
-- New in 1.1.0: inbound translation.  When another player writes something that is not Chinese,
-- the line is translated (same HD2CT_* settings) and the translation is written *under that line*
-- -- in this client only, nothing is broadcast:
--
--     <what the teammate wrote>
--     <INBOUND_LABEL>what it means
--
--   HD2BC_INBOUND = on (default) write the translation into the row (calls the game's body setter)
--                 = probe          report the row resolution and the translation, write nothing
--                 = off            disable inbound translation
--   HD2BC_INBOUND_LABEL = the text put in front of the translation (default is the usual
--                         Chinese "translation:" label, prefixed with a newline)
--   HD2BC_INBOUND_MAX = stop after this many messages (default 0 = no ceiling)
--
-- The UI row is not assumed to share the ring index: a row is matched by the string pointer of
-- its body property (key 0x7518C954) against the ring body address, and nothing is written before
-- that match is confirmed.  Own lines, [EN]/[CN] echoes and messages that are already Chinese are
-- never sent to the API (a Chinese line used to cost a wasted request).
--
-- LIVE WORKBENCH (new in 1.0.7): the game is driven through a command file instead of edits and
-- restarts. Write one line into %LOCALAPPDATA%\HD2BilingualChat\cmd.txt and it is executed in
-- game within a quarter of a second, with the answer in this log:
--   status                     box / ring / mode / foreground / dump state
--   hex <offset> <len>         hex+ascii of manager+offset (the chat manager object)
--   box <text>                 write text into the chat input box
--   cr                         call the game window procedure with WM_CHAR 0x0D (Enter)
--   crkey                      call it with WM_KEYDOWN/WM_KEYUP instead
--   set <offset> <byte>        write one byte of the manager object
--   set32 <offset> <dword>     write four bytes of the manager object
--   submit <text>              write the box, then press Enter 0.4 s later, then report the box
--   scan <seconds>             rank every manager byte that flips while the chat is opened/closed
--   rank [n]                   show that ranking
--   save <offset> <len> <name> snapshot a memory range into snap_<name>.bin
--   call <rva> [arg]           call game.dll+rva with rcx=arg (points at the chat manager)
--   call3 <rva> <rcx> <rdx> <r8> call with three pointer arguments
--   sendbox <text>             write the box and call the game's own chat send directly
--   mods                       module and chat object addresses
--   dumpimg                    dump the loaded game.dll image again
-- The loaded image of game.dll is written once at start up (img_game.dll.bin + img_game.dll.txt)
-- because the on-disk file is packed and cannot be disassembled.
-- Submitting is tried through five routes in turn, because only one of them may be reachable
-- behind the anti-cheat: user32 SendInput (40-byte INPUT), win32u NtUserSendInput (syscall stub),
-- the game window procedure with WM_CHAR CR, win32u NtUserPostMessage key, win32u
-- NtUserPostMessage character. Each try is judged by the input box and the chat ring.
-- Your own message goes out untouched; one to two seconds later a second chat message carrying the
-- translation is sent automatically, so teammates read it too.
--
-- Proven in game:
--   * the chat input box is the UTF-8 buffer at manager+0x16D4 (manager = root+0x14498,
--     root = *(game.dll+0x346D538)); the game treats that text as your own input and really
--     transmits it when the box submits (confirmed in the chat ring);
--   * SendInput / PostMessage / SendMessage / keybd_event are refused inside the game, but the
--     game's own window procedure can be called directly: WM_CHAR delivers text and WM_CHAR 0x0D
--     (the character a real Enter produces) submits it.
-- Translation never runs inside the game process (native code there is what crashed an earlier
-- build): the request goes to %LOCALAPPDATA%\HD2BilingualChat\* and the answer comes back as a
-- file that is read on a later frame. Nothing blocks the render thread.
--
-- Modes: mem (default) the translation is sent by the game itself -- two state bytes are written
--        and the chat panel update does the send, so no key press is needed at all; if the game
--        does not take it the text stays in the box and your own Enter still sends it;
--        prefill writes the translation and waits for your Enter; auto tries the old five submit
--        routes; dry translates only; off disables the mod.
-- Environment: HD2BC_MODE      = mem (default) | prefill | auto | dry | off
--              HD2BC_PREFIX    = auto (default "[EN] " / "[CN] ") | 0 | any literal prefix
--              HD2BC_TRANSPORT = auto (default: helper when node.exe exists, else curl) | helper
--                                | curl | dll (dll = the hd2-chat-translate worker)
--              HD2CT_API_URL / HD2CT_MODEL / HD2CT_API_KEY = the same variables the other mod uses
local Mod = (function()
local ffi = require('ffi')
assert(ffi.os == 'Windows' and ffi.abi('64bit'), 'WINDOWS_X64_REQUIRED')
ffi.cdef[[
void *GetModuleHandleA(const char *);
void *GetCurrentProcess(void);
uint32_t GetCurrentProcessId(void);
void *GetForegroundWindow(void);
uint32_t GetWindowThreadProcessId(void *, uint32_t *);
int IsWindow(void *);
intptr_t GetWindowLongPtrW(void *, int);
int ReadProcessMemory(void *, const void *, void *, size_t, size_t *);
int WriteProcessMemory(void *, void *, const void *, size_t, size_t *);
int QueryPerformanceCounter(int64_t *);
int QueryPerformanceFrequency(int64_t *);
uint32_t GetEnvironmentVariableW(const uint16_t *, uint16_t *, uint32_t);
void *CreateFileW(const uint16_t *, uint32_t, uint32_t, void *, uint32_t, uint32_t, void *);
void *FindFirstFileW(const uint16_t *, void *);
int FindNextFileW(void *, void *);
int FindClose(void *);
int ReadFile(void *, void *, uint32_t, uint32_t *, void *);
int WriteFile(void *, const void *, uint32_t, uint32_t *, void *);
int CloseHandle(void *);
int DeleteFileW(const uint16_t *);
int CreateDirectoryW(const uint16_t *, void *);
void *LoadLibraryW(const uint16_t *);
void *GetProcAddress(void *, const char *);
int CreateProcessW(const uint16_t *, uint16_t *, void *, void *, int, uint32_t, void *,
 const uint16_t *, void *, void *);
uint32_t WaitForSingleObject(void *, uint32_t);
int TerminateProcess(void *, uint32_t);
uint32_t GetLastError(void);
uint32_t SendInput(uint32_t, void *, int);
int32_t NtUserSendInput(uint32_t, void *, int32_t);
int32_t NtUserPostMessage(void *, uint32_t, uintptr_t, intptr_t);
typedef struct {uint32_t type; uint32_t reserved; uint16_t vk; uint16_t scan; uint32_t flags;
 uint32_t time; uint32_t pad0; uint64_t extra; uint64_t pad1;} BcInput;
typedef struct {uint32_t attributes; uint32_t t1lo; uint32_t t1hi; uint32_t t2lo; uint32_t t2hi;
 uint32_t t3lo; uint32_t t3hi; uint32_t size_high; uint32_t size_low; uint32_t reserved0;
 uint32_t reserved1; uint16_t name[260];} BcFindData;
typedef struct {uint32_t cb; void *lpReserved; void *lpDesktop; void *lpTitle;
 uint32_t dwX; uint32_t dwY; uint32_t dwXSize; uint32_t dwYSize; uint32_t dwXCountChars;
 uint32_t dwYCountChars; uint32_t dwFillAttribute; uint32_t dwFlags; uint16_t wShowWindow;
 uint16_t cbReserved2; void *lpReserved2; void *hStdInput; void *hStdOutput; void *hStdError;}
 BcStartupInfo;
typedef struct {void *hProcess; void *hThread; uint32_t pid; uint32_t tid;} BcProcessInfo;
]]
local k = ffi.load('kernel32')
local user32 = ffi.load('user32')
local ok_win32u, win32u = pcall(ffi.load, 'win32u')
local process = k.GetCurrentProcess()
local INVALID_HANDLE = ffi.cast('void *', -1)
local GENERIC_READ = 0x80000000
local GENERIC_WRITE = 0x40000000
local CREATE_ALWAYS = 2
local OPEN_EXISTING = 3
local FILE_ATTRIBUTE_NORMAL = 0x80
local CREATE_NO_WINDOW = 0x08000000
local BUF = 1024 * 1024
local buffer = ffi.new('uint8_t[?]', BUF)
local buffer_at = tonumber(ffi.cast('uintptr_t', buffer))
local count = ffi.new('size_t[1]')
local tmp = ffi.new('uint8_t[4096]')
local wide = ffi.new('uint16_t[1024]')
local read_buf = ffi.new('uint8_t[?]', 65536)
local written_out = ffi.new('uint32_t[1]')
local tick, hz = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
assert(k.QueryPerformanceFrequency(hz) ~= 0, 'QPC_UNAVAILABLE')
local started
local function now()
 k.QueryPerformanceCounter(tick)
 local t = tonumber(tick[0]) / tonumber(hz[0])
 if not started then started = t end
 return t - started
end

local ROOT_GLOBAL_A = 0x346D538
local RING_OFFSET = 0x4F7080
local RING_STRIDE = 0x4B4
local RING_META = 0x12D00
local BODY_OFFSET = 0xB4
local BODY_CAPACITY = 0x400
local NAME_OFFSET = 0x14
local MANAGER_OFFSET = 0x14498
local INPUT_OFFSET = 0x16D4
local INPUT_CAPACITY = 0x100
local PANEL_STATE_OFFSET = 0x139B8
local SUBMIT_FLAG_OFFSET = 0x1E0F
local MSEND_TIMEOUT = 1.5
local EVENT_CHAT = 0x1C12037F
local WM_CHAR = 0x0102
local GWLP_WNDPROC = -4
local CR = 0x0D
local VK_RETURN = 0x0D
local SCAN_RETURN = 0x1C
local BOX_CAPACITY = 200
local TRANSLATE_TIMEOUT = 12.0
local EMPTY_BOX_TIMEOUT = 6.0
local EMPTY_STABLE = 0.25
local RETRY_GAPS = {0.5, 0.5, 1.0, 2.0}
local REGION_OFFSET = 0x1400
local REGION_LENGTH = 0x400
local BODY_LIMIT = 900

local function wide_path(path)
 local out = ffi.new('uint16_t[?]', #path + 1)
 for i = 1, #path do out[i - 1] = path:byte(i) end
 out[#path] = 0
 return out
end
local env_cache = {}
local function env_string(name)
 if env_cache[name] ~= nil then return env_cache[name] or nil end
 if k.GetEnvironmentVariableW(wide_path(name), wide, 1024) == 0 then
  env_cache[name] = false
  return nil
 end
 local out = {}
 for i = 0, 1023 do
  local code = tonumber(wide[i])
  if code == 0 then break end
  if code > 127 then
   env_cache[name] = false
   return nil
  end
  out[#out + 1] = string.char(code)
 end
 local value = table.concat(out)
 env_cache[name] = value ~= '' and value or false
 return env_cache[name] or nil
end
local function u32(s, o)
 if not s or #s < o + 4 then return nil end
 return s:byte(o+1) + s:byte(o+2)*256 + s:byte(o+3)*65536 + s:byte(o+4)*16777216
end
local function u64(s, o)
 local lo, hi = u32(s, o), u32(s, o + 4)
 if not lo or not hi then return nil end
 return lo + hi * 4294967296
end
local function sane(at, n)
 return type(at) == 'number' and at >= 65536 and at + n < 0x800000000000
  and not (at < buffer_at + BUF and at + n > buffer_at)
end
local function read(at, n)
 if not sane(at, n) or n < 1 or n > BUF then return nil end
 count[0] = 0
 if k.ReadProcessMemory(process, ffi.cast('const void *', at), buffer, n, count) == 0
  or tonumber(count[0]) ~= n then return nil end
 return ffi.string(buffer, n)
end
local function write(at, bytes)
 if not sane(at, #bytes) or #bytes > 4096 then return false end
 ffi.copy(tmp, bytes, #bytes)
 count[0] = 0
 if k.WriteProcessMemory(process, ffi.cast('void *', at), tmp, #bytes, count) == 0
  or tonumber(count[0]) ~= #bytes then return false end
 return true
end
local function text(s, cap)
 if not s then return '' end
 local z = s:find('\0', 1, true)
 if z then s = s:sub(1, z - 1) end
 s = s:gsub('[%c]', '.')
 if cap and #s > cap then s = s:sub(1, cap) .. '..' end
 return s
end
local function file_write(path, data)
 local handle = k.CreateFileW(wide_path(path), GENERIC_WRITE, 0, nil, CREATE_ALWAYS,
  FILE_ATTRIBUTE_NORMAL, nil)
 if handle == nil or handle == INVALID_HANDLE then return false end
 local blob = ffi.new('uint8_t[?]', #data)
 ffi.copy(blob, data, #data)
 written_out[0] = 0
 local ok = k.WriteFile(handle, blob, #data, written_out, nil) ~= 0
 if tonumber(written_out[0]) ~= #data then ok = false end
 k.CloseHandle(handle)
 return ok
end
local function file_read(path)
 local handle = k.CreateFileW(wide_path(path), GENERIC_READ, 1, nil, OPEN_EXISTING,
  FILE_ATTRIBUTE_NORMAL, nil)
 if handle == nil or handle == INVALID_HANDLE then return nil end
 written_out[0] = 0
 local ok = k.ReadFile(handle, read_buf, 65536, written_out, nil) ~= 0
 k.CloseHandle(handle)
 if not ok then return nil end
 return ffi.string(read_buf, tonumber(written_out[0]))
end
local function is_cjk(s)
 return s:find('[\228-\233]') ~= nil
end
local function json_escape(s)
 local out = {}
 for i = 1, #s do
  local c, b = s:sub(i, i), s:byte(i)
  if c == '"' then out[#out + 1] = '\\"'
  elseif c == '\\' then out[#out + 1] = '\\\\'
  elseif b < 0x20 then out[#out + 1] = string.format('\\u%04x', b)
  else out[#out + 1] = c end
 end
 return table.concat(out)
end
local function utf8_of(cp)
 if cp < 0x80 then return string.char(cp) end
 if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
 if cp < 0x10000 then
  return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
 end
 return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
  0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end
local ESCAPES = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}
local function json_unescape(s)
 local out, i, n = {}, 1, #s
 while i <= n do
  local c = s:sub(i, i)
  if c ~= '\\' then
   out[#out + 1] = c
   i = i + 1
  else
   local marker = s:sub(i + 1, i + 1)
   if marker == 'u' then
    local cp = tonumber(s:sub(i + 2, i + 5), 16)
    if not cp then return nil end
    i = i + 6
    if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == '\\u' then
     local low = tonumber(s:sub(i + 2, i + 5), 16)
     if low and low >= 0xDC00 and low <= 0xDFFF then
      cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
      i = i + 6
     end
    end
    out[#out + 1] = utf8_of(cp)
   else
    local mapped = ESCAPES[marker]
    if not mapped then return nil end
    out[#out + 1] = mapped
    i = i + 2
   end
  end
 end
 return table.concat(out)
end
-- the assistant's "content" (not "reasoning_content"), without a full JSON parser
local function extract_content(response)
 if type(response) ~= 'string' or response == '' then return nil, 'empty_response' end
 local choices = response:find('"choices"', 1, true)
 if not choices then
  return nil, response:find('"error"', 1, true) and 'api_error' or 'no_choices'
 end
 local at = choices
 while true do
  local key = response:find('"content":"', at, true)
  if not key then return nil, 'no_content' end
  local before = response:sub(math.max(1, key - 12), key - 1)
  if before:sub(-10) ~= 'reasoning_' then
   local out, i = {}, key + 11
   while i <= #response do
    local c = response:sub(i, i)
    if c == '\\' then
     out[#out + 1] = response:sub(i, i + 1)
     i = i + 2
    elseif c == '"' then
     return json_unescape(table.concat(out))
    else
     out[#out + 1] = c
     i = i + 1
    end
   end
   return nil, 'unterminated'
  end
  at = key + 1
 end
end

return {
 new = function(note)
  local self = {version = '1.3.0', lines = 0, maxlines = 20000}
  local base, root, ring, manager, input_at
  local last_meta = ''
  local last_box = ''
  local typed, self_name, verify_text, verify_at, took_at = nil, nil, nil, 0, 0
  local sent_bodies = {}
  local hwnd, wndproc = nil, 0
  local inflight, tr_ready = nil, nil
  local curl_proc, curl_paths, curl_at = nil, nil, 0
  local worker, worker_state = nil, 'unloaded'
  local send_phase, send_at, send_text, wait_since, empty_since = 'idle', 0, nil, 0, 0
  local send_blob, attempt = nil, 0
  local seq = 0
  local dir = nil
  local counters = {own = 0, sent = 0, failed = 0}
  local mode = os.getenv('HD2BC_MODE') or 'mem'
  local prefix = os.getenv('HD2BC_PREFIX') or 'auto'
  local transport = os.getenv('HD2BC_TRANSPORT') or 'auto'
  local in_mode = os.getenv('HD2BC_INBOUND') or 'on'
  local in_label = os.getenv('HD2BC_INBOUND_LABEL') or '\n译文：'
  local in_arg = tonumber(os.getenv('HD2BC_INBOUND_ARG')) or 0x110
  -- the self test writes a translation under our own line; it is a debugging aid, so it is off
  -- unless it is asked for (HD2BC_INBOUND_SELF=1)
  local in_self = os.getenv('HD2BC_INBOUND_SELF') == '1'
  local in_height = os.getenv('HD2BC_INBOUND_HEIGHT') ~= '0'
  -- the placeholder is what makes the feature feel instant: the row says "translating" in the
  -- same frame the message is noticed instead of staying untouched for half a second
  local in_place = os.getenv('HD2BC_INBOUND_PLACEHOLDER') ~= '0'
  -- 0 = no ceiling.  A finite ceiling silently stopped translating after N chat lines.
  local in_max = tonumber(os.getenv('HD2BC_INBOUND_MAX')) or 0
  local self_index = nil
  local in_seen, in_queue, in_ready, in_probed, in_slots = {}, {}, {}, {}, {}
  local in_sig, in_last, in_idle_logged = nil, 0, false
  -- in_temp = the placeholder is on that row right now, in_pending = a placeholder is wanted but
  -- the row was not laid out yet, in_base_h = the height the row had before we touched it (never
  -- its current height, or every rewrite would double it again)
  local in_temp, in_pending, in_base_h = {}, {}, {}
   -- ring index -> the widget slot that showed it last time; a rewrite usually goes to the same slot
   local in_row = {}
  local in_place_at = 0
  local in_stats = {seen = 0, done = 0, applied = 0, failed = 0, placed = 0, reverted = 0}
  -- a translation of our own line that was put on hold while the helper booted
  local pending_self = nil

  function self.line(s)
   if self.lines >= self.maxlines then return end
   self.lines = self.lines + 1
   note(string.format('t=%.1f %s', now(), s))
  end

  -- ---- frame budget probe ---------------------------------------------------------------------
  -- The game calls _G.update once per frame, so the wall time between two entries is a frame, the wall
  -- time inside our hook is what this mod costs, and the wall time between the end of our hook and the
  -- next entry is the game's own work -- which is where its chat layout lands after we change a row.
  -- Both halves are measured, so a stutter can be attributed.  One QPC call per frame.
  local PERF_ON = os.getenv('HD2BC_PERF') ~= '0'
  local PERF_SLOW = tonumber(os.getenv('HD2BC_PERF_SLOW')) or 0.020
  local PERF_EVERY = tonumber(os.getenv('HD2BC_PERF_EVERY')) or 10.0
  local perf_buckets, perf_ours_max, perf_game_max = {}, 0, 0
  local perf_frames, perf_ours_slow, perf_game_slow = 0, 0, 0
  local perf_at, perf_log_at = 0, 0
  local perf_tag, perf_last_tag = '', ''
  local function perf_note(s)
   if not PERF_ON then return end
   perf_tag = perf_tag == '' and s or (perf_tag .. '+' .. s)
   if #perf_tag > 48 then perf_tag = perf_tag:sub(1, 48) end
  end
  local function perf_bucket(seconds)
   local slot = math.floor(seconds / 0.004) + 1
   return slot > 8 and 8 or slot
  end
  local function perf_end(t0)
   if not PERF_ON then return end
   local t1 = now()
   local ours = t1 - t0
   local game = perf_at > 0 and (t0 - perf_at) or 0
   perf_at = t1
   perf_frames = perf_frames + 1
   if ours > perf_ours_max then perf_ours_max = ours end
   if game > perf_game_max then perf_game_max = game end
   if ours >= PERF_SLOW then
    perf_ours_slow = perf_ours_slow + 1
    note(string.format('t=%.1f PERF ours=%.0fms tag=%s', t1, ours * 1000, perf_tag))
   end
   if game >= PERF_SLOW then
    perf_game_slow = perf_game_slow + 1
    note(string.format('t=%.1f PERF game=%.0fms tag=%s', t1, game * 1000, perf_last_tag))
   end
   local slot = perf_bucket(ours)
   perf_buckets[slot] = (perf_buckets[slot] or 0) + 1
   if perf_log_at == 0 then perf_log_at = t1 end
   if t1 - perf_log_at >= PERF_EVERY then
    local seen, p99 = 0, 0
    for i = 1, 8 do seen = seen + (perf_buckets[i] or 0) end
    for i = 1, 8 do
     p99 = p99 + (perf_buckets[i] or 0)
     if p99 >= seen * 0.99 then p99 = (i - 1) * 4 break end
    end
    note(string.format(
     't=%.1f PERF %ds frames=%d ours_max=%.0fms p99~%dms slow=%d game_max=%.0fms slow=%d tag=%s',
     t1, PERF_EVERY, perf_frames, perf_ours_max * 1000, p99, perf_ours_slow,
     perf_game_max * 1000, perf_game_slow, perf_last_tag))
    perf_buckets, perf_ours_max, perf_game_max = {}, 0, 0
    perf_frames, perf_ours_slow, perf_game_slow = 0, 0, 0
    perf_log_at = t1
   end
   perf_last_tag, perf_tag = perf_tag, ''
  end


  local function hook()
   local t = rawget(_G, '__HD2_BC_TEST')
   if type(t) == 'table' then return t end
   return nil
  end

  local function resolve()
   local inj = hook()
   local image = inj and ffi.cast('void *', inj.base) or k.GetModuleHandleA('game.dll')
   if image == nil or image == ffi.NULL then return nil, 'no_game_dll' end
   base = tonumber(ffi.cast('uintptr_t', image))
   root = u64(read(base + ROOT_GLOBAL_A, 8), 0)
   if not root then return nil, 'root_unreadable' end
   ring = root + RING_OFFSET
   manager = root + MANAGER_OFFSET
   input_at = manager + INPUT_OFFSET
   if not read(ring + RING_META, 8) then return nil, 'ring_meta_unreadable' end
   if not read(input_at, 64) then return nil, 'input_unreadable' end
   self.line(string.format('BASE image=0x%x root=0x%x ring=0x%x manager=0x%x input=0x%x',
    base, root, ring, manager, input_at))
   return true
  end

  local function work_dir()
   if dir then return dir end
   local root_dir = env_string('LOCALAPPDATA')
   if not root_dir then return nil end
   local path = root_dir .. '\\HD2BilingualChat'
   k.CreateDirectoryW(wide_path(path), nil)
   dir = path
   return dir
  end

  local function sample_region()
   return read(manager + REGION_OFFSET, REGION_LENGTH)
  end
  local function diff_region(a, b)
   if not a or not b then return 'unreadable' end
   local out, changed = {}, 0
   for off = 0, REGION_LENGTH - 4, 4 do
    local x, y = a:sub(off + 1, off + 4), b:sub(off + 1, off + 4)
    if x ~= y then
     changed = changed + 1
     if #out < 8 then out[#out + 1] = string.format('+0x%x', off) end
    end
   end
   return string.format('n=%d %s', changed, table.concat(out, ' '))
  end

  local function read_box()   local bytes = read(input_at, INPUT_CAPACITY)
   if not bytes then return nil end
   local z = bytes:find('\0', 1, true)
   if not z then return nil end
   return bytes:sub(1, z - 1)
  end

  local function request_body(source, target)
   local model = env_string('HD2CT_MODEL') or 'deepseek-chat'
   local system = 'You translate video game chat. Answer with the translation only, '
    .. 'no quotes and no explanation.'
   local user = 'Translate this Helldivers 2 chat line into ' .. target .. ':\n' .. source
   -- Measured on this endpoint: thinking on burned 95 reasoning tokens / 1070 ms on "hello" and
   -- 184 tokens / 1491 ms on one sentence; a chat line has nothing to reason about, so both
   -- switches go out (either alone stops it) and the same two calls came back in 496 / 455 ms with
   -- 1 and 10 tokens.  HD2BC_THINKING=on restores the old body for providers that reject them.
   local quiet = os.getenv('HD2BC_THINKING') == 'on' and ''
    or ',"reasoning_effort":"none","thinking":{"type":"disabled"}'
   return string.format(
    '{"model":"%s","messages":[{"role":"system","content":"%s"},{"role":"user","content":"%s"}],'
    .. '"temperature":0.2,"max_tokens":200,"stream":false%s}',
    json_escape(model), json_escape(system), json_escape(user), quiet)
  end

  -- ---- transport: curl in a separate process -------------------------------------------
  local function start_curl(body)
   local where = work_dir()
   local url = env_string('HD2CT_API_URL')
   local key = env_string('HD2CT_API_KEY')
   local system_root = env_string('SystemRoot') or 'C:\\Windows'
   if not where or not url or not key then
    self.line('CURL config missing (LOCALAPPDATA / HD2CT_API_URL / HD2CT_API_KEY)')
    return nil, 'no_config'
   end
   seq = seq + 1
   local body_path = string.format('%s\\body%d.json', where, seq)
   local cfg_path = string.format('%s\\curl%d.cfg', where, seq)
   local resp_path = string.format('%s\\resp%d.json', where, seq)
   if not file_write(body_path, body) or not file_write(cfg_path, string.format(
     'url = "%s/chat/completions"\nheader = "Content-Type: application/json"\n'
     .. 'header = "Authorization: Bearer %s"\nsilent\nshow-error\n', url, key)) then
    self.line('CURL could not stage the request files')
    return nil, 'no_stage'
   end
   perf_note('curl_spawn')
   local cmd = string.format('"%s\\System32\\curl.exe" --config "%s" --data-binary "@%s" -o "%s"',
    system_root, cfg_path, body_path, resp_path)
   local cmdline = ffi.new('uint16_t[?]', #cmd + 1)
   for i = 1, #cmd do cmdline[i - 1] = cmd:byte(i) end
   local startup = ffi.new('BcStartupInfo[1]')
   startup[0].cb = ffi.sizeof(startup[0])
   local info = ffi.new('BcProcessInfo[1]')
   if k.CreateProcessW(nil, cmdline, nil, nil, 0, CREATE_NO_WINDOW, nil, nil, startup, info) == 0 then
    self.line('CURL CreateProcess failed err=' .. tostring(tonumber(k.GetLastError())))
    return nil, 'no_process'
   end
   k.CloseHandle(info[0].hThread)
   curl_proc = info[0].hProcess
   curl_paths = {body = body_path, cfg = cfg_path, resp = resp_path}
   curl_at = now()
   return true
  end

  local function cleanup_curl()
   if curl_proc then k.CloseHandle(curl_proc) end
   if curl_paths then
    k.DeleteFileW(wide_path(curl_paths.body))
    k.DeleteFileW(wide_path(curl_paths.cfg))
   end
   curl_proc, curl_paths = nil, nil
  end

  local function poll_curl()
   if not curl_proc then return nil end
   local signal = k.WaitForSingleObject(curl_proc, 0)
   if signal ~= 0 then
    if now() - curl_at > TRANSLATE_TIMEOUT then
     k.TerminateProcess(curl_proc, 1)
     self.line('CURL timeout')
     cleanup_curl()
     return 'TIMEOUT'
    end
    return nil
   end
   local response = curl_paths.resp and file_read(curl_paths.resp) or nil
   local keep = curl_paths.resp
   cleanup_curl()
   if keep then k.DeleteFileW(wide_path(keep)) end
   if not response or response == '' then return 'ERR\nCURL_EMPTY' end
   return response
  end

  -- ---- transport: one keep-alive helper process (node) ---------------------------------
  -- curl.exe pays a process spawn plus a fresh TLS handshake for every single line (measured:
  -- 285 ms cold, 67..88 ms on a reused socket).  This keeps one node process for the whole
  -- session, so every translation after the first rides the same connection, and the mod only
  -- exchanges files with it.  curl stays the fallback: no node, a helper that died, or
  -- HD2BC_TRANSPORT=curl all land back on it.
  local HELPER_JS = [==['use strict';
// HD2BilingualChat transport helper.  Started once by the game (BilingualChat.lua) and kept
// alive for the whole session, so every translation reuses one TLS connection instead of
// spawning curl.exe and handshaking again for each chat line.
//
//   node hd2bc_helper.js <dir>
//
// <dir> holds, all files owned by one side each:
//   helper.cfg   in   url=, token=, idle=<ms>, warm=<0|1>          written by the mod
//   helper.ready out  "<pid> node <version>"                       written once at startup
//   job.tmp      in   staging file, renamed to job.json to publish (never read)
//   job.json     in   {"id":"<pid>-<n>","body":"<raw request body>"}
//   raw.txt      out  the API response body, exactly as received
//   out.txt      out  id=, ok=, ms=, reused=, status=, err=
//   helper.log   out  the helper's own trace, for diagnosing a silent transport
const fs = require('fs');
const path = require('path');
const https = require('https');

const DIR = process.argv[2] || '.';
const P = function (name) { return path.join(DIR, name); };
const sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };

function log(line) {
  try { fs.appendFileSync(P('helper.log'), new Date().toISOString() + ' ' + line + '\n'); } catch (e) {}
}

// the mod polls out.txt, so raw.txt must be complete before out.txt appears: rename, not write
function atomic(file, data) {
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

function read_cfg() {
  let raw;
  try { raw = fs.readFileSync(P('helper.cfg'), 'utf8'); } catch (e) { return null; }
  raw = raw.replace(/^\uFEFF/, '');
  const out = {};
  for (const line of raw.split(/\r?\n/)) {
    const at = line.indexOf('=');
    if (at > 0) out[line.slice(0, at).trim()] = line.slice(at + 1);
  }
  return out.url ? out : null;
}

const endpoint = function (url, tail) { return url.replace(/[\/\s]+$/, '') + tail; };
const agent = new https.Agent({ keepAlive: true, maxSockets: 1, maxFreeSockets: 1, keepAliveMsecs: 60000 });
const sockets = new WeakSet();

// reused=1 proves the connection survived: that is the whole point of this process
function call(url, method, body, token) {
  return new Promise(function (resolve) {
    const started = Date.now();
    let reused = -1;
    let target;
    try { target = new URL(url); } catch (e) {
      resolve({ status: 0, body: '', reused: reused, ms: 0, err: 'bad_url' });
      return;
    }
    const headers = { accept: 'application/json', 'content-type': 'application/json' };
    if (token) headers.authorization = 'Bearer ' + token;
    if (body) headers['content-length'] = Buffer.byteLength(body);
    const req = https.request({
      hostname: target.hostname, port: target.port || 443,
      path: target.pathname + target.search, method: method, agent: agent, headers: headers
    }, function (res) {
      const chunks = [];
      res.on('data', function (c) { chunks.push(c); });
      res.on('end', function () {
        resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8'),
          reused: reused, ms: Date.now() - started, err: '' });
      });
    });
    req.on('socket', function (s) { reused = sockets.has(s) ? 1 : 0; sockets.add(s); });
    req.on('error', function (e) {
      resolve({ status: 0, body: '', reused: reused, ms: Date.now() - started,
        err: String((e && e.message) || e).replace(/\s+/g, '_') });
    });
    req.setTimeout(45000, function () { req.destroy(new Error('timeout')); });
    if (body) req.write(body);
    req.end();
  });
}

(async function main() {
  for (const name of ['job.json', 'job.taken.json', 'out.txt', 'raw.txt']) {
    try { fs.unlinkSync(P(name)); } catch (e) {}
  }
  try { fs.writeFileSync(P('helper.log'), ''); } catch (e) {}
  atomic(P('helper.ready'), process.pid + ' node ' + process.version + '\n');
  log('ready pid=' + process.pid + ' node=' + process.version + ' ppid=' + process.ppid);

  let last = Date.now();
  let warm_at = 0;
  let lost_parent = 0;
  for (;;) {
    await sleep(50);
    const cfg = read_cfg();
    const idle = Number(cfg && cfg.idle) || 900000;
    if (Date.now() - last > idle) {
      log('idle exit after ' + Math.round((Date.now() - last) / 1000) + 's');
      try { fs.unlinkSync(P('helper.ready')); } catch (e) {}
      process.exit(0);
    }
    // the game closing must not leave a stray process behind
    try { process.kill(process.ppid, 0); lost_parent = 0; } catch (e) { lost_parent += 1; }
    if (lost_parent >= 2) {
      log('parent ' + process.ppid + ' gone, exit');
      try { fs.unlinkSync(P('helper.ready')); } catch (e) {}
      process.exit(0);
    }
    // keep the connection genuinely warm between chat lines; /models costs no tokens
    if (cfg && cfg.warm !== '0' && Date.now() - warm_at > 45000 && Date.now() - last > 3000) {
      warm_at = Date.now();
      last = Date.now();
      call(endpoint(cfg.url, '/models'), 'GET', null, cfg.token).then(function (r) {
        log('warm status=' + r.status + ' reused=' + r.reused + ' ms=' + r.ms + ' ' + r.err);
      });
    }

    try { fs.renameSync(P('job.json'), P('job.taken.json')); } catch (e) {
      if (e.code !== 'ENOENT') log('take failed ' + e.code);
    }
    if (fs.existsSync(P('job.taken.json'))) {
      let job = null;
      try { job = JSON.parse(fs.readFileSync(P('job.taken.json'), 'utf8').replace(/^\uFEFF/, '')); } catch (e) {
        log('job parse failed: ' + String(e.message));
      }
      try { fs.unlinkSync(P('job.taken.json')); } catch (e) {}
      if (job && job.id) {
        const started = Date.now();
        const url = endpoint((cfg && cfg.url) || '', '/chat/completions');
        const res = cfg ? await call(url, 'POST', String(job.body || ''), cfg.token)
          : { status: 0, body: '', reused: -1, ms: 0, err: 'no_cfg' };
        if (res.body) atomic(P('raw.txt'), res.body);
        atomic(P('out.txt'), 'id=' + job.id + '\nok=' + ((res.err || !res.body) ? 0 : 1)
          + '\nms=' + res.ms + '\nreused=' + res.reused + '\nstatus=' + res.status
          + '\nerr=' + (res.err || '') + '\n');
        log('job id=' + job.id + ' status=' + res.status + ' ms=' + res.ms + ' reused=' + res.reused
          + ' bytes=' + res.body.length + ' total=' + (Date.now() - started) + (res.err ? ' err=' + res.err : ''));
      }
      last = Date.now();
    }
  }
})();
]==]

  local helper_state, helper_proc, helper_at = 'idle', nil, 0
  local helper_restarts = 0
  local helper_dir_path, helper_job_id, helper_seq, node_path = nil, nil, 0, nil
  local helper_probe_at, helper_poll_at = 0, 0

  -- the thread this hook runs on, logged once.  A crash dump names its faulting thread, so
  -- this is what separates "our frame" from "some engine worker thread" instead of guessing.
  local function thread_id()
   local at = k.GetProcAddress(k.GetModuleHandleA('kernel32.dll'), 'GetCurrentThreadId')
   if at == nil or at == ffi.NULL then return 0 end
   return tonumber(ffi.cast('uint32_t (*)(void)', at)())
  end

  local function file_exists(path)
   local handle = k.CreateFileW(wide_path(path), GENERIC_READ, 1, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, nil)
   if handle == nil or handle == INVALID_HANDLE then return false end
   k.CloseHandle(handle)
   return true
  end

  -- wide_path hands back one shared buffer, so a two path call needs its own
  local function wide_of(path)
   local buf = ffi.new('uint16_t[?]', #path + 1)
   for i = 1, #path do buf[i - 1] = path:byte(i) end
   buf[#path] = 0
   return buf
  end

  -- publish by rename: a directory poller can never observe a half written file.  MoveFileExW is
  -- fetched by hand so the shared cdef block stays untouched.
  local move_fn
  local function file_move(from, to)
   if move_fn == nil then
    local at = k.GetProcAddress(k.GetModuleHandleA('kernel32.dll'), 'MoveFileExW')
    move_fn = (at ~= nil and at ~= ffi.NULL)
     and ffi.cast('int (*)(const uint16_t *, const uint16_t *, uint32_t)', at) or false
   end
   if not move_fn then return false end
   return move_fn(wide_of(from), wide_of(to), 1) ~= 0
  end

  local function helper_dir()
   if helper_dir_path then return helper_dir_path end
   local root = work_dir()
   if not root then return nil end
   helper_dir_path = root .. '\\helper'
   k.CreateDirectoryW(wide_path(helper_dir_path), nil)
   return helper_dir_path
  end

  local function helper_path(name)
   local folder = helper_dir()
   if not folder then return nil end
   return folder .. '\\' .. name
  end

  local function find_node()
   if node_path ~= nil then return node_path or nil end
   local list = {}
   local pf = env_string('ProgramFiles') or 'C:\\Program Files'
   local pf86, la = env_string('ProgramFiles(x86)'), env_string('LOCALAPPDATA')
   list[#list + 1] = pf .. '\\nodejs\\node.exe'
   if pf86 then list[#list + 1] = pf86 .. '\\nodejs\\node.exe' end
   if la then
    list[#list + 1] = la .. '\\Programs\\nodejs\\node.exe'
    list[#list + 1] = la .. '\\nvs\\node\\node.exe'
   end
   local path_env = env_string('PATH')
   if path_env then
    for item in path_env:gmatch('[^;]+') do
     if #list < 64 then list[#list + 1] = (item:gsub('"', '')) .. '\\node.exe' end
    end
   end
   node_path = false
   for i = 1, #list do
    if file_exists(list[i]) then node_path = list[i] break end
   end
   return node_path or nil
  end

  local function start_helper()
   if helper_state == 'ready' or helper_state == 'starting' then return true end
   if helper_state ~= 'idle' then return false end
   local node = find_node()
   if not node then
    helper_state = 'unavailable'
    self.line('HELPER no node.exe found, staying on curl')
    return false
   end
   local folder, js = helper_dir(), helper_path('hd2bc_helper.js')
   local url, key = env_string('HD2CT_API_URL'), env_string('HD2CT_API_KEY')
   if not folder or not url or not key then
    helper_state = 'unavailable'
    self.line('HELPER config missing (HD2CT_API_URL / HD2CT_API_KEY), staying on curl')
    return false
   end
   if not file_write(js, HELPER_JS) then
    helper_state = 'unavailable'
    self.line('HELPER could not write ' .. tostring(js))
    return false
   end
   file_write(helper_path('helper.cfg'), string.format('url=%s\ntoken=%s\nidle=%s\nwarm=%s\n', url,
    key, os.getenv('HD2BC_HELPER_IDLE') or '900000',
    os.getenv('HD2BC_HELPER_WARM') == '0' and '0' or '1'))
   -- a ready file left behind by an earlier session would look like a live helper
   k.DeleteFileW(wide_path(helper_path('helper.ready')))
   local cmd = string.format('"%s" "%s" "%s"', node, js, folder)
   local cmdline = ffi.new('uint16_t[?]', #cmd + 1)
   for i = 1, #cmd do cmdline[i - 1] = cmd:byte(i) end
   local startup = ffi.new('BcStartupInfo[1]')
   startup[0].cb = ffi.sizeof(startup[0])
   local info = ffi.new('BcProcessInfo[1]')
   if k.CreateProcessW(nil, cmdline, nil, nil, 0, CREATE_NO_WINDOW, nil, nil, startup, info) == 0 then
    helper_state = 'unavailable'
    self.line('HELPER CreateProcess failed err=' .. tostring(tonumber(k.GetLastError())))
    return false
   end
   k.CloseHandle(info[0].hThread)
   helper_proc, helper_at, helper_state = info[0].hProcess, now(), 'starting'
   perf_note('helper_spawn')
   self.line('HELPER starting node=' .. node)
   return true
  end

  local function helper_tick()
   if helper_state == 'starting' then
    -- helper.ready is a file open per test; a helper that boots in 0.3 s does not need 60 of them
    if now() - helper_probe_at < 0.1 then return end
    helper_probe_at = now()
    if file_exists(helper_path('helper.ready')) then
     helper_state = 'ready'
     self.line(string.format('HELPER ready in %.2fs', now() - helper_at))
    elseif now() - helper_at > 8 then
     helper_state = 'unavailable'
     self.line('HELPER never reported ready, staying on curl')
    end
   elseif helper_state == 'ready' then
    if helper_proc and k.WaitForSingleObject(helper_proc, 0) == 0 then
     -- the helper exits on idle (and when its parent disappears).  A session that stayed quiet
     -- for a quarter of an hour must not silently lose the fast lane for the rest of the night.
     helper_restarts = helper_restarts + 1
     if helper_restarts <= 3 then
      helper_state = 'idle'
      self.line(string.format('HELPER exited, starting it again (restart %d of 3)',
       helper_restarts))
      start_helper()
     else
      helper_state = 'unavailable'
      self.line('HELPER exited too often, staying on curl')
     end
    end
   end
  end

  local function start_helper_job(body)
   local id = string.format('%d-%d', tonumber(k.GetCurrentProcessId()) or 0, helper_seq + 1)
   local tmp, job = helper_path('job.tmp'), helper_path('job.json')
   if not file_write(tmp, string.format('{"id":"%s","body":"%s"}', id, json_escape(body))) then
    return nil, 'no_stage'
   end
   if not file_move(tmp, job) then
    k.DeleteFileW(wide_path(tmp))
    return nil, 'no_publish'
   end
   helper_seq, helper_job_id = helper_seq + 1, id
   perf_note('stage')
   return true
  end

  -- the id in the answer is what makes a stale out.txt harmless: a reply for someone else's job
  -- is silently ignored instead of being parsed as this one
  local function poll_helper()
   local meta = file_read(helper_path('out.txt'))
   if not meta then return nil end
   local fields = {}
   for name, value in meta:gmatch('([%w_]+)=([^\r\n]*)') do fields[name] = value end
   if fields.id == nil or fields.id ~= helper_job_id then return nil end
   helper_job_id = nil
   if fields.ok ~= '1' then
    return 'ERR\n' .. ((fields.err ~= nil and fields.err ~= '') and fields.err
     or ('HTTP_' .. tostring(fields.status))), fields
   end
   local raw = file_read(helper_path('raw.txt'))
   if not raw or raw == '' then return 'ERR\nHELPER_EMPTY', fields end
   perf_note('answer')
   return raw, fields
  end

  -- one place decides which lane carries a request, so every caller (our own line, other players'
  -- lines, the self test) behaves the same when the helper is missing, booting or dead.
  -- A request is only ever handed to the running helper: staging a job for it is two file writes,
  -- while curl.exe is a process spawn on the game thread (and a fresh TLS handshake, measured at
  -- 285 ms cold).  So a request that finds the helper booting waits for it instead of paying that;
  -- curl is left for the case where there is no helper at all: no node, or its restarts used up.
  local function start_request(body)
   if helper_state == 'ready' then
    local ok, why = start_helper_job(body)
    if ok then return 'helper' end
    self.line('HELPER stage failed reason=' .. tostring(why) .. ', using curl')
   elseif helper_state == 'starting' then
    return nil, 'helper_booting'
   elseif helper_state == 'idle' and (transport == 'auto' or transport == 'helper') then
    start_helper()
    return nil, 'helper_booting'
   end
   local ok, why = start_curl(body)
   if not ok then return nil, why end
   return 'curl'
  end

  -- ---- transport: the hd2-chat-translate worker dll (opt-in) ---------------------------
  local function load_worker()
   if worker_state == 'ready' then return worker end
   if worker_state == 'failed' then return nil end
   local root_dir = env_string('LOCALAPPDATA')
   if not root_dir then
    worker_state = 'failed'
    return nil
   end
   local pattern = root_dir .. '\\HD2ChatTranslate\\native\\*.dll'
   local find_data = ffi.new('BcFindData[1]')
   local handle = k.FindFirstFileW(wide_path(pattern), find_data)
   local found = {}
   if handle ~= nil and handle ~= INVALID_HANDLE then
    for i = 0, 259 do
     local code = tonumber(find_data[0].name[i])
     if code == 0 or code == nil then break end
     found[#found + 1] = string.char(code % 256)
    end
    k.FindClose(handle)
   end
   if #found == 0 then
    worker_state = 'failed'
    self.line('WORKER dll not found')
    return nil
   end
   local library = k.LoadLibraryW(wide_path(root_dir .. '\\HD2ChatTranslate\\native\\'
    .. table.concat(found)))
   if library == nil or library == ffi.NULL then
    worker_state = 'failed'
    self.line('WORKER LoadLibrary failed')
    return nil
   end
   local function resolve(name, signature)
    local address = k.GetProcAddress(library, name)
    if address == nil or address == ffi.NULL then return nil end
    return ffi.cast(signature, address)
   end
   local api = {
    version = resolve('HD2CT_ABIVersion', 'uint32_t (*)(void)'),
    initialize = resolve('HD2CT_InitializeEnvironment', 'uint32_t (*)(void)'),
    enabled = resolve('HD2CT_IsEnabled', 'uint32_t (*)(void)'),
    submit = resolve('HD2CT_Submit', 'uint32_t (*)(const char *, const char *, uint32_t)'),
    poll = resolve('HD2CT_Poll', 'uint32_t (*)(const char *, char *, uint32_t, uint32_t *)'),
   }
   if not (api.version and api.initialize and api.enabled and api.submit and api.poll)
     or tonumber(api.version()) ~= 1 then
    worker_state = 'failed'
    self.line('WORKER exports missing')
    return nil
   end
   local enabled = tonumber(api.enabled()) or 0
   if enabled ~= 1 then
    enabled = tonumber(api.initialize()) or 0
    enabled = tonumber(api.enabled()) or 0
   end
   self.line('WORKER loaded enabled=' .. tostring(enabled))
   if enabled ~= 1 then
    worker_state = 'failed'
    return nil
   end
   worker, worker_state = api, 'ready'
   return worker
  end

  -- Filled in by the inbound layer further down.  A request that fails or times out has to take
  -- its placeholder back off the row, or "translating" would sit there for the rest of the match.
  local revert_inbound = function() end
  local function fail_inbound(item, why)
   if not item then return end
   in_stats.failed = in_stats.failed + 1
   revert_inbound(item.index, item.body, why)
  end

  -- ---- translation lifecycle -----------------------------------------------------------
  local function start_translation(source, index)
   self_index = index
   local inj = hook()
   if inj and type(inj.translate) == 'function' then
    local ok, result = pcall(inj.translate, source)
    if ok and type(result) == 'string' and result ~= '' then
     tr_ready = {text = result, source = source}
     self.line('TRANSLATE injected="' .. text(result, 120) .. '"')
    else
     counters.failed = counters.failed + 1
    end
    return
   end
   local target = is_cjk(source) and 'English' or 'Simplified Chinese'
   local tag = is_cjk(source) and 'EN' or 'CN'
   local body = request_body(source, target)
   if #body > BODY_LIMIT then
    counters.failed = counters.failed + 1
    self.line(string.format('SKIP translate reason=body_too_long len=%d', #body))
    return
   end
   if transport == 'dll' then
    local api = load_worker()
    if not api then
     counters.failed = counters.failed + 1
     self.line('SKIP translate reason=worker_unavailable')
     return
    end
    local token = string.format('bc%d_%d', tonumber(k.GetCurrentProcessId()) or 0, seq + 1)
    seq = seq + 1
    local ok, accepted = pcall(api.submit, token, body, #body)
    if not ok or tonumber(accepted) ~= 1 then
     counters.failed = counters.failed + 1
     self.line('SUBMIT rejected')
     return
    end
    inflight = {api = api, token = token, source = source, tag = tag, at = now()}
    self.line(string.format('SUBMIT ok token=%s tag=%s src="%s"', token, tag, text(source, 60)))
    return
   end
   local lane, why = start_request(body)
   if not lane then
    if why == 'helper_booting' then
     pending_self = {source = source, tag = tag, index = index, at = now()}
     self.line('TRANSLATE deferred reason=helper_booting')
     return
    end
    counters.failed = counters.failed + 1
    self.line('SKIP translate reason=' .. tostring(why))
    return
   end
   inflight = {source = source, tag = tag, at = now(), lane = lane}
   self.line(string.format('%s started tag=%s src="%s"',
    lane == 'helper' and 'HELPER job' or 'CURL', tag, text(source, 60)))
  end

  -- our own line's translation can be on hold while the helper boots (and only then)
  local function deferred_translate()
   local p = pending_self
   if not p then return end
   if now() - p.at > TRANSLATE_TIMEOUT then
    pending_self = nil
    counters.failed = counters.failed + 1
    self.line('TRANSLATE deferred gave up (the helper never became ready)')
    return
   end
   if inflight or now() - p.at < 0.2 or helper_state ~= 'ready' then return end
   pending_self = nil
   self.line('TRANSLATE retrying, the helper is ready now')
   start_translation(p.source, p.index)
  end

  local function finish_translation(response, tag, source, purpose, item)
   local content = extract_content(response)
   if not content then
    counters.failed = counters.failed + 1
    self.line(string.format('TRANSLATE failed raw="%s"', text(response, 140)))
    if purpose == 'in' then fail_inbound(item, 'translate_failed') end
    return
   end
   content = content:gsub('%s+', ' ')
   if content == '' then
    counters.failed = counters.failed + 1
    self.line('TRANSLATE empty')
    if purpose == 'in' then fail_inbound(item, 'translate_empty') end
    return
   end
   if purpose == 'in' then
    in_stats.done = in_stats.done + 1
    in_ready[item.index] = {body = item.body, text = content, name = item.name}
    self.line(string.format('INBOUND translated idx=%d len=%d text="%s"', item.index, #content,
     text(content, 80)))
    return
   end
   if #content > BOX_CAPACITY then content = content:sub(1, BOX_CAPACITY) end
   local final = content
   if prefix == 'auto' then
    final = '[' .. tag .. '] ' .. content
   elseif prefix ~= '' and prefix ~= '0' then
    final = prefix .. ' ' .. content
   end
   -- self test: put the translation under our own line, so the write path can be exercised
   -- without waiting for a teammate to say something
   if in_self and in_mode ~= 'off' and self_index then
    in_ready[self_index] = {body = source, text = content, name = self_name or '?'}
    self.line(string.format('INBOUND self-test idx=%d translation="%s"', self_index,
     text(content, 60)))
   end
   tr_ready = {text = final, source = source}
   self.line(string.format('TRANSLATE ok tag=%s len=%d text="%s"', tag, #final, text(final, 120)))
  end

  local function poll_translation()
   if not inflight then return end
   if inflight.lane == 'helper' then
    -- out.txt costs a file open/read/close pair; the answer takes hundreds of ms, so 12 Hz is plenty
    if now() - helper_poll_at < 0.08 then return end
    helper_poll_at = now()
    local response, fields = poll_helper()
    if response == nil then
     if now() - inflight.at > TRANSLATE_TIMEOUT then
      counters.failed = counters.failed + 1
      self.line('HELPER timeout (no answer)')
      local dead = inflight
      inflight, helper_job_id = nil, nil
      if dead.purpose == 'in' then fail_inbound(dead.item, 'timeout') end
     end
     return
    end
    local source, tag = inflight.source, inflight.tag
    local purpose, item = inflight.purpose, inflight.item
    inflight = nil
    self.line(string.format('HELPER answered ms=%s reused=%s status=%s',
     fields and tostring(fields.ms) or '?', fields and tostring(fields.reused) or '?',
     fields and tostring(fields.status) or '?'))
    finish_translation(response, tag, source, purpose, item)
    return
   end
   if inflight.api then
    local ok, done = pcall(inflight.api.poll, inflight.token, read_buf, 65536, written_out)
    if not ok then
     counters.failed = counters.failed + 1
     self.line('POLL exception')
     inflight = nil
     return
    end
    if tonumber(done) ~= 1 then
     if now() - inflight.at > TRANSLATE_TIMEOUT then
      counters.failed = counters.failed + 1
      self.line('POLL timeout')
      inflight = nil
     end
     return
    end
    local length = tonumber(written_out[0]) or 0
    local response = length > 0 and ffi.string(read_buf, length) or ''
    local source, tag = inflight.source, inflight.tag
    local purpose, item = inflight.purpose, inflight.item
    inflight = nil
    finish_translation(response, tag, source, purpose, item)
    return
   end
   local response = poll_curl()
   if response == nil then
    if now() - inflight.at > TRANSLATE_TIMEOUT then
     counters.failed = counters.failed + 1
     self.line('CURL timeout (no process)')
     local dead = inflight
     inflight = nil
     if dead.purpose == 'in' then fail_inbound(dead.item, 'timeout') end
    end
    return
   end
   local source, tag = inflight.source, inflight.tag
   local purpose, item = inflight.purpose, inflight.item
   inflight = nil
   finish_translation(response, tag, source, purpose, item)
  end

  -- inbound layout constants.  They live inside the factory on purpose: the module-level scope
  -- is already close to LuaJIT's 60-upvalue ceiling and every extra module local counts twice.
  local WIDGET_BASE_OFFSET = 0x4390
  local WIDGET_STRIDE = 0x3D8
  local PROP_TABLE_OFFSET = 0x220
  local PROP_COUNT_OFFSET = 0x158
  local PROP_ENTRY_SIZE = 0x18
  local PROP_MAX = 14
  local BODY_KEY = 0x7518C954
  local SETTER_RVA = 0x1441CA0
  local STRING_SETTER_RVA = 0x143A1B0
  local LAYOUT_HELPER_RVA = 0x18610C0
  local LAYOUT_DIRECT_RVA = 0x1860DA0
  local INBOUND_QUEUE = 4
  local INBOUND_TTL = 60
  -- spacing between two requests.  Steam passes its own (possibly stale) environment block to the
  -- game, so every switch also has a working default: unset means on, "0" means off.
  local INBOUND_GAP = 0.25
  local INBOUND_LIMIT = 2048
  local WIDE_SCAN = 0x10000
  -- fingerprint of the game's own row -> body wiring.  Verified byte for byte against the dumped
  -- image with tools/verify_offsets.py before every build: the sequence starts at 0x1860C49
  -- (lea r8,[rbx+0xB4] / mov edx,0x7518C954 / mov rcx,rsi / call).
  local GUARD_RVA = 0x1860C49
  local GUARD_BYTES = string.char(0x4c, 0x8d, 0x83, 0xb4, 0x00, 0x00, 0x00, 0xba, 0x54, 0xc9,
   0x18, 0x75, 0x48, 0x8b, 0xce, 0xe8)
  -- ---- inbound: put a translation under other players' lines (this client only) ------------
  -- The ring record and the UI row are not assumed to share an index: a row is found by matching
  -- the string pointer of its body property against the ring buffer address, and nothing is
  -- written before that match is confirmed.
  local function hex_of(s)
   if not s then return '?' end
   return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end))
  end

  local function read_float(at)
   local b = read(at, 4)
   if not b then return nil end
   local f = ffi.new('float[1]')
   ffi.copy(f, b, 4)
   return tonumber(f[0])
  end

  local function float_bytes(value)
   local f = ffi.new('float[1]')
   f[0] = value
   return ffi.string(f, 4)
  end

  local function ring_body_at(index)
   return ring + (index % 64) * RING_STRIDE + BODY_OFFSET
  end

  local function slot_at(slot)
   return manager + WIDGET_BASE_OFFSET + slot * WIDGET_STRIDE
  end

  -- Find every place inside a window where a dword equals the body property key and read the value
  -- that sits 8 bytes after it.  This is the whole row-lookup rule, and it does not depend on
  -- knowing the table base or the entry count: the game's own code
  --   cmp [rcx+r8*8+8], edx          ; r8 = 3*i, so the key is the entry's first dword
  --   movups [rbx+rcx*8+8], xmm0     ; on insert it writes {key, 1, pointer}
  -- only promises that the key and the value live 8 bytes apart inside the same window.
  local function scan_key_hits(at, span)
   local blob = read(at, span)
   if not blob then return nil end
   local hits = {}
   for off = 0, span - 0x10, 4 do
    if u32(blob, off) == BODY_KEY then
     hits[#hits + 1] = {off = off, value = u64(blob, off + 8) or 0}
    end
   end
   return hits, blob
  end

  local function map_from_value(value)
   local delta = value - (ring + BODY_OFFSET)
   if delta >= 0 and delta < 64 * RING_STRIDE and delta % RING_STRIDE == 0 then
    return (delta / RING_STRIDE) % 64
   end
   return nil
  end

  -- which row shows ring index <index>, plus the whole slot -> index map the pointers imply
  -- alt is the buffer this row already shows (after a placeholder the property points at us, not
  -- at the ring any more), so a rewrite can still find its own row
  local function find_slot_for(index, alt)
   local want = ring_body_at(index)
   -- the slot that held this row last time is almost always still the one: validating it is a single
   -- ReadProcessMemory instead of 64, and the value check keeps a recycled row honest
   local cached = alt ~= nil and in_row[index] or nil
   if cached then
    local at = slot_at(cached)
    local hits = scan_key_hits(at, WIDGET_STRIDE)
    if hits then
     for i = 1, #hits do
      local h = hits[i]
      if h.value == want or h.value == alt then
       return {slot = cached, off = h.off, value = h.value, at = at + h.off}, nil
      end
     end
    end
    in_row[index] = nil
   end
   local map, match = {}, nil
   for slot = 0, 63 do
    local hits = scan_key_hits(slot_at(slot), WIDGET_STRIDE)
    if hits then
     for i = 1, #hits do
      local h = hits[i]
      if h.value == want or (alt ~= nil and h.value == alt) then
       match = {slot = slot, off = h.off, value = h.value, at = slot_at(slot) + h.off}
      else
       local other = map_from_value(h.value)
       if other then map[slot] = other end
      end
     end
    end
   end
   if match then in_row[index] = match.slot end
   return match, map
  end

  -- the addresses the write path depends on; logged once so a moved offset is visible in the log
  local function guard_ok()
   local bytes = read(base + GUARD_RVA, #GUARD_BYTES)
   return bytes == GUARD_BYTES
  end

  local function probe_signatures()
   if in_sig then return end
   local list = {
    {name = 'setter', rva = SETTER_RVA}, {name = 'string_setter', rva = STRING_SETTER_RVA},
    {name = 'layout_helper', rva = LAYOUT_HELPER_RVA},
    {name = 'layout_direct', rva = LAYOUT_DIRECT_RVA}}
   in_sig = {}
   for i = 1, #list do
    local bytes = read(base + list[i].rva, 16)
    in_sig[list[i].name] = bytes or ''
    self.line(string.format('INBOUND sig %s rva=0x%x %s', list[i].name, list[i].rva,
     bytes and hex_of(bytes) or 'unreadable'))
   end
   in_sig.guard = guard_ok()
   self.line(string.format('INBOUND guard rva=0x%x match=%s arg=%#x', GUARD_RVA,
    tostring(in_sig.guard), in_arg))
  end

  local function probe_index(index)
   if in_probed[index] then return end
   in_probed[index] = true
   probe_signatures()
   local want = ring_body_at(index)
   local match, map = find_slot_for(index)
   local rows = {}
   for slot = 0, 63 do
    if map[slot] then rows[#rows + 1] = string.format('%d>%d', slot, map[slot]) end
   end
   self.line(string.format('INBOUND probe idx=%d body=0x%x slot=%s off=+0x%x map=%s', index, want,
    match and tostring(match.slot) or 'none', match and match.off or 0,
    #rows > 0 and table.concat(rows, ' ') or 'none'))
   if match then
    local at = slot_at(match.slot)
    self.line(string.format('INBOUND geom slot=%d h=%s s=%s p=%s', match.slot,
     hex_of(read(at + 0x10, 4)), hex_of(read(at + 0x20, 4)), hex_of(read(at + 0x3CC, 8))))
    return
   end
   -- nothing matched: say why.  List every key hit we saw and, if there were none at all, widen
   -- the window so a wrong slot base (not a missing row) shows up as data.
   local total, shown = 0, 0
   for slot = 0, 63 do
    local hits = scan_key_hits(slot_at(slot), WIDGET_STRIDE)
    if hits then
     for i = 1, #hits do
      total = total + 1
      if shown < 12 then
       shown = shown + 1
       self.line(string.format('INBOUND hit slot=%d off=+0x%x value=0x%x want=0x%x', slot,
        hits[i].off, hits[i].value, want))
      end
     end
    end
   end
   self.line(string.format('INBOUND slots key_hits=%d want=0x%x stride=0x%x', total, want,
    WIDGET_STRIDE))
   if total == 0 then
    local wide = scan_key_hits(manager + WIDGET_BASE_OFFSET, WIDE_SCAN)
    local found, list = 0, {}
    if wide then
     for i = 1, #wide do
      found = found + 1
      if #list < 12 then
       list[#list + 1] = string.format('+0x%x=0x%x', WIDGET_BASE_OFFSET + wide[i].off,
        wide[i].value)
      end
     end
    end
    self.line(string.format('INBOUND wide key_hits=%d %s', found, table.concat(list, ' ')))
   end
  end

  -- one buffer per ring index, kept for the session: the game's string setter borrows the pointer
  local function inbound_buffer(index, blob)
   local buf = in_slots[index]
   if not buf then
    buf = ffi.new('uint8_t[?]', INBOUND_LIMIT)
    in_slots[index] = buf
   end
   if #blob + 1 > INBOUND_LIMIT then return nil end
   ffi.copy(buf, blob .. '\0', #blob + 1)
   return buf
  end

  -- kind is 'final' | 'placeholder' | 'revert'.  The row is laid out from its own height, so the
  -- height is always derived from the height the row had before we touched it: taking it from the
  -- current height would double it on every rewrite (placeholder first, answer second).
  local function write_inbound(index, blob, kind)
   local buf = inbound_buffer(index, blob)
   if not buf then return false, 'too_long' end
   local want = tonumber(ffi.cast('uintptr_t', buf))
   -- after a placeholder the row's body points at our buffer instead of the ring, so both match
   local match = find_slot_for(index, want)
   if not match then return false, 'no_slot' end
   if in_mode ~= 'on' then
    self.line(string.format('INBOUND ready idx=%d kind=%s slot=%d off=+0x%x len=%d text="%s"',
     index, kind, match.slot, match.off, #blob, text(blob, 80)))
    return true, 'probe'
   end
   probe_signatures()
   if not in_sig.guard then return false, 'guard_mismatch' end
   local fn = ffi.cast('void (*)(void *, void *, void *)',
    ffi.cast('uintptr_t', base + SETTER_RVA))
   local at = slot_at(match.slot)
   local ok, err = pcall(function()
    fn(ffi.cast('void *', at + in_arg), ffi.cast('void *', BODY_KEY), ffi.cast('void *', buf))
   end)
   local now_value = 0
   local hits = scan_key_hits(at, WIDGET_STRIDE)
   if hits then
    for i = 1, #hits do
     if hits[i].off == match.off then now_value = hits[i].value end
    end
   end
   self.line(string.format(
    'INBOUND %s idx=%d kind=%s slot=%d off=+0x%x value=%#x>%#x want=%#x len=%d err=%s',
    ok and 'set' or 'set_fault', index, kind, match.slot, match.off, match.value, now_value, want,
    #blob, tostring(err)))
   if not ok or now_value ~= want then
    return false, ok and 'unconfirmed' or 'fault'
   end
   perf_note('set:' .. kind)
   if kind == 'placeholder' then
    in_stats.placed = in_stats.placed + 1
   elseif kind == 'revert' then
    in_stats.reverted = in_stats.reverted + 1
   else
    in_stats.applied = in_stats.applied + 1
   end
   if in_height then
    local lines = 1
    for _ in blob:gmatch('\n') do lines = lines + 1 end
    local base_h = in_base_h[index]
    if not base_h then
     base_h = read_float(at + 0x10)
     if base_h and base_h > 0 and base_h < 4096 then in_base_h[index] = base_h end
    end
    if base_h and base_h > 0 and base_h < 4096 then
     local have, want_h = read_float(at + 0x10), base_h * lines
     if have and math.abs(have - want_h) > 0.01 then
      if write(at + 0x10, float_bytes(want_h)) then
       self.line(string.format('INBOUND height slot=%d %.1f -> %.1f (lines=%d kind=%s)',
        match.slot, have, want_h, lines, kind))
      else
       self.line(string.format('INBOUND height write failed slot=%d', match.slot))
      end
     end
    end
   end
   return true, 'applied'
  end

  -- The placeholder is what makes the feature feel instant: the row says "translating" in the
  -- frame the message is noticed, instead of sitting untouched for half a second and then jumping.
  -- The buffer belongs to the row, so the answer is written into that same memory.
  local function place_inbound(index, item)
   if in_mode ~= 'on' or not in_place then return false end
   if in_temp[index] then return true end
   -- pcall returns (true, first, second): the status string is the THIRD value.  Reading it as the
   -- second made every successful write look like a failure, so the placeholder was rewritten five
   -- times a second until the answer arrived (visible in the log as repeated kind=placeholder lines).
   local ok, _res, why = pcall(write_inbound, index, item.body .. in_label .. '…', 'placeholder')
   in_pending[index] = nil
   if ok and why == 'applied' then
    in_temp[index] = item
    return true
   end
   in_pending[index] = item
   return false
  end

  revert_inbound = function(index, body, why)
   local shown = in_temp[index] ~= nil
   in_temp[index], in_pending[index] = nil, nil
   if not shown then return end
   local ok, _res, res = pcall(write_inbound, index, body, 'revert')
   self.line(string.format('INBOUND revert idx=%d reason=%s res=%s', index, tostring(why),
    tostring(res)))
  end

  local function consider_inbound(name, body_t, index)
   if in_mode == 'off' then return end
   if self_name == nil then
    if not in_idle_logged then
     in_idle_logged = true
     self.line('INBOUND idle: own name not learned yet (send one line first)')
    end
    return
   end
   if name == self_name or #body_t < 2 then return end
   if is_cjk(body_t) then return end
   if body_t:sub(1, 4) == '[EN]' or body_t:sub(1, 4) == '[CN]' then return end
   if in_seen[body_t] or sent_bodies[body_t] then return end
   if #in_queue >= INBOUND_QUEUE or (in_max > 0 and in_stats.seen >= in_max) then return end
   in_seen[body_t] = true
   in_stats.seen = in_stats.seen + 1
   local item = {name = name, body = body_t, index = index, at = now()}
   in_queue[#in_queue + 1] = item
   self.line(string.format('INBOUND queued idx=%d from="%s" len=%d', index, text(name, 24),
    #body_t))
   place_inbound(index, item)
  end

  local function start_inbound(item)
   -- test hook: the offline harness injects a translator, so the inbound path can be driven
   -- without curl.exe and without touching the provider
   local inj = hook()
   if inj and type(inj.translate) == 'function' then
    local ok, result = pcall(inj.translate, item.body, 'zh')
    if ok and type(result) == 'string' and result ~= '' then
     in_stats.done = in_stats.done + 1
     in_ready[item.index] = {body = item.body, text = result, name = item.name}
     self.line(string.format('INBOUND translated idx=%d (injected) len=%d', item.index, #result))
     return
    end
    in_stats.failed = in_stats.failed + 1
    self.line('INBOUND injected translate failed')
    revert_inbound(item.index, item.body, 'injected_failed')
    return
   end
   local body = request_body(item.body, 'Simplified Chinese')
   if #body > BODY_LIMIT then
    in_stats.failed = in_stats.failed + 1
    self.line('INBOUND skip idx=' .. item.index .. ' reason=body_too_long')
    revert_inbound(item.index, item.body, 'body_too_long')
    return
   end
   local lane, why = start_request(body)
   if not lane then
    if why == 'helper_booting' then
     -- hold the line rather than spawn curl on the game thread; the placeholder stays on the row
     table.insert(in_queue, 1, item)
     in_last = now()
     if not item.deferred then
      item.deferred = true
      self.line(string.format('INBOUND deferred idx=%d reason=helper_booting', item.index))
     end
     return
    end
    in_stats.failed = in_stats.failed + 1
    self.line('INBOUND request failed reason=' .. tostring(why))
    revert_inbound(item.index, item.body, tostring(why))
    return
   end
   in_last = now()
   inflight = {purpose = 'in', item = item, source = item.body, tag = 'ZH', at = now(),
    lane = lane}
   self.line(string.format('INBOUND request idx=%d lane=%s from="%s"', item.index, lane,
    text(item.name, 24)))
  end

  local function inbound_step()
   if in_mode == 'off' then return end
   for i = #in_queue, 1, -1 do
    if now() - in_queue[i].at > INBOUND_TTL then
     local dead = table.remove(in_queue, i)
     revert_inbound(dead.index, dead.body, 'expired')
    end
   end
   -- retry a placeholder the row was not addressable for yet: the widget of a message that has
   -- just arrived is not necessarily laid out in the same frame
   if now() - in_place_at > 0.2 then
    in_place_at = now()
    for index, item in pairs(in_pending) do
     if place_inbound(index, item) then break end
    end
   end
   if not inflight and #in_queue > 0 and now() - in_last > INBOUND_GAP then
    start_inbound(table.remove(in_queue, 1))
    return
   end
   for index, entry in pairs(in_ready) do
    in_ready[index] = nil
    if in_mode == 'probe' then
     probe_index(index)
     self.line(string.format('INBOUND ready idx=%d len=%d body="%s" text="%s"', index,
      #entry.text, text(entry.body, 40), text(entry.text, 60)))
     return
    end
    in_temp[index], in_pending[index] = nil, nil
    local ok, _res, why = pcall(write_inbound, index, entry.body .. in_label .. entry.text, 'final')
    if not ok then
     in_stats.failed = in_stats.failed + 1
     self.line('INBOUND apply fault: ' .. tostring(why))
    elseif why ~= 'applied' and why ~= 'probe' then
     in_stats.failed = in_stats.failed + 1
     self.line(string.format('INBOUND apply idx=%d reason=%s', index, tostring(why)))
    end
    return
   end
  end


  -- ---- sending -------------------------------------------------------------------------
  local function learn_window()
   local inj = hook()
   if inj and inj.wndproc then
    hwnd, wndproc = ffi.cast('void *', inj.hwnd or 0x10001), tonumber(inj.wndproc) or 0
    return true
   end
   local fg = user32.GetForegroundWindow()
   if fg ~= nil and fg ~= ffi.NULL then
    local pid_out = ffi.new('uint32_t[1]')
    user32.GetWindowThreadProcessId(fg, pid_out)
    if tonumber(pid_out[0]) == tonumber(k.GetCurrentProcessId()) then
     local proc = tonumber(user32.GetWindowLongPtrW(fg, GWLP_WNDPROC)) or 0
     if proc ~= 0 then
      hwnd, wndproc = fg, proc
      self.line(string.format('WINDOW hwnd=0x%x wndproc=0x%x',
       tonumber(ffi.cast('uintptr_t', fg)), proc))
      return true
     end
    end
   end
   return false
  end

  -- five ways to press Enter; the log says which one the game actually accepts
  local METHODS = {'cr', 'sendinput', 'ntsendinput', 'post_char', 'post_key'}

  local function foreground_is_game()
   local fg = user32.GetForegroundWindow()
   if fg == nil or fg == ffi.NULL then return false end
   local pid_out = ffi.new('uint32_t[1]')
   user32.GetWindowThreadProcessId(fg, pid_out)
   return tonumber(pid_out[0]) == tonumber(k.GetCurrentProcessId())
  end

  local function key_lp(scan, up)
   local lp = 1 + scan * 65536
   if up then lp = lp + 0x40000000 + 0x80000000 end
   return lp
  end

  local function inject(method)
   local inj = hook()
   if inj and inj.nokey then return 'skipped' end
   if method == 'sendinput' or method == 'ntsendinput' then
    if not foreground_is_game() then return 'not_foreground' end
    local events = ffi.new('BcInput[2]')
    events[0].type = 1
    events[0].vk = VK_RETURN
    events[0].scan = SCAN_RETURN
    events[1].type = 1
    events[1].vk = VK_RETURN
    events[1].scan = SCAN_RETURN
    events[1].flags = 2
    if method == 'sendinput' then
     local sent = user32.SendInput(2, events, ffi.sizeof(events[0]))
     return string.format('ret=%s size=%d', tostring(tonumber(sent)), ffi.sizeof(events[0]))
    end
    if not ok_win32u then return 'no_win32u' end
    local status = win32u.NtUserSendInput(2, events, ffi.sizeof(events[0]))
    return string.format('status=0x%x size=%d', tonumber(status) or -1, ffi.sizeof(events[0]))
   end
   if method == 'cr' then
    if hwnd == nil or wndproc == 0 then
     if not learn_window() then return 'no_window' end
    elseif user32.IsWindow(hwnd) == 0 then
     hwnd, wndproc = nil, 0
     if not learn_window() then return 'no_window' end
    end
    local fn = ffi.cast('intptr_t (*)(void *, uint32_t, uintptr_t, intptr_t)', wndproc)
    local ok = pcall(function() return fn(hwnd, WM_CHAR, CR, 1) end)
    return 'sent=' .. tostring(ok)
   end
   if not ok_win32u then return 'no_win32u' end
   if method == 'post_key' then
    local a = win32u.NtUserPostMessage(hwnd, WM_KEYDOWN, VK_RETURN, key_lp(SCAN_RETURN, false))
    local b = win32u.NtUserPostMessage(hwnd, WM_KEYUP, VK_RETURN, key_lp(SCAN_RETURN, true))
    return string.format('status=0x%x/0x%x', tonumber(a) or -1, tonumber(b) or -1)
   end
   local a = win32u.NtUserPostMessage(hwnd, WM_CHAR, CR, 1)
   return string.format('status=0x%x', tonumber(a) or -1)
  end

  local function submit_box(step)
   local method = METHODS[math.min(step, #METHODS)]
   local result = inject(method)
   self.line(string.format('SUBMIT method=%s %s', tostring(method), tostring(result)))
   return method
  end

  local function send_step()
   if send_phase == 'idle' then
    if not tr_ready then return end
    if mode == 'dry' then
     self.line('DRY would send: "' .. text(tr_ready.text, 120) .. '"')
     tr_ready = nil
     return
    end
    local box = read_box()
    if box == nil then return end
    if box ~= '' then
     empty_since = 0
     if wait_since == 0 then wait_since = now() end
     if now() - wait_since > EMPTY_BOX_TIMEOUT then
      self.line('SEND aborted: the box stayed busy with "' .. text(box, 40) .. '"')
      tr_ready, wait_since = nil, 0
     end
     return
    end
    wait_since = 0
    if empty_since == 0 then
     empty_since = now()
     return
    end
    if now() - empty_since < EMPTY_STABLE then return end
    empty_since = 0
    send_text = tr_ready.text
    if mode == 'prefill' then
     if #send_text + 1 > INPUT_CAPACITY then
      self.line('PREFILL aborted: translation does not fit in the box')
      tr_ready, send_text = nil, nil
      return
     end
     if not write(input_at, send_text .. '\0') then
      self.line('PREFILL write failed')
      tr_ready, send_text = nil, nil
      return
     end
     if read_box() ~= send_text then
      self.line('PREFILL write reverted immediately')
      tr_ready, send_text = nil, nil
      return
     end
     sent_bodies[send_text] = true
     verify_text = send_text
     verify_at, took_at = now(), 0
     self.line(string.format('PREFILL ready len=%d text="%s" (press Enter to send it)',
      #send_text, text(send_text, 120)))
     tr_ready, send_text = nil, nil
     return
    end
    if #send_text + 1 > INPUT_CAPACITY then
     self.line('SEND aborted: translation does not fit in the box')
     tr_ready, send_text = nil, nil
     return
    end
    if not write(input_at, send_text .. '\0') then
     self.line('SEND write failed')
     tr_ready, send_text = nil, nil
     return
    end
    if read_box() ~= send_text then
     self.line('SEND write reverted immediately')
     tr_ready, send_text = nil, nil
     return
    end
    self.line(string.format('SEND wrote len=%d text="%s"', #send_text, text(send_text, 120)))
    send_blob = sample_region()
    attempt = 1
    send_at = now()
    if mode == 'mem' then
     sent_bodies[send_text] = true
     verify_text = send_text
     verify_at, took_at = now(), 0
     if not write(manager + PANEL_STATE_OFFSET, '\1') then
      self.line('MSEND state write failed; the text is in the box, press Enter')
      send_phase = 'idle'
      tr_ready, send_text = nil, nil
      return
     end
     if not write(manager + SUBMIT_FLAG_OFFSET, '\1') then
      self.line('MSEND flag write failed; the text is in the box, press Enter')
      send_phase = 'idle'
      tr_ready, send_text = nil, nil
      return
     end
     self.line('MSEND armed state=0x139b8 flag=0x1e0f')
     send_phase = 'memory'
     return
    end
    send_phase = 'submitted'
    submit_box(attempt)
    return
   end
   if send_phase == 'submitted' then
    local box = read_box()
    if box ~= send_text then
     send_phase = 'idle'
     counters.sent = counters.sent + 1
     sent_bodies[send_text] = true
     verify_text = send_text
     verify_at, took_at = now(), 0
     self.line(string.format('SEND ok sent=%d method=%s tries=%d region=%s', counters.sent,
      tostring(METHODS[math.min(attempt, #METHODS)]), attempt,
      diff_region(send_blob, sample_region())))
     tr_ready, send_text = nil, nil
     return
    end
    if attempt >= #RETRY_GAPS then
     counters.failed = counters.failed + 1
     self.line(string.format('SEND failed after %d cr region=%s', attempt,
      diff_region(send_blob, sample_region())))
     send_phase = 'idle'
     tr_ready, send_text = nil, nil
     return
    end
    if now() - send_at < RETRY_GAPS[attempt + 1] then return end
    attempt = attempt + 1
    self.line(string.format('SEND retry=%d region=%s', attempt,
     diff_region(send_blob, sample_region())))
    send_at = now()
    submit_box(attempt)
    return
   end
   if send_phase == 'memory' then
    local box = read_box()
    if box ~= send_text then
     send_phase = 'idle'
     counters.sent = counters.sent + 1
     took_at = now()
     self.line(string.format('MSEND ok sent=%d text="%s" region=%s', counters.sent,
      text(send_text, 120), diff_region(send_blob, sample_region())))
     tr_ready, send_text = nil, nil
     return
    end
    if now() - send_at < MSEND_TIMEOUT then return end
    send_phase = 'idle'
    counters.failed = counters.failed + 1
    self.line('MSEND failed: the game did not take it; the text stays in the box (press Enter)')
    tr_ready, send_text = nil, nil
    return
   end
   if false then
    send_phase = 'idle'
    tr_ready, send_text = nil, nil
   end
  end

  local function ring_step()
   local meta = read(ring + RING_META, 8)
   local next_index, active = u32(meta, 0), u32(meta, 4)
   if not next_index then return end
   local key = string.format('%d/%d', next_index, active)
   if key == last_meta then return end
   local previous = last_meta ~= '' and tonumber(last_meta:match('^(%d+)'))
    or (next_index - math.min(active or 0, 2)) % 64
   last_meta = key
   if previous == nil or previous == next_index then return end
   local span = (next_index - previous) % 64
   if span > 6 then span, previous = 6, (next_index - 6) % 64 end
   for i = 1, span do
    local index = (previous + i - 1) % 64
    local rec = ring + index * RING_STRIDE
    local head = read(rec, NAME_OFFSET + 32)
    local body = read(rec + BODY_OFFSET, BODY_CAPACITY)
    if u32(head, 0) == EVENT_CHAT and head then
     local name = text(head:sub(NAME_OFFSET + 1), 40)
     local body_t = text(body, 200)
     if body_t ~= '' then
      if verify_text and body_t == verify_text then
       verify_text = nil
       -- how long the game needed to put the message into the ring: the same frame means the client
       -- added it itself, several frames means it came back from the server
       self.line(string.format(
        'SEND verified: the translation is in the chat ring after %.0f ms (game took it after %.0f ms)',
        (now() - verify_at) * 1000, took_at > 0 and (now() - took_at) * 1000 or -1))
      elseif sent_bodies[body_t] then
       self.line('RING our own translation came back (ignored)')
      elseif typed and body_t == typed and (self_name == nil or name == self_name) then
       self_name = name
       counters.own = counters.own + 1
       typed = nil
       self.line(string.format('OWN message name="%s" body="%s"', name, body_t))
       if mode ~= 'off' then start_translation(body_t, index) end
       -- our own line is a row in the same chat window: probing it is how the row layout gets
       -- reported even when nobody else writes anything
       if in_mode == 'probe' then probe_index(index) end
      else
       consider_inbound(name, body_t, index)
      end
     end
    end
   end
  end

  local function box_step()
   local box = read_box()
   if box == nil or box == last_box then return end
   last_box = box
   if box == '' then return end
   if send_text and box == send_text then return end
   typed = box
  end

  -- ---- live workbench: command file, memory monitor, image dump, pokes ------------------
  -- A file (%LOCALAPPDATA%\HD2BilingualChat\cmd.txt) is polled four times a second; every line
  -- written there is executed inside the running game and its answer lands in the log. That is how
  -- the chat code is interrogated without rebuilding the mod or restarting the game.
  local REGION_SPAN = 0x3400
  local cmd_last, cmd_at = nil, 0
  local cr_pending, cr_at, cr_label = false, 0, ''
  local report_at, report_label = 0, ''
  local scan_until, scan_sample_at, monitor_last = 0, 0, nil
  local flips, flip_value = {}, {}
  local dump = nil
  local dumped = false

  local function u16(s, o)
   if not s or #s < o + 2 then return nil end
   return s:byte(o+1) + s:byte(o+2) * 256
  end
  local function hexnum(s)
   if type(s) ~= 'string' then return nil end
   return tonumber((s:gsub('^0[xX]', '')), 16)
  end
  local function bytes_hex(s)
   if not s then return '?' end
   return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end))
  end
  local function ascii_of(s)
   return (s:gsub('.', function(c)
    local byte = c:byte()
    return (byte >= 32 and byte < 127) and c or '.'
   end))
  end
  local function dump_range(label, at, off, length)
   local left = length
   while left > 0 do
    local step = math.min(left, 0x100)
    local bytes = read(at + off, step)
    if not bytes then
     self.line(string.format('HEX %s +0x%x unreadable', label, off))
     return
    end
    self.line(string.format('HEX %s +0x%x %s |%s|', label, off, bytes_hex(bytes), ascii_of(bytes)))
    off, left = off + step, left - step
   end
  end

  local function rank(n)
   local list = {}
   for off, count in pairs(flips) do
    list[#list + 1] = {off = off, count = count, value = flip_value[off] or ''}
   end
   table.sort(list, function(a, b)
    if a.count == b.count then return a.off < b.off end
    return a.count > b.count
   end)
   local out = {}
   for i = 1, math.min(n, #list) do
    out[#out + 1] = string.format('%s x%d %s', list[i].off, list[i].count, list[i].value)
   end
   if #out == 0 then return '(nothing changed while scanning)' end
   return table.concat(out, ' | ')
  end

  local FILE_APPEND_DATA = 0x0004
  local OPEN_ALWAYS = 4
  local function file_open_append(path)
   local handle = k.CreateFileW(wide_path(path), FILE_APPEND_DATA, 1, nil, OPEN_ALWAYS,
    FILE_ATTRIBUTE_NORMAL, nil)
   if handle == nil or handle == INVALID_HANDLE then return nil end
   return handle
  end
  local function file_append(handle, data)
   local blob = ffi.new('uint8_t[?]', #data)
   ffi.copy(blob, data, #data)
   written_out[0] = 0
   local ok = k.WriteFile(handle, blob, #data, written_out, nil) ~= 0
   return ok and tonumber(written_out[0]) == #data
  end

  -- the on-disk game.dll is packed, so the chat code only exists unpacked in memory: copy the
  -- loaded image out section by section (one file per module plus a manifest of the section table)
  local function start_dump()
   local jobs = {}
   local function add(image, label)
    if image == nil or image == ffi.NULL then return end
    local at = tonumber(ffi.cast('uintptr_t', image))
    local head = read(at, 0x1000)
    if not head or head:sub(1, 2) ~= 'MZ' then return end
    local nt_at = u32(head, 0x3C)
    local nt = read(at + nt_at, 0x400)
    if not nt or nt:sub(1, 4) ~= 'PE\0\0' then return end
    local count, opt_size, image_size = u16(nt, 6), u16(nt, 20), u32(nt, 80)
    if not (count and opt_size and image_size) or count > 96 or opt_size > 0x400 then return end
    local sections = {}
    for i = 0, count - 1 do
     local o = 24 + opt_size + i * 40
     sections[#sections + 1] = {
      name = text(nt:sub(o + 1, o + 8), 8), va = u32(nt, o + 12), vsize = u32(nt, o + 8),
      raw = u32(nt, o + 16), chars = u32(nt, o + 36)}
    end
    jobs[#jobs + 1] = {label = label, at = at, image_size = image_size, sections = sections,
     done = 0}
   end
   add(k.GetModuleHandleA('game.dll'), 'game.dll')
   add(k.GetModuleHandleA(nil), 'main')
   if #jobs == 0 then
    self.line('DUMPIMG nothing to dump')
    return
   end
   dump = {jobs = jobs, index = 1}
   self.line(string.format('DUMPIMG start jobs=%d modules=%s', #jobs, jobs[1].label))
  end

  local function dump_step()
   if not dump then return end
   local job = dump.jobs[dump.index]
   if not job then dump = nil return end
   local where = work_dir()
   if not where then dump = nil return end
   if not job.handle then
    job.path = string.format('%s\\img_%s.bin', where, job.label)
    local lines = {string.format('# %s at=0x%x image_size=0x%x', job.label, job.at, job.image_size)}
    for i, s in ipairs(job.sections) do
     lines[#lines + 1] = string.format('section %d name=%s va=0x%x vsize=0x%x raw=0x%x chars=0x%x',
      i, s.name, s.va, s.vsize, s.raw, s.chars)
    end
    file_write(string.format('%s\\img_%s.txt', where, job.label), table.concat(lines, '\n'))
    k.DeleteFileW(wide_path(job.path))
    job.handle = file_open_append(job.path)
    if not job.handle then
     self.line('DUMPIMG cannot open ' .. job.path)
     dump = nil
     return
    end
    self.line(string.format('DUMPIMG module=%s at=0x%x image=0x%x sections=%d path=%s',
     job.label, job.at, job.image_size, #job.sections, job.path))
   end
   local budget, zero = 0x20000, string.rep('\0', 0x10000)
   while budget > 0 and job.done < job.image_size do
    local step = math.min(0x10000, budget, job.image_size - job.done)
    local bytes = read(job.at + job.done, step)
    if not bytes then
     bytes = zero:sub(1, step)
     job.gaps = (job.gaps or 0) + 1
    end
    if not file_append(job.handle, bytes) then
     self.line('DUMPIMG write failed (disk?)')
     k.CloseHandle(job.handle)
     dump = nil
     return
    end
    job.done, budget = job.done + step, budget - step
   end
   if job.done >= job.image_size then
    k.CloseHandle(job.handle)
    self.line(string.format('DUMPIMG done module=%s bytes=%d gaps=%d', job.label, job.done,
     job.gaps or 0))
    dump.index = dump.index + 1
    if dump.index > #dump.jobs then
     dump = nil
     self.line('DUMPIMG all done')
    end
   end
  end

  local function status_line()
   local meta = read(ring + RING_META, 8)
   return string.format('STATUS box="%s" ring=%s mode=%s fg=%s dump=%s',
    text(read_box() or '?', 60), meta and bytes_hex(meta) or '?', mode,
    tostring(foreground_is_game()), dump and 'running' or 'idle')
  end

  local function run_command(line)
   local parts = {}
   for word in line:gmatch('%S+') do parts[#parts + 1] = word end
   local verb = (parts[1] or ''):lower()
   if verb == 'status' then return status_line() end
   if verb == 'hex' then
    local off, length = hexnum(parts[2]) or 0, hexnum(parts[3]) or 0x40
    dump_range('manager', manager, off, math.min(length, 0x400))
    return ''
   end
   if verb == 'box' then
    local body = line:match('^box%s+(.*)$') or ''
    if #body + 1 > INPUT_CAPACITY then return 'BOX too long' end
    if not write(input_at, body .. '\0') then return 'BOX write failed' end
    return string.format('BOX wrote len=%d back="%s"', #body, text(read_box() or '', 80))
   end
   if verb == 'cr' then
    local box = read_box()
    if box and box ~= '' then
     sent_bodies[box] = true
     verify_text = box
    end
    return 'CR ' .. tostring(inject('cr'))
   end
   if verb == 'crkey' then return 'CRKEY ' .. tostring(inject('post_key')) end
   if verb == 'set' then
    local off, value = hexnum(parts[2]), hexnum(parts[3])
    if not off or not value then return 'SET needs <offset> <byte>' end
    local before = read(manager + off, 1)
    if not write(manager + off, string.char(value % 256)) then return 'SET write failed' end
    return string.format('SET +0x%x %s->%02x', off, before and bytes_hex(before) or '??', value % 256)
   end
   if verb == 'set32' then
    local off, value = hexnum(parts[2]), hexnum(parts[3])
    if not off or not value then return 'SET32 needs <offset> <dword>' end
    local before = read(manager + off, 4) or ''
    local bytes = string.char(value % 256, math.floor(value / 256) % 256,
     math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
    if not write(manager + off, bytes) then return 'SET32 write failed' end
    return string.format('SET32 +0x%x %s->%s', off, bytes_hex(before), bytes_hex(bytes))
   end
   if verb == 'submit' then
    local body = line:match('^submit%s+(.*)$') or ''
    if #body + 1 > INPUT_CAPACITY then return 'SUBMIT too long' end
    if not write(input_at, body .. '\0') then return 'SUBMIT write failed' end
    if body ~= '' then
     sent_bodies[body] = true
     verify_text = body
    end
    cr_pending, cr_at, cr_label = true, now() + 0.4, body
    return string.format('SUBMIT queued len=%d text="%s"', #body, text(body, 60))
   end
   if verb == 'scan' then
    scan_until = now() + (tonumber(parts[2]) or 20)
    monitor_last, flips, flip_value = nil, {}, {}
    return string.format('SCAN until t=%.1f', scan_until)
   end
   if verb == 'rank' then return 'RANK ' .. rank(tonumber(parts[2]) or 15) end
   if verb == 'save' then
    local off, length, name = hexnum(parts[2]), hexnum(parts[3]), parts[4]
    local where = work_dir()
    if not (off and length and name and where) then return 'SAVE needs <offset> <len> <name>' end
    local bytes = read(manager + off, length)
    if not bytes then return 'SAVE unreadable' end
    local path = string.format('%s\\snap_%s.bin', where, name)
    file_write(path, bytes)
    return string.format('SAVE +0x%x len=%d -> %s', off, length, path)
   end
   if verb == 'call' then
    local off = hexnum(parts[2])
    if not off then return 'CALL needs <rva> [arg]' end
    local arg = hexnum(parts[3]) or manager
    local fn = ffi.cast('void (*)(void *)', ffi.cast('uintptr_t', base + off))
    local ok, err = pcall(function() fn(ffi.cast('void *', arg)) end)
    return string.format('CALL rva=0x%x arg=0x%x ok=%s err=%s', off, arg, tostring(ok), tostring(err))
   end
   if verb == 'call3' then
    local off = hexnum(parts[2])
    if not off then return 'CALL3 needs <rva> <rcx> <rdx> <r8>' end
    local a, b, c = hexnum(parts[3]) or 0, hexnum(parts[4]) or 0, hexnum(parts[5]) or 0
    local fn = ffi.cast('void (*)(void *, void *, void *)', ffi.cast('uintptr_t', base + off))
    local ok, err = pcall(function()
     fn(ffi.cast('void *', a), ffi.cast('void *', b), ffi.cast('void *', c))
    end)
    return string.format('CALL3 rva=0x%x rcx=0x%x rdx=0x%x r8=0x%x ok=%s err=%s',
     off, a, b, c, tostring(ok), tostring(err))
   end
   -- the chat panel update reads the box and calls send(service+0xC418, 0, box):
   -- sendbox writes the box and calls exactly that, so the game sends it with its own code
   if verb == 'sendbox' then
    local body = line:match('^sendbox%s+(.*)$') or ''
    if body == '' then return 'SENDBOX needs <text>' end
    if #body + 1 > INPUT_CAPACITY then return 'SENDBOX too long' end
    if not write(input_at, body .. '\0') then return 'SENDBOX write failed' end
    local service = u64(read(base + 0x347CEF0, 8), 0)
    if not service then return 'SENDBOX service pointer unreadable' end
    local context = service + 0xC418
    local fn = ffi.cast('void (*)(void *, void *, void *)',
     ffi.cast('uintptr_t', base + 0x1097560))
    local ok, err = pcall(function()
     fn(ffi.cast('void *', context), ffi.cast('void *', 0), ffi.cast('void *', input_at))
    end)
    return string.format('SENDBOX ctx=0x%x text="%s" ok=%s err=%s', context, text(body, 60),
     tostring(ok), tostring(err))
   end
   if verb == 'mods' then
    local game = k.GetModuleHandleA('game.dll')
    local exe = k.GetModuleHandleA(nil)
    return string.format('MODS game=0x%x exe=0x%x base=0x%x manager=0x%x box=0x%x ring=0x%x',
     tonumber(ffi.cast('uintptr_t', game)) or 0, tonumber(ffi.cast('uintptr_t', exe)) or 0,
     base or 0, manager or 0, input_at or 0, ring or 0)
   end
   if verb == 'dumpimg' then
    start_dump()
    return 'DUMPIMG restart'
   end
   return 'UNKNOWN command (status|hex|box|cr|crkey|set|set32|submit|scan|rank|save|call|mods|dumpimg)'
  end

  local function command_step()
   if not manager then return end
   if env_string('HD2BC_WORKBENCH') ~= '1' then return end
   if now() - cmd_at < 0.25 then return end
   cmd_at = now()
   local where = work_dir()
   if not where then return end
   local content = file_read(where .. '\\cmd.txt')
   if not content or content == cmd_last then return end
   cmd_last = content
   local line = content:gsub('%s+$', '')
   if line == '' then return end
   self.line('CMD ' .. text(line, 160))
   local ok, out = pcall(run_command, line)
   if not ok then
    self.line('CMD FAULT ' .. tostring(out))
   elseif out and out ~= '' then
    self.line('OUT ' .. text(out, 240))
   end
  end

  local function deferred_step()
   if cr_pending and now() >= cr_at then
    cr_pending = false
    local result = inject('cr')
    self.line(string.format('CRFIRE text="%s" %s', text(cr_label, 60), tostring(result)))
    report_at, report_label = now() + 0.6, cr_label
   end
   if report_at > 0 and now() >= report_at then
    report_at = 0
    self.line(string.format('CRAFTER text="%s" box="%s"', text(report_label, 60),
     text(read_box() or '?', 60)))
   end
  end

  local function monitor_step()
   if scan_until == 0 then return end
   if now() >= scan_until then
    scan_until = 0
    self.line('SCAN end ' .. rank(20))
    return
   end
   if now() - scan_sample_at < 0.2 then return end
   scan_sample_at = now()
   local region = read(manager, REGION_SPAN)
   if not region then return end
   if monitor_last then
    local shown, changed = {}, 0
    for off = 0, REGION_SPAN - 1 do
     local before, after = monitor_last:byte(off + 1), region:byte(off + 1)
     if before ~= after then
      changed = changed + 1
      local key = string.format('+0x%x', off)
      flips[key] = (flips[key] or 0) + 1
      flip_value[key] = string.format('%02x->%02x', before, after)
      if #shown < 12 then
       shown[#shown + 1] = string.format('%s %02x->%02x', key, before, after)
      end
     end
    end
    if changed > 0 then
     self.line(string.format('CHG n=%d %s', changed, table.concat(shown, ' ')))
    end
   end
   monitor_last = region
  end

  function self.step()
   local t0 = now()
   if not base then
    local ok, why = resolve()
    if not ok then self.line('WAIT resolve=' .. tostring(why)) perf_end(t0) return end
    self.line(string.format('ARMED mode=%s prefix=%s transport=%s tid=%d', mode, prefix,
     transport, thread_id()))
    -- start the helper while the player is still loading, so the first chat line already finds a
    -- warm process and a warm connection instead of paying for both
    if transport == 'auto' or transport == 'helper' then start_helper() end
    if not dumped then
     dumped = true
     if not hook() and env_string('HD2BC_DUMP') == '1' then start_dump() end
    end
    return
   end
   local ok, err = pcall(function()
    command_step()
    deferred_step()
    deferred_translate()
    monitor_step()
    dump_step()
    box_step()
    ring_step()
    helper_tick()
    poll_translation()
    inbound_step()
    send_step()
   end)
   if not ok then self.line('FAULT ' .. tostring(err)) end
   perf_end(t0)
  end

  function self.summary()
   return string.format('own=%d sent=%d failed=%d inbound=%d/%d applied=%d placed=%d reverted=%d',
    counters.own, counters.sent, counters.failed, in_stats.seen, in_stats.done, in_stats.applied,
    in_stats.placed, in_stats.reverted)
  end
  return self
 end,
}
end)()

do
 if rawget(_G, 'HD2BilingualChat9') then return end
 local state = {version = '1.3.0'}
 rawset(_G, 'HD2BilingualChat9', state)
 local loader = rawget(_G, 'CowboyBingusModLoader')
 local log
 if loader and type(loader.open_log) == 'function' then
  local ok, handle = pcall(loader.open_log, 'HD2BilingualChat9.log')
  if ok and handle then log = handle end
 end
 local function note(text)
  if log then pcall(function() log:write(text .. '\n'); log:flush() end) end
 end
 if not (loader and loader.api == 1) then
  note('ERROR=BSL_API_1_REQUIRED')
  return
 end
 local mod = Mod.new(note)
 note('START version=' .. state.version
  .. ' (bilingual chat, one keep-alive helper process carries the translations)')
 note('LANE transport=' .. (os.getenv('HD2BC_TRANSPORT') or 'auto(default)')
  .. ' thinking=' .. (os.getenv('HD2BC_THINKING') or 'off(default)')
  .. ' placeholder=' .. (os.getenv('HD2BC_INBOUND_PLACEHOLDER') or 'on(default)')
  .. ' max=' .. (os.getenv('HD2BC_INBOUND_MAX') or '0(default,unlimited)'))
 note('INBOUND mode=' .. (os.getenv('HD2BC_INBOUND') or 'on(default)')
  .. ' self=' .. (os.getenv('HD2BC_INBOUND_SELF') or 'off(default)')
  .. ' height=' .. (os.getenv('HD2BC_INBOUND_HEIGHT') or 'on(default)')
  .. ' workbench=' .. (os.getenv('HD2BC_WORKBENCH') or 'off(default)'))
 note('PLAN prefill: send one chat line, the translation appears in the box, your Enter sends it')
 note('PERF frame budget probe=on(default) -- HD2BC_PERF=0 silences it')
 note('WORKBENCH write a line into ' .. tostring(os.getenv('LOCALAPPDATA'))
  .. '\\HD2BilingualChat\\cmd.txt : status | hex <off> <len> | box <text> | cr | set <off> <byte>'
  .. ' | submit <text> | scan <s> | rank | call <rva> | dumpimg')
 local original = rawget(_G, 'update')
 if type(original) ~= 'function' then
  note('ERROR=UPDATE_UNAVAILABLE')
  return
 end
 local wrapper = function(...)
  local ok, err = pcall(mod.step)
  state.status = ok and 'RUNNING' or 'FAULT'
  if not ok then
   state.error = tostring(err)
   note('FAULT ' .. tostring(err))
  end
  return original(...)
 end
 rawset(_G, 'update', wrapper)
 note('ARMED')
end
