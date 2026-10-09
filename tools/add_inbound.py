"""Turn the running 1.0.9 addon into 1.1.0 with inbound translation.

Input : tmp/deployed_bilingual.lua  (byte-identical to the Arsenal library copy, verified)
Output: work/bilingual_chat_1.1.0.lua

Every replacement is asserted to hit exactly once, so the script fails loudly if the input is not
the source it was written against.  Idempotence is not a goal: rebuild from tmp/ each time.

What is added: other players' non-Chinese lines are translated (same curl child process, same
HD2CT_* configuration) and the result is written under the original line in *this* client only.
HD2BC_INBOUND=probe (default) resolves the UI row and reports what it found without writing;
=on also calls the game's body setter.  =off disables the feature.
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tmp', 'deployed_bilingual.lua')
OUT = os.path.join(ROOT, 'work', 'bilingual_chat_1.1.0.lua')

HEADER_DOC = r"""-- Bilingual chat for Helldivers 2, build 1.1.0.
--
-- New in 1.1.0: inbound translation.  When another player writes something that is not Chinese,
-- the line is translated (same curl child process, same HD2CT_* settings) and the translation is
-- written *under that line* -- in this client only, nothing is broadcast:
--
--     <what the teammate wrote>
--     <INBOUND_LABEL>what it means
--
--   HD2BC_INBOUND = probe (default) report the row resolution and the translation, write nothing
--                 = on              also write it into the row (calls the game's body setter)
--                 = off             disable inbound translation
--   HD2BC_INBOUND_LABEL = the text put in front of the translation (default is the usual
--                         Chinese "translation:" label, prefixed with a newline)
--
-- The UI row is not assumed to share the ring index: a row is matched by the string pointer of
-- its body property (key 0x7518C954) against the ring body address, and nothing is written before
-- that match is confirmed.  Own lines, [EN]/[CN] echoes and messages that are already Chinese are
-- never sent to the API (a Chinese line used to cost a wasted request)."""

CONSTANTS = r"""  -- inbound layout constants.  They live inside the factory on purpose: the module-level scope
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
  local INBOUND_MAX = 12
  local INBOUND_LIMIT = 2048
  local WIDE_SCAN = 0x10000
  -- fingerprint of the game's own row -> body wiring.  Verified byte for byte against the dumped
  -- image with tools/verify_offsets.py before every build: the sequence starts at 0x1860C49
  -- (lea r8,[rbx+0xB4] / mov edx,0x7518C954 / mov rcx,rsi / call).
  local GUARD_RVA = 0x1860C49
  local GUARD_BYTES = string.char(0x4c, 0x8d, 0x83, 0xb4, 0x00, 0x00, 0x00, 0xba, 0x54, 0xc9,
   0x18, 0x75, 0x48, 0x8b, 0xce, 0xe8)
"""

STATE = r"""  local transport = os.getenv('HD2BC_TRANSPORT') or 'curl'
  local in_mode = os.getenv('HD2BC_INBOUND') or 'on'
  local in_label = os.getenv('HD2BC_INBOUND_LABEL') or '\n译文：'
  local in_arg = tonumber(os.getenv('HD2BC_INBOUND_ARG')) or 0x110
  local in_self = os.getenv('HD2BC_INBOUND_SELF') ~= '0'
  local in_height = os.getenv('HD2BC_INBOUND_HEIGHT') ~= '0'
  local self_index = nil
  local in_seen, in_queue, in_ready, in_probed, in_slots = {}, {}, {}, {}, {}
  local in_sig, in_last, in_idle_logged = nil, 0, false
  local in_stats = {seen = 0, done = 0, applied = 0, failed = 0}"""

INBOUND_BLOCK = r"""  -- ---- inbound: put a translation under other players' lines (this client only) ------------
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
  local function find_slot_for(index)
   local want = ring_body_at(index)
   local map, match = {}, nil
   for slot = 0, 63 do
    local hits = scan_key_hits(slot_at(slot), WIDGET_STRIDE)
    if hits then
     for i = 1, #hits do
      local h = hits[i]
      if h.value == want then
       match = {slot = slot, off = h.off, value = h.value, at = slot_at(slot) + h.off}
      else
       local other = map_from_value(h.value)
       if other then map[slot] = other end
      end
     end
    end
   end
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

  local function write_inbound(index, entry)
   local blob = entry.body .. in_label .. entry.text
   local buf = inbound_buffer(index, blob)
   if not buf then return false, 'too_long' end
   local match = find_slot_for(index)
   if not match then return false, 'no_slot' end
   if in_mode ~= 'on' then
    self.line(string.format('INBOUND ready idx=%d slot=%d off=+0x%x len=%d text="%s"', index,
     match.slot, match.off, #blob, text(blob, 80)))
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
   local want = tonumber(ffi.cast('uintptr_t', buf))
   self.line(string.format(
    'INBOUND %s idx=%d slot=%d off=+0x%x value=%#x>%#x want=%#x len=%d err=%s',
    ok and 'set' or 'set_fault', index, match.slot, match.off, match.value, now_value, want, #blob,
    tostring(err)))
   if ok and now_value == want then
    in_stats.applied = in_stats.applied + 1
    -- the row is laid out top-down from its own height (measured 17.0 px with scale 1.0), so a
    -- second line needs the height to grow or it overlaps the next row
    if in_height then
     local lines = 1
     for _ in blob:gmatch('\n') do lines = lines + 1 end
     local h0 = read_float(at + 0x10)
     if lines > 1 and h0 and h0 > 0 and h0 < 4096 then
      if write(at + 0x10, float_bytes(h0 * lines)) then
       self.line(string.format('INBOUND height slot=%d %.1f -> %.1f (lines=%d)', match.slot,
        h0, h0 * lines, lines))
      else
       self.line(string.format('INBOUND height write failed slot=%d', match.slot))
      end
     end
    end
    return true, 'applied'
   end
   return false, ok and 'unconfirmed' or 'fault'
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
   if #in_queue >= INBOUND_QUEUE or in_stats.seen >= INBOUND_MAX then return end
   in_seen[body_t] = true
   in_stats.seen = in_stats.seen + 1
   in_queue[#in_queue + 1] = {name = name, body = body_t, index = index, at = now()}
   self.line(string.format('INBOUND queued idx=%d from="%s" len=%d', index, text(name, 24),
    #body_t))
  end

  local function start_inbound(item)
   local body = request_body(item.body, 'Simplified Chinese')
   if #body > BODY_LIMIT then
    in_stats.failed = in_stats.failed + 1
    self.line('INBOUND skip idx=' .. item.index .. ' reason=body_too_long')
    return
   end
   local ok, why = start_curl(body)
   if not ok then
    in_stats.failed = in_stats.failed + 1
    self.line('INBOUND request failed reason=' .. tostring(why))
    return
   end
   in_last = now()
   inflight = {purpose = 'in', item = item, source = item.body, tag = 'ZH', at = now()}
   self.line(string.format('INBOUND request idx=%d from="%s"', item.index, text(item.name, 24)))
  end

  local function inbound_step()
   if in_mode == 'off' then return end
   for i = #in_queue, 1, -1 do
    if now() - in_queue[i].at > INBOUND_TTL then table.remove(in_queue, i) end
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
    local ok, why = pcall(write_inbound, index, entry)
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


"""

RING_INDEX = ("""   for i = 1, span do
    local rec = ring + ((previous + i - 1) % 64) * RING_STRIDE""",
              """   for i = 1, span do
    local index = (previous + i - 1) % 64
    local rec = ring + index * RING_STRIDE""")

RING_ELSE = ("""       self.line(string.format('OWN message name="%s" body="%s"', name, body_t))
       if mode ~= 'off' then start_translation(body_t) end
      end""",
             """       self.line(string.format('OWN message name="%s" body="%s"', name, body_t))
       if mode ~= 'off' then start_translation(body_t, index) end
       -- our own line is a row in the same chat window: probing it is how the row layout gets
       -- reported even when nobody else writes anything
       if in_mode == 'probe' then probe_index(index) end
      else
       consider_inbound(name, body_t, index)
      end""")

FINISH_SIG = ("  local function finish_translation(response, tag, source)",
              "  local function finish_translation(response, tag, source, purpose, item)")

FINISH_BRANCH = ("""   if #content > BOX_CAPACITY then content = content:sub(1, BOX_CAPACITY) end
   local final = content""",
                 """   if purpose == 'in' then
    in_stats.done = in_stats.done + 1
    in_ready[item.index] = {body = item.body, text = content, name = item.name}
    self.line(string.format('INBOUND translated idx=%d len=%d text="%s"', item.index, #content,
     text(content, 80)))
    return
   end
   if #content > BOX_CAPACITY then content = content:sub(1, BOX_CAPACITY) end
   local final = content""")

CALL_API = ("""    local source, tag = inflight.source, inflight.tag
    inflight = nil
    finish_translation(response, tag, source)""",
            """    local source, tag = inflight.source, inflight.tag
    local purpose, item = inflight.purpose, inflight.item
    inflight = nil
    finish_translation(response, tag, source, purpose, item)""")

CALL_CURL = ("""    return
   end
   local source, tag = inflight.source, inflight.tag
   inflight = nil
   finish_translation(response, tag, source)""",
             """    return
   end
   local source, tag = inflight.source, inflight.tag
   local purpose, item = inflight.purpose, inflight.item
   inflight = nil
   finish_translation(response, tag, source, purpose, item)""")

START_INBOUND_HOOK = ("""  local function start_inbound(item)
   local body = request_body(item.body, 'Simplified Chinese')""",
                      """  local function start_inbound(item)
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
    return
   end
   local body = request_body(item.body, 'Simplified Chinese')""")

SELF_INDEX_SIG = ("""  local function start_translation(source)""",
                  """  local function start_translation(source, index)
   self_index = index""")

SELF_TEST = ("""   tr_ready = {text = final, source = source}""",
             """   -- self test: put the translation under our own line, so the write path can be exercised
   -- without waiting for a teammate to say something
   if in_self and in_mode ~= 'off' and self_index then
    in_ready[self_index] = {body = source, text = content, name = self_name or '?'}
    self.line(string.format('INBOUND self-test idx=%d translation="%s"', self_index,
     text(content, 60)))
   end
   tr_ready = {text = final, source = source}""")

STEP_HOOK = ("""    ring_step()
    poll_translation()
    send_step()""",
             """    ring_step()
    poll_translation()
    inbound_step()
    send_step()""")

WORKBENCH_GATE = ("""   if not manager then return end
   if now() - cmd_at < 0.25 then return end""",
                  """   if not manager then return end
   if env_string('HD2BC_WORKBENCH') == '0' then return end
   if now() - cmd_at < 0.25 then return end""")

DUMP_GATE = ("""     if not hook() then start_dump() end""",
             """     if not hook() and env_string('HD2BC_DUMP') == '1' then start_dump() end""")

LOG_BANNER = (""" note('START version=' .. state.version .. ' (bilingual chat, translation runs in curl.exe)')""",
              """ note('START version=' .. state.version .. ' (bilingual chat, translation runs in curl.exe)')
 note('INBOUND mode=' .. (os.getenv('HD2BC_INBOUND') or 'on(default)')
  .. ' self=' .. (os.getenv('HD2BC_INBOUND_SELF') or 'on(default)')
  .. ' height=' .. (os.getenv('HD2BC_INBOUND_HEIGHT') or 'on(default)')
  .. ' workbench=' .. (os.getenv('HD2BC_WORKBENCH') or 'on(default)'))""")

VERSION = ("""  local self = {version = '1.0.9', lines = 0, maxlines = 20000}""",
           """  local self = {version = '1.1.0', lines = 0, maxlines = 20000}""")

STATE_VERSION = (""" local state = {version = '1.0.9'}""",
                 """ local state = {version = '1.1.0'}""")

SUMMARY = ("""  function self.summary()
   return string.format('own=%d sent=%d failed=%d', counters.own, counters.sent, counters.failed)
  end""",
           """  function self.summary()
   return string.format('own=%d sent=%d failed=%d inbound=%d/%d applied=%d',
    counters.own, counters.sent, counters.failed, in_stats.seen, in_stats.done, in_stats.applied)
  end""")

EDITS = [
    ('header doc', r"""-- Bilingual chat for Helldivers 2, build 1.0.9.""", HEADER_DOC),
    ('state', r"""  local transport = os.getenv('HD2BC_TRANSPORT') or 'curl'""", STATE),
    ('inbound block', r"""  -- ---- sending -------------------------------------------------------------------------""",
     CONSTANTS + INBOUND_BLOCK + r"""  -- ---- sending -------------------------------------------------------------------------"""),
    ('ring index', RING_INDEX[0], RING_INDEX[1]),
    ('ring else', RING_ELSE[0], RING_ELSE[1]),
    ('finish signature', FINISH_SIG[0], FINISH_SIG[1]),
    ('self index', SELF_INDEX_SIG[0], SELF_INDEX_SIG[1]),
    ('self test', SELF_TEST[0], SELF_TEST[1]),
    ('start inbound hook', START_INBOUND_HOOK[0], START_INBOUND_HOOK[1]),    ('finish branch', FINISH_BRANCH[0], FINISH_BRANCH[1]),
    ('call api', CALL_API[0], CALL_API[1]),
    ('call curl', CALL_CURL[0], CALL_CURL[1]),
    ('step hook', STEP_HOOK[0], STEP_HOOK[1]),
    ('workbench gate', WORKBENCH_GATE[0], WORKBENCH_GATE[1]),
    ('dump gate', DUMP_GATE[0], DUMP_GATE[1]),
    ('log banner', LOG_BANNER[0], LOG_BANNER[1]),
    ('version', VERSION[0], VERSION[1]),
    ('state version', STATE_VERSION[0], STATE_VERSION[1]),
    ('summary', SUMMARY[0], SUMMARY[1]),
]


def main():
    if not os.path.isfile(SRC):
        raise SystemExit('run tools/inspect_variants.py first: %s missing' % SRC)
    text = open(SRC, encoding='utf-8').read()
    print('input %s bytes=%d sha=%s' % (SRC, len(text.encode()),
                                        hashlib.sha256(text.encode()).hexdigest()[:20]))
    for label, old, new in EDITS:
        if label == 'constants':
            pass
        count = text.count(old)
        if count != 1:
            raise SystemExit('%s: expected 1 occurrence, found %d' % (label, count))
        text = text.replace(old, new)
        print('  ok %-18s +%d bytes' % (label, len(new.encode()) - len(old.encode())))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    blob = text.encode('utf-8')
    with open(OUT, 'wb') as f:
        f.write(blob)
    print('output %s bytes=%d lines=%d sha=%s' % (OUT, len(blob), blob.count(b'\n') + 1,
                                                  hashlib.sha256(blob).hexdigest()[:20]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
