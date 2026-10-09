"""Compare two copies of the addon ignoring comment/blank lines (code-only diff)."""
import difflib
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.join(ROOT, 'src', 'bilingual_chat.lua')
DEPLOYED = os.path.join(ROOT, 'tmp', 'deployed_bilingual.lua')
WORK = os.path.join(ROOT, 'work')
os.makedirs(WORK, exist_ok=True)
TARGET = os.path.join(WORK, 'bilingual_chat_1.1.0.lua')


def code_lines(path):
    out = []
    for line in open(path, encoding='utf-8').read().splitlines():
        s = line.strip()
        if s == '' or s.startswith('--'):
            continue
        out.append(line)
    return out


a, b = code_lines(REPO), code_lines(DEPLOYED)
print('code lines: repo=%d deployed=%d' % (len(a), len(b)))
d = list(difflib.unified_diff(a, b, 'repo-code', 'deployed-code', n=2, lineterm=''))
print('code diff lines: %d' % len(d))
for line in d[:60]:
    print(line[:150])

if not d:
    shutil.copyfile(DEPLOYED, TARGET)
    print('\ncode identical -> working copy: %s' % TARGET)
    print('bytes %d' % os.path.getsize(TARGET))
