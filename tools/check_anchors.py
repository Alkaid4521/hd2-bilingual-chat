"""Print exact indentation/content for every anchor add_inbound.py depends on."""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tmp', 'deployed_bilingual.lua')
text = open(SRC, encoding='utf-8').read()
lines = text.split('\n')

print('--- ring_step tail (927-936) ---')
for i in range(926, 936):
    print('%4d %r' % (i + 1, lines[i]))

print('\n--- anchors ---')
anchors = [
    '  -- ---- sending -------------------------------------------------------------------------',
    '  local function finish_translation(response, tag, source)',
    '   if #content > BOX_CAPACITY then content = content:sub(1, BOX_CAPACITY) end',
    '    local source, tag = inflight.source, inflight.tag',
    '   local source, tag = inflight.source, inflight.tag',
    '    ring_step()',
    '    poll_translation()',
    '    send_step()',
    '   if not manager then return end',
    '   if now() - cmd_at < 0.25 then return end',
    '     if not hook() then start_dump() end',
    "  local self = {version = '1.0.9', lines = 0, maxlines = 20000}",
    " local state = {version = '1.0.9'}",
    '  function self.summary()',
    "-- Bilingual chat for Helldivers 2, build 1.0.9.",
    '       self.line(string.format(\'OWN message name="%s" body="%s"\', name, body_t))',
    "        self.line(string.format('OWN message name=\"%s\" body=\"%s\"', name, body_t))",
]
for a in anchors:
    print('%3d  %r' % (text.count(a), a[:96]))
    if text.count(a) != 1:
        for i, line in enumerate(lines):
            if a in line:
                print('        line %d %r' % (i + 1, line))
print('\nsize=%d' % os.path.getsize(SRC))
