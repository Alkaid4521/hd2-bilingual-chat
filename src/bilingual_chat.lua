-- HD2-Addon: mods/alkaid/bilingual_chat
-- Bilingual Chat for Helldivers 2, build 1.0.0.
--
-- Send one chat line; about a second later a second, real chat message carries the translation,
-- so teammates read it too.  Your own line goes out untouched and is never held back.
--
-- How the second message is sent: the mod writes the translation into the game's chat input box
-- (manager+0x16D4), sets the panel-active byte (manager+0x139B8) and the submit byte
-- (manager+0x1E0F).  The game's own chat panel update then consumes the flag, hands the box to its
-- send routine and clears it -- exactly what pressing Enter does, so no key is injected and there
-- is nothing for the anti-cheat to filter.  If the game does not take it within 1.5 s the
-- translation is simply left in the box: press Enter yourself and it still goes out.
--
-- Translation runs in a separate curl.exe process (no native code inside the game): the request
-- body goes to %LOCALAPPDATA%\HD2BilingualChat\*, together with a curl config file that holds the
-- API key, so the key never appears on a command line.  Nothing blocks the render thread.
--
-- Modes (HD2BC_MODE):
--   mem      (default) the game sends the translation itself, you press nothing
--   prefill  write the translation into the box and wait for your own Enter
--   auto     try the older key-injection routes (filtered by the anti-cheat on current builds)
--   dry      translate and log only, never send
--   off      do nothing
--
-- Environment:
--   HD2BC_MODE      = mem (default) | prefill | auto | dry | off
--   HD2BC_PREFIX    = auto (default "[EN] " / "[CN] ") | 0 | any literal prefix
--   HD2BC_TRANSPORT = curl (default) | dll
--   HD2CT_API_URL, HD2CT_MODEL, HD2CT_API_KEY   endpoint, model name and key
--
-- Debug switches (off by default, development only -- they can crash the game):
--   HD2BC_WORKBENCH = 1   listen on %LOCALAPPDATA%\HD2BilingualChat\cmd.txt
--   HD2BC_DUMP      = 1   write the loaded game.dll image into that folder
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
  local self = {version = '1.0.0', lines = 0, maxlines = 20000}
  local base, root, ring, manager, input_at
  local last_meta = ''
  local last_box = ''
  local typed, self_name, verify_text = nil, nil, nil
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
  local transport = os.getenv('HD2BC_TRANSPORT') or 'curl'

  function self.line(s)
   if self.lines >= self.maxlines then return end
   self.lines = self.lines + 1
   note(string.format('t=%.1f %s', now(), s))
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
   return string.format(
    '{"model":"%s","messages":[{"role":"system","content":"%s"},{"role":"user","content":"%s"}],'
    .. '"temperature":0.2,"max_tokens":200,"stream":false}',
    json_escape(model), json_escape(system), json_escape(user))
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

  -- ---- translation lifecycle -----------------------------------------------------------
  local function start_translation(source)
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
   local ok, why = start_curl(body)
   if not ok then
    counters.failed = counters.failed + 1
    self.line('SKIP translate reason=' .. tostring(why))
    return
   end
   inflight = {source = source, tag = tag, at = now()}
   self.line(string.format('CURL started tag=%s src="%s"', tag, text(source, 60)))
  end

  local function finish_translation(response, tag, source)
   local content = extract_content(response)
   if not content then
    counters.failed = counters.failed + 1
    self.line(string.format('TRANSLATE failed raw="%s"', text(response, 140)))
    return
   end
   content = content:gsub('%s+', ' ')
   if content == '' then
    counters.failed = counters.failed + 1
    self.line('TRANSLATE empty')
    return
   end
   if #content > BOX_CAPACITY then content = content:sub(1, BOX_CAPACITY) end
   local final = content
   if prefix == 'auto' then
    final = '[' .. tag .. '] ' .. content
   elseif prefix ~= '' and prefix ~= '0' then
    final = prefix .. ' ' .. content
   end
   tr_ready = {text = final, source = source}
   self.line(string.format('TRANSLATE ok tag=%s len=%d text="%s"', tag, #final, text(final, 120)))
  end

  local function poll_translation()
   if not inflight then return end
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
    inflight = nil
    finish_translation(response, tag, source)
    return
   end
   local response = poll_curl()
   if response == nil then
    if now() - inflight.at > TRANSLATE_TIMEOUT then
     counters.failed = counters.failed + 1
     self.line('CURL timeout (no process)')
     inflight = nil
    end
    return
   end
   local source, tag = inflight.source, inflight.tag
   inflight = nil
   finish_translation(response, tag, source)
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
    local rec = ring + ((previous + i - 1) % 64) * RING_STRIDE
    local head = read(rec, NAME_OFFSET + 32)
    local body = read(rec + BODY_OFFSET, BODY_CAPACITY)
    if u32(head, 0) == EVENT_CHAT and head then
     local name = text(head:sub(NAME_OFFSET + 1), 40)
     local body_t = text(body, 200)
     if body_t ~= '' then
      if verify_text and body_t == verify_text then
       verify_text = nil
       self.line('SEND verified: the translation is in the chat ring')
      elseif sent_bodies[body_t] then
       self.line('RING our own translation came back (ignored)')
      elseif typed and body_t == typed and (self_name == nil or name == self_name) then
       self_name = name
       counters.own = counters.own + 1
       typed = nil
       self.line(string.format('OWN message name="%s" body="%s"', name, body_t))
       if mode ~= 'off' then start_translation(body_t) end
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
   if not base then
    local ok, why = resolve()
    if not ok then self.line('WAIT resolve=' .. tostring(why)) return end
    self.line(string.format('ARMED mode=%s prefix=%s transport=%s', mode, prefix, transport))
    if not dumped then
     dumped = true
     if not hook() and env_string('HD2BC_DUMP') == '1' then start_dump() end
    end
    return
   end
   local ok, err = pcall(function()
    command_step()
    deferred_step()
    monitor_step()
    dump_step()
    box_step()
    ring_step()
    poll_translation()
    send_step()
   end)
   if not ok then self.line('FAULT ' .. tostring(err)) end
  end

  function self.summary()
   return string.format('own=%d sent=%d failed=%d', counters.own, counters.sent, counters.failed)
  end
  return self
 end,
}
end)()

do
 if rawget(_G, 'HD2BilingualChat') then return end
 local state = {version = '1.0.0'}
 rawset(_G, 'HD2BilingualChat', state)
 local loader = rawget(_G, 'CowboyBingusModLoader')
 local log
 if loader and type(loader.open_log) == 'function' then
  local ok, handle = pcall(loader.open_log, 'HD2BilingualChat.log')
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
 note('START version=' .. state.version .. ' addon=' .. 'mods/alkaid/bilingual_chat')
 note('MODES mem (default, automatic) | prefill (you press Enter) | auto | dry | off')
 note('PLAN send one chat line; about a second later the translation is sent the same way')
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
