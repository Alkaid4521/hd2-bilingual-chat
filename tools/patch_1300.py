"""1.3.0: stop paying for a process spawn on the game thread, and measure the frame budget.

What the numbers say.  Measured on the game's own lua51.dll (tmp/bench_hot.lua): the whole pure-Lua
half of an inbound write is 36 us (find_slot_for over 64 widget slots) and nothing else in the path
reaches 4 us -- so a stutter is not this mod's Lua.  Two things in the path can still cost real wall
time on the game thread, and both are fixed here:

  1. curl.exe.  A request is a CreateProcessW on the game thread (plus a fresh TLS handshake) and
     that is tens of milliseconds of frozen game.  In the 2026-10-08 session the log shows
     lane=curl for every message after t=900, i.e. a process spawn per translation, because the
     helper had idle-exited.  Now the helper is the only lane while it is alive or booting: a
     request that finds it booting is held in the queue instead of spawning curl.  curl is left for
     the case where there is no helper at all (no node, or the restarts are used up).
  2. file I/O per frame.  out.txt was opened, read and closed on every frame while a translation was
     in flight (~60/s), and helper.ready was tested every frame while the helper booted.  Both are
     now polled at a fixed rate; the answer takes hundreds of milliseconds, so 12 Hz is invisible.

The two mutations of a row (placeholder, then the answer) stay: each is one game-side layout pass,
and the placeholder is what makes the feature feel instant.  HD2BC_INBOUND_PLACEHOLDER=0 turns it off
without a rebuild if the log says the placeholder is the pass that hurts.

And PERF lines measure what is left, so the next session answers the question with numbers: the game
runs _G.update once per frame, so the wall time inside our hook is our own cost and the wall time
between the end of our hook and the next frame's entry is the game's (its chat layout lands there).
PERF lines appear only for frames over 20 ms, plus one summary every 10 s; HD2BC_PERF=0 silences them.

  python tools/patch_1300.py [--dry]
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, 'src', 'bilingual_chat.lua')

EDITS = []


def edit(old, new, count=1):
    EDITS.append((old, new, count))


# ---- 1. the frame budget probe (defined before everything that tags it) ----------------------
edit(
    """local function is_cjk(s)
 return s:find('[\\228-\\233]') ~= nil
end
""",
    """-- ---- frame budget probe ---------------------------------------------------------------------
-- The game calls _G.update once per frame, so the wall time between two entries is a frame, the wall
-- time inside our hook is what this mod costs, and the wall time between the end of our hook and the
-- next entry is the game's own work -- which is where its chat layout lands after we change a row.
-- Both halves are measured, so a stutter can be attributed.  One QPC call per frame.
local PERF_ON = os.getenv('HD2BC_PERF') ~= '0'
local PERF_SLOW = 0.020
local PERF_EVERY = 10.0
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

local function is_cjk(s)
 return s:find('[\\228-\\233]') ~= nil
end
""")

# ---- 2. tag the work that can cost wall time -------------------------------------------------
edit(
    """   if not ok or now_value ~= want then
    return false, ok and 'unconfirmed' or 'fault'
   end
""",
    """   if not ok or now_value ~= want then
    return false, ok and 'unconfirmed' or 'fault'
   end
   perf_note('set:' .. kind)
""")

edit(
    """   helper_proc, helper_at, helper_state = info[0].hProcess, now(), 'starting'
   self.line('HELPER starting node=' .. node)
""",
    """   helper_proc, helper_at, helper_state = info[0].hProcess, now(), 'starting'
   perf_note('helper_spawn')
   self.line('HELPER starting node=' .. node)
""")

edit(
    """   helper_seq, helper_job_id = helper_seq + 1, id
   return true
  end
""",
    """   helper_seq, helper_job_id = helper_seq + 1, id
   perf_note('stage')
   return true
  end
""")

edit(
    """   local cmd = string.format('"%s\\\\System32\\\\curl.exe" --config "%s" --data-binary "@%s" -o "%s"',
""",
    """   perf_note('curl_spawn')
   local cmd = string.format('"%s\\\\System32\\\\curl.exe" --config "%s" --data-binary "@%s" -o "%s"',
""")

edit(
    """   local raw = file_read(helper_path('raw.txt'))
   if not raw or raw == '' then return 'ERR\\nHELPER_EMPTY', fields end
""",
    """   local raw = file_read(helper_path('raw.txt'))
   if not raw or raw == '' then return 'ERR\\nHELPER_EMPTY', fields end
   perf_note('answer')
""")

# ---- 3. helper state / poll rates ------------------------------------------------------------
edit(
    """  local helper_dir_path, helper_job_id, helper_seq, node_path = nil, nil, 0, nil
""",
    """  local helper_dir_path, helper_job_id, helper_seq, node_path = nil, nil, 0, nil
  local helper_probe_at, helper_poll_at = 0, 0
""")

edit(
    """  local function helper_tick()
   if helper_state == 'starting' then
    if file_exists(helper_path('helper.ready')) then
""",
    """  local function helper_tick()
   if helper_state == 'starting' then
    -- helper.ready is a file open per test; a helper that boots in 0.3 s does not need 60 of them
    if now() - helper_probe_at < 0.1 then return end
    helper_probe_at = now()
    if file_exists(helper_path('helper.ready')) then
""")

edit(
    """  local function helper_lane()
   if transport ~= 'auto' and transport ~= 'helper' then return false end
   return helper_state == 'ready'
  end

""",
    """  -- a request is only ever handed to the running helper: staging a job for it is two file writes,
  -- while curl.exe is a process spawn on the game thread (and a fresh TLS handshake).  So a request
  -- that finds the helper booting waits for it instead of paying that; curl is left for the case
  -- where there is no helper at all -- no node, or its restarts are used up.
  local function start_request(body)
   if helper_state == 'ready' then
    local ok, why = start_helper_job(body)
    if ok then return 'helper' end
    self.line('HELPER stage failed reason=' .. tostring(why) .. ', using curl')
   elseif helper_state == 'idle' and (transport == 'auto' or transport == 'helper') then
    start_helper()
    return nil, 'helper_booting'
   elseif helper_state == 'starting' then
    return nil, 'helper_booting'
   end
   local ok, why = start_curl(body)
   if not ok then return nil, why end
   return 'curl'
  end

""")

# the old start_request (and its only caller of helper_lane) is now dead
edit(
    """  -- one place decides which lane carries a request, so every caller (our own line, other
  -- players' lines, the self test) behaves the same when the helper is missing or has died
  local function start_request(body)
   if helper_lane() then
    local ok, why = start_helper_job(body)
    if ok then return 'helper' end
    self.line('HELPER stage failed reason=' .. tostring(why) .. ', using curl')
   end
   local ok, why = start_curl(body)
   if not ok then return nil, why end
   return 'curl'
  end

""",
    "")

edit(
    """   if inflight.lane == 'helper' then
    local response, fields = poll_helper()
""",
    """   if inflight.lane == 'helper' then
    -- out.txt costs a file open/read/close pair; the answer takes hundreds of ms, so 12 Hz is plenty
    if now() - helper_poll_at < 0.08 then return end
    helper_poll_at = now()
    local response, fields = poll_helper()
""")

# ---- 4. defer instead of spawning curl -------------------------------------------------------
edit(
    """   local lane, why = start_request(body)
   if not lane then
    in_stats.failed = in_stats.failed + 1
    self.line('INBOUND request failed reason=' .. tostring(why))
    revert_inbound(item.index, item.body, tostring(why))
    return
   end
""",
    """   local lane, why = start_request(body)
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
""")

edit(
    """   local lane, why = start_request(body)
   if not lane then
    counters.failed = counters.failed + 1
    self.line('SKIP translate reason=' .. tostring(why))
    return
   end
""",
    """   local lane, why = start_request(body)
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
""")

edit(
    """  local in_place_at = 0
  local in_stats = {seen = 0, done = 0, applied = 0, failed = 0, placed = 0, reverted = 0}
""",
    """  local in_place_at = 0
  local in_stats = {seen = 0, done = 0, applied = 0, failed = 0, placed = 0, reverted = 0}
  -- a translation of our own line that was put on hold while the helper booted
  local pending_self = nil
""")

edit(
    """  local function finish_translation(response, tag, source, purpose, item)
""",
    """  -- our own line's translation can be on hold while the helper boots (and only then)
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
""")

edit(
    """    command_step()
    deferred_step()
""",
    """    command_step()
    deferred_step()
    deferred_translate()
""")

# ---- 5. one ReadProcessMemory instead of 64 when the row is where it was ---------------------
edit(
    """  local in_temp, in_pending, in_base_h = {}, {}, {}
""",
    """  local in_temp, in_pending, in_base_h = {}, {}, {}
   -- ring index -> the widget slot that showed it last time; a rewrite usually goes to the same slot
   local in_row = {}
""")

edit(
    """  local function find_slot_for(index, alt)
   local want = ring_body_at(index)
   local map, match = {}, nil
""",
    """  local function find_slot_for(index, alt)
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
""")

edit(
    """   return match, map
  end

  -- the addresses the write path depends on; logged once so a moved offset is visible in the log
""",
    """   if match then in_row[index] = match.slot end
   return match, map
  end

  -- the addresses the write path depends on; logged once so a moved offset is visible in the log
""")

# ---- 6. version ------------------------------------------------------------------------------
edit("""  local self = {version = '1.1.0', lines = 0, maxlines = 20000}""",
     """  local self = {version = '1.3.0', lines = 0, maxlines = 20000}""")
edit(""" local state = {version = '1.2.1'}""", """ local state = {version = '1.3.0'}""")
edit(""" note('WORKBENCH write a line into '""",
     """ note('PERF frame budget probe=on(default) -- HD2BC_PERF=0 silences it')
 note('WORKBENCH write a line into '""")


def main():
    dry = '--dry' in sys.argv
    text = open(SOURCE, encoding='utf-8').read()
    problems = []
    for index, (old, new, count) in enumerate(EDITS, 1):
        found = text.count(old)
        label = old.strip().splitlines()[0][:72]
        if found != count:
            problems.append('edit %d: expected %d hit(s), found %d -- %s' % (index, count, found, label))
            continue
        if count == 0:
            continue
        text = text.replace(old, new, count)
        print('ok  edit %2d  %s' % (index, label))
    if problems:
        print('')
        for line in problems:
            print('FAIL ' + line)
        return 1
    if dry:
        print('')
        print('dry run: %d edit(s) would apply, %d bytes -> %d bytes'
              % (len(EDITS), len(open(SOURCE, encoding='utf-8').read()), len(text)))
        return 0
    open(SOURCE, 'w', encoding='utf-8', newline='').write(text)
    print('')
    print('%s: %d edit(s) applied, %d bytes' % (SOURCE, len(EDITS), len(text)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
