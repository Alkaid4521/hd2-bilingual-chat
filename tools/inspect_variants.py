"""Reconcile the three copies of our own addon: repo src / Arsenal library / deployed slot.

usage: python tools/inspect_variants.py
"""
import difflib
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# the container parser lives in the sibling hd2-chat-translate checkout; point HD2_CHAT_TRANSLATE_TOOLS
# somewhere else when it is not next to this repo
sys.path.insert(0, os.environ.get('HD2_CHAT_TRANSLATE_TOOLS',
                                  os.path.join(os.path.dirname(ROOT), 'hd2-chat-translate', 'tools')))
import scan_slots as S  # noqa: E402

W = os.path.join(ROOT, 'tmp')
GAME_DATA = os.environ.get('HD2_GAME_DATA',
                           r'E:\SteamLibrary\steamapps\common\Helldivers 2\data')
DEPLOYED = os.path.join(GAME_DATA, '9ba626afa44a3aa3.patch_1')
MODS = os.environ.get('HD2_ARSENAL_MODS',
                      os.path.join(os.environ.get('LOCALAPPDATA', ''), 'hd2arsenal', 'mods'))
LIBRARY = os.path.join(MODS, 'BilingualChat9-1.0.9_AR549440', 'Addon',
                       '9ba626afa44a3aa3.patch_0')
DIST = os.path.join(ROOT, 'dist', 'BilingualChat-1.0.0', 'Addon', '9ba626afa44a3aa3.patch_0')
HASH = 0xFB34EB4065DFB532


def dump(path, out):
    c = S.read_container(path)
    for e in c['entries']:
        if e['name_hash'] == HASH:
            with open(path, 'rb') as f:
                f.seek(e['offset'] + 8)
                src = f.read(e['src_len'])
            with open(out, 'wb') as g:
                g.write(src)
            return c['size'], e['src_len']
    return None, None


def show(path, name):
    c = S.read_container(path)
    for e in c['entries']:
        with open(path, 'rb') as f:
            f.seek(e['offset'] + 8)
            head = f.read(80)
        print('%-9s container=%7d count=%d hash=%#018x src=%d | %s'
              % (name, c['size'], c['count'], e['name_hash'], e['src_len'],
                 head.decode('utf-8', 'replace').split('\n')[0]))
        return e['name_hash']
    return None


def main():
    os.makedirs(W, exist_ok=True)
    for name, path, out in (('deployed', DEPLOYED, os.path.join(W, 'deployed_bilingual.lua')),
                            ('library', LIBRARY, os.path.join(W, 'library_bilingual.lua'))):
        size, src = dump(path, out)
        print('%-9s container=%s payload=%s -> %s' % (name, size, src, out))
    print()
    for name, p in (('dist', DIST), ('deployed', DEPLOYED), ('library', LIBRARY)):
        show(p, name)
    print()

    blobs = {}
    for key, p in (('repo src', os.path.join(ROOT, 'src', 'bilingual_chat.lua')),
                   ('deployed', os.path.join(W, 'deployed_bilingual.lua')),
                   ('library', os.path.join(W, 'library_bilingual.lua'))):
        b = open(p, 'rb').read()
        blobs[key] = b
        print('%-9s %7d B %4d lines sha %s | %s'
              % (key, len(b), b.count(b'\n') + 1, hashlib.sha256(b).hexdigest()[:20],
                 b.split(b'\n', 1)[0].decode('utf-8', 'replace')))

    print('\n=== murmur64a(declared path) vs container hash ===')
    for path in ('mods/alkaid/bilingual_chat', 'mods/dsh/bilingual_chat9'):
        h = S.__dict__  # keep scan_slots import used
        del h
        import struct

        m = 0xc6a4a7935bd1e995
        data = path.encode('ascii')
        hh = (len(data) * m) & 0xFFFFFFFFFFFFFFFF
        n = len(data) // 8
        for i in range(n):
            k = struct.unpack_from('<Q', data, i * 8)[0]
            k = (k * m) & 0xFFFFFFFFFFFFFFFF
            k ^= k >> 47
            k = (k * m) & 0xFFFFFFFFFFFFFFFF
            hh ^= k
            hh = (hh * m) & 0xFFFFFFFFFFFFFFFF
        tail = data[n * 8:]
        if tail:
            hh ^= int.from_bytes(tail, 'little')
            hh = (hh * m) & 0xFFFFFFFFFFFFFFFF
        hh ^= hh >> 47
        hh = (hh * m) & 0xFFFFFFFFFFFFFFFF
        hh ^= hh >> 47
        print('  %-30s %#018x %s' % (path, hh, 'MATCH' if hh == HASH else ''))

    for label, other in (('repo vs deployed', 'deployed'), ('library vs deployed', 'deployed')):
        left = blobs['repo src'] if label.startswith('repo') else blobs['library']
        a = left.decode('utf-8', 'replace').splitlines()
        b = blobs[other].decode('utf-8', 'replace').splitlines()
        d = list(difflib.unified_diff(a, b, label.split()[0], other, n=1, lineterm=''))
        print('\n=== %s : %d diff lines ===' % (label, len(d)))
        for line in d[:70]:
            print(line[:150])


if __name__ == '__main__':
    main()
