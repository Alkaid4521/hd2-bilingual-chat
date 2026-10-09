"""Find where the chat body property key (0x7518C954) is used inside the dumped game.dll image.

The property table layout we rely on (key at entry+0, 0x18 byte stride, count byte at table+0x158)
is only believable if the game really compares that key against table entries -- this prints the
code offsets that mention it, so the next in-game probe can be judged against something real.

usage: python tools/scan_key.py [0xKEY] [--near 0xRVA]
"""
import os
import struct
import sys

IMG = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'HD2BilingualChat', 'img_game.dll.bin')


def main():
    key = 0x7518C954
    near = None
    args = sys.argv[1:]
    skip = False
    for a in args:
        if skip:
            skip = False
            continue
        if a == '--near':
            near = int(args[args.index(a) + 1], 16)
            skip = True
        elif a.startswith('0x'):
            key = int(a, 16)
    if not os.path.isfile(IMG):
        raise SystemExit('no image at %s' % IMG)
    blob = open(IMG, 'rb').read()
    pattern = struct.pack('<I', key)
    hits = []
    at = blob.find(pattern)
    while at != -1 and len(hits) < 200:
        hits.append(at)
        at = blob.find(pattern, at + 1)
    print('image %d bytes ; key %#x found %d time(s)' % (len(blob), key, len(hits)))
    for rva in hits:
        marker = ''
        if near is not None:
            marker = ' (%.1f KB from --near)' % ((rva - near) / 1024.0)
        print('\nrva 0x%x%s' % (rva, marker))
        start = max(0, rva - 16)
        chunk = blob[start:start + 48]
        print('  %s' % ' '.join('%02x' % b for b in chunk))
    return 0


if __name__ == '__main__':
    sys.exit(main())
