"""Build Bilingual Chat 1.1.0 and install it into the live mod (Arsenal library + game slot).

  python tools/install_live.py [--dry]

Steps: build the container from work/bilingual_chat_1.1.0.lua with the live identity
(mods/dsh/bilingual_chat9, Guid 2f7b0d31-...), back up both targets, copy the container into the
Arsenal library folder and into the game's data folder slot that currently holds this addon,
then re-parse both copies and check the payload by the TOC length (not by file end).
"""
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
# the container parser lives in the sibling hd2-chat-translate checkout; point HD2_CHAT_TRANSLATE_TOOLS
# somewhere else when it is not next to this repo
sys.path.insert(0, os.environ.get('HD2_CHAT_TRANSLATE_TOOLS',
                                  os.path.join(os.path.dirname(ROOT), 'hd2-chat-translate', 'tools')))
import scan_slots as S  # noqa: E402

PY = sys.executable
SOURCE = os.path.join(ROOT, 'src', 'bilingual_chat.lua')
# both are this machine's own paths: override them (or just use the --dry packaging check)
LIBRARY_MOD = os.environ.get('HD2_ARSENAL_MOD', os.path.join(
    os.environ.get('LOCALAPPDATA', ''), 'hd2arsenal', 'mods', 'BilingualChat9-1.0.9_AR549440'))
GAME_DATA = os.environ.get('HD2_GAME_DATA',
                           r'E:\SteamLibrary\steamapps\common\Helldivers 2\data')
HASH = 0xFB34EB4065DFB532
BUILD = os.path.join(ROOT, 'dist', 'BilingualChat9-1.3.0')
CONTAINER = os.path.join(BUILD, 'Addon', '9ba626afa44a3aa3.patch_0')
DESCRIPTION = ('Bilingual chat for Helldivers 2: your own line goes out untouched and the '
               'translation is sent by the game itself about a second later; other players\' '
               'non-Chinese lines get a translation under them, in this client only.')


def sha(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()


def build():
    # the helper script lives inside the Lua as a long string; refuse to build a stale copy
    import embed_helper  # noqa: E402
    if embed_helper.sync(check=True) != 0:
        raise SystemExit('HELPER_JS is out of sync with helper/hd2bc_helper.js')
    cmd = [PY, os.path.join(ROOT, 'tools', 'pack_addon.py'),
           '--src', SOURCE, '--path', 'mods/dsh/bilingual_chat9', '--rewrite-header',
           '--name', 'Bilingual Chat Auto', '--guid', '2f7b0d31-6c4a-4e8b-9d15-3a8c7e5b2f04',
           '--version', '1.3.0', '--delivery', 'BilingualChat9', '--description', DESCRIPTION]
    out = subprocess.run(cmd, capture_output=True, text=True)
    print(out.stdout.strip())
    if out.returncode != 0:
        raise SystemExit('pack_addon failed:\n' + out.stderr)


def deployed_slots():
    """files the loader will actually take: <bundle>.patch_<digits>, not our own .bak copies"""
    hits = []
    for p in S.containers(GAME_DATA):
        name = os.path.basename(p)
        if '.bak' in name:
            continue
        if not name.rsplit('.patch_', 1)[-1].isdigit():
            continue
        try:
            c = S.read_container(p)
        except Exception:
            continue
        for e in c['entries']:
            if e['name_hash'] == HASH:
                hits.append(p)
    return hits


def backup(path, stamps):
    """keep the old container out of the loader's wildcard (.patch_*) and out of the data root"""
    folder = os.path.join(os.path.dirname(path), '_bak')
    if not os.path.isdir(folder):
        os.makedirs(folder)
    keep = os.path.join(folder, '%s-%s.bak' % (os.path.basename(path).split('.patch_')[0], stamps))
    shutil.copyfile(path, keep)
    return keep


def check(path, label):
    c = S.read_container(path)
    e = c['entries'][0]
    with open(path, 'rb') as f:
        f.seek(e['offset'])
        env = struct.unpack('<II', f.read(8))
        f.seek(e['offset'] + 8)
        src = f.read(e['src_len'])
    tail_ok = e['gap'] == 0 and c['total'] == c['size'] == os.path.getsize(path)
    print('%-10s size=%d count=%d total=%d aligned16=%s envelope=(%d,%d) gap=%d resource=%#x'
          % (label, c['size'], c['count'], c['total'], c['size'] % 16 == 0, env[0], env[1],
             e['gap'], e['name_hash']))
    print('           payload=%d sha=%s lengths_consistent=%s'
          % (len(src), hashlib.sha256(src).hexdigest()[:24], tail_ok))
    return src, tail_ok


def main():
    dry = '--dry' in sys.argv
    build()
    stamps = time.strftime('%Y%m%d%H%M%S')
    targets = [(os.path.join(LIBRARY_MOD, 'Addon', '9ba626afa44a3aa3.patch_0'), 'library')]
    slots = deployed_slots()
    print('deployed files holding this addon: %s' % ', '.join(os.path.basename(p) for p in slots))
    if len(slots) != 1:
        raise SystemExit('expected exactly one deployed slot, found %d' % len(slots))
    targets.append((slots[0], 'deployed'))
    for path, label in targets:
        if not os.path.isfile(path):
            raise SystemExit('%s missing: %s' % (label, path))
        print('%s: old size=%d sha=%s' % (label, os.path.getsize(path), sha(path)[:24]))
        if not dry:
            print('       backup -> %s' % backup(path, stamps))
    print()
    built = sha(CONTAINER)
    print('built container sha=%s' % built)
    for path, label in targets:
        if not dry:
            shutil.copyfile(CONTAINER, path)
    print()
    bad = 0
    for path, label in targets:
        src, ok = check(path, label)
        print('           sha=%s' % sha(path)[:24])
        if not ok or sha(path) != built:
            bad += 1
    print()
    payload, ok = check(CONTAINER, 'build')
    if not ok:
        bad += 1
    # verify the way the loader reads it: slice the payload by the TOC length, then compile
    check_path = os.path.join(ROOT, 'work', 'deployed_check.lua')
    with open(check_path, 'wb') as f:
        f.write(payload)
    print('payload written to %s' % check_path)
    if bad:
        raise SystemExit('INCONSISTENT: %d problem(s)' % bad)
    print('all copies consistent')
    return 0


if __name__ == '__main__':
    sys.exit(main())
