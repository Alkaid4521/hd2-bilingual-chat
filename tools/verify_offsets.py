"""Check every offset/fingerprint baked into tools/add_inbound.py against the dumped game image.

Run this before packaging: it reads the memory image the addon dumped from its own process
(%LOCALAPPDATA%\\HD2BilingualChat\\img_game.dll.bin, file offset == RVA) and fails loudly when a
constant no longer matches the code, so a wrong address can never be shipped twice.

usage: python tools/verify_offsets.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATCHER = os.path.join(ROOT, 'tools', 'add_inbound.py')
IMG = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'HD2BilingualChat', 'img_game.dll.bin')

# rva constant name in the patcher -> what the bytes at that rva must be
EXPECT = {
    'GUARD_RVA': [0x4c, 0x8d, 0x83, 0xb4, 0, 0, 0, 0xba, 0x54, 0xc9, 0x18, 0x75, 0x48, 0x8b, 0xce, 0xe8],
    'SETTER_RVA': [0x40, 0x53, 0x48, 0x83, 0xec, 0x20, 0x48, 0x8b, 0xd9, 0x48, 0x81, 0xc1, 0x10, 0x01, 0x00, 0x00],
    'STRING_SETTER_RVA': [0x48, 0x89, 0x5c, 0x24, 0x18, 0x57, 0x48, 0x83, 0xec, 0x40, 0x44, 0x0f, 0xb6, 0x99, 0x58, 0x01],
    'LAYOUT_DIRECT_RVA': [0x48, 0x89, 0x54, 0x24, 0x10, 0x53, 0x56, 0x48, 0x83, 0xec, 0x38, 0x48, 0x8b, 0xda, 0x48, 0x8b],
}


def main():
    if not os.path.isfile(IMG):
        raise SystemExit('no image dump at %s (start the game with HD2BC_DUMP=1)' % IMG)
    src = open(PATCHER, encoding='utf-8').read()
    img = open(IMG, 'rb').read()
    bad = 0

    rvas = {}
    for name in EXPECT:
        m = re.search(r'local %s = (0x[0-9A-Fa-f]+)' % name, src)
        if not m:
            print('FAIL %-20s not found in %s' % (name, PATCHER))
            bad += 1
            continue
        rvas[name] = int(m.group(1), 16)

    guard_literal = re.search(r'GUARD_BYTES = string\.char\(([^)]*)\)', src)
    if guard_literal:
        values = [int(v, 0) for v in re.findall(r'0x[0-9A-Fa-f]+|\d+', guard_literal.group(1))]
        if values != EXPECT['GUARD_RVA']:
            print('FAIL GUARD_BYTES literal != the sequence tools/verify_offsets.py expects')
            print('     literal %s' % [hex(v) for v in values])
            bad += 1
        else:
            print('ok   GUARD_BYTES literal matches the expected sequence')
    else:
        print('FAIL GUARD_BYTES literal not found')
        bad += 1

    for name, want in EXPECT.items():
        rva = rvas.get(name)
        if rva is None:
            continue
        got = list(img[rva:rva + len(want)])
        if got == want:
            print('ok   %-20s rva=0x%-8x %s' % (name, rva, ' '.join('%02x' % b for b in got)))
        else:
            print('FAIL %-20s rva=0x%-8x got  %s' % (name, rva, ' '.join('%02x' % b for b in got)))
            print('     %-20s want %s' % ('', ' '.join('%02x' % b for b in want)))
            bad += 1

    print('\n%s (%d problem(s))' % ('ALL OFFSETS VERIFIED' if bad == 0 else 'MISMATCH', bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
