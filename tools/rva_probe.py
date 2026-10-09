"""Read bytes out of the game.dll image the addon dumped from its own process.

The dump (`%LOCALAPPDATA%\\HD2BilingualChat\\img_game.dll.bin`) is the *loaded* image, so a byte
offset in that file is the same RVA the mod uses (base + rva).  The sidecar .txt has the section
table, which is how we tell whether an address is inside executable code.

usage:
  python tools/rva_probe.py <rva> [<len>]        hex + ascii of one address
  python tools/rva_probe.py --sections           the section table
  python tools/rva_probe.py --list <rva> ...     compact one line per address
"""
import os
import re
import sys

DEFAULT = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'HD2BilingualChat')
IMG = os.path.join(DEFAULT, 'img_game.dll.bin')
TXT = os.path.join(DEFAULT, 'img_game.dll.txt')


def sections():
    out = []
    if not os.path.isfile(TXT):
        return out
    for line in open(TXT, encoding='utf-8', errors='replace'):
        m = re.match(r'section \d+ name=(\S*) va=0x([0-9a-f]+) vsize=0x([0-9a-f]+) raw=0x([0-9a-f]+) chars=0x([0-9a-f]+)', line.strip())
        if m:
            out.append(dict(name=m.group(1), va=int(m.group(2), 16), vsize=int(m.group(3), 16),
                            raw=int(m.group(4), 16), chars=int(m.group(5), 16)))
    return out


def describe(rva, secs):
    for s in secs:
        if s['va'] <= rva < s['va'] + max(s['vsize'], 1):
            code = bool(s['chars'] & 0x20000000)
            writable = bool(s['chars'] & 0x80000000)
            return '%s%s%s' % (s['name'] or '?', ' X' if code else '', ' W' if writable else '')
    return 'outside'


def show(rva, length, secs):
    if not os.path.isfile(IMG):
        raise SystemExit('no image dump at %s' % IMG)
    with open(IMG, 'rb') as f:
        f.seek(rva)
        blob = f.read(length)
    hexs = ' '.join('%02x' % b for b in blob)
    text = ''.join(chr(b) if 32 <= b < 127 else '.' for b in blob)
    print('rva 0x%x len=%d [%s]' % (rva, length, describe(rva, secs)))
    print('  %s' % hexs)
    print('  |%s|' % text)


def main():
    secs = sections()
    args = sys.argv[1:]
    if not args or args[0] == '--sections':
        for s in secs:
            print('%-10s va=0x%-8x vsize=0x%-8x raw=0x%-8x chars=0x%x %s'
                  % (s['name'] or '?', s['va'], s['vsize'], s['raw'], s['chars'], describe(s['va'], secs)))
        return 0
    if args[0] == '--list':
        for a in args[1:]:
            rva = int(a, 16)
            with open(IMG, 'rb') as f:
                f.seek(rva)
                blob = f.read(16)
            print('%-12s [%-10s] %s' % (a, describe(rva, secs),
                                        ' '.join('%02x' % b for b in blob)))
        return 0
    rva = int(args[0], 16)
    length = int(args[1], 0) if len(args) > 1 else 32
    show(rva, length, secs)
    return 0


if __name__ == '__main__':
    sys.exit(main())
