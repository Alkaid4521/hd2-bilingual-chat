"""Generic builder: packs a plaintext Lua addon into an Arsenal-importable mod ZIP.

Usage:
  python build_addon.py --src <lua> --path mods/<ns>/<name> --name "<mod name>"
                        --guid <uuid> --version 1.2.3 --delivery <FolderName> [--dist <dir>]

Patch container layout (identical to working shipped addons; the 200-byte header is copied
byte-for-byte from a verified addon patch, only size / file id / payload length change):
  0x00 u32 0xf0000011   entry kind (Lua script)      0x20 u32 total file size
  0x50 u64 type id 0xa14e8dfa2cd117e2                0x68 u64 file id = MurmurHash64A(path)
  0xa0 u64 payload size + 8                          0xc0 u32 payload size, 0xc4 u32 2
  0xc8..    payload (first line must be "-- HD2-Addon: <path>")
"""
import argparse, hashlib, json, os, shutil, struct, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
TEMPLATE = os.path.join(PROJECT, 'template', 'patch_header.template')
BUNDLE = '9ba626afa44a3aa3'
HEADER = 0xC8

KNOWN = {
    'mods/suzuka/pelican_cover_flag': 0xAA51DD04B3C1E987,
    'mods/chef/armored_overhaul_turret_range': 0xEA7F1B954893E186,
    'mods/chef/armored_overhaul_handling': 0x1F43A5BD3F9E8829,
    'mods/hd2transmog/foundation': 0xD42A76EFA2BEB2E3,
}


def murmur64a(s, seed=0):
    m = 0xc6a4a7935bd1e995
    r = 47
    data = s.encode('ascii')
    h = (seed ^ (len(data) * m)) & 0xFFFFFFFFFFFFFFFF
    n = len(data) // 8
    for i in range(n):
        k = struct.unpack_from('<Q', data, i * 8)[0]
        k = (k * m) & 0xFFFFFFFFFFFFFFFF
        k ^= k >> r
        k = (k * m) & 0xFFFFFFFFFFFFFFFF
        h ^= k
        h = (h * m) & 0xFFFFFFFFFFFFFFFF
    tail = data[n * 8:]
    if tail:
        h ^= int.from_bytes(tail, 'little')
        h = (h * m) & 0xFFFFFFFFFFFFFFFF
    h ^= h >> r
    h = (h * m) & 0xFFFFFFFFFFFFFFFF
    h ^= h >> r
    return h


def build_patch(payload, path):
    template = open(TEMPLATE, 'rb').read()
    assert len(template) >= HEADER, 'template too small'
    hdr = bytearray(template[:HEADER])
    file_id = murmur64a(path)
    struct.pack_into('<I', hdr, 0x20, HEADER + len(payload))
    struct.pack_into('<Q', hdr, 0x68, file_id)
    struct.pack_into('<Q', hdr, 0xA0, len(payload) + 8)
    struct.pack_into('<I', hdr, 0xC0, len(payload))
    skip = set(range(0x20, 0x24)) | set(range(0x68, 0x70)) | set(range(0xA0, 0xA8)) | set(range(0xC0, 0xC4))
    for off in range(HEADER):
        if off not in skip:
            assert hdr[off] == template[off], 'header mismatch at 0x%x' % off
    return bytes(hdr) + payload, file_id


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', required=True)
    ap.add_argument('--path', required=True)
    ap.add_argument('--name', required=True)
    ap.add_argument('--guid', required=True)
    ap.add_argument('--version', required=True)
    ap.add_argument('--delivery', required=True)
    ap.add_argument('--description', default='')
    ap.add_argument('--dist', default=os.path.join(PROJECT, 'dist'))
    args = ap.parse_args()

    src = args.src if os.path.isabs(args.src) else os.path.join(PROJECT, args.src)
    source = open(src, 'rb').read().replace(b'\r\n', b'\n')
    want = '-- HD2-Addon: ' + args.path
    assert source.split(b'\n', 1)[0].decode() == want, 'addon header line must be %r' % want
    for path, want_id in KNOWN.items():
        assert murmur64a(path) == want_id, 'murmur mismatch for ' + path

    patch, file_id = build_patch(source, args.path)
    print('src        : %s' % src)
    print('addon path : %s' % args.path)
    print('file id    : 0x%016x' % file_id)
    print('patch size : %d (payload %d)' % (len(patch), len(source)))
    print('patch sha  : %s' % hashlib.sha256(patch).hexdigest())

    build = os.path.join(args.dist, '%s-%s' % (args.delivery, args.version))
    if os.path.isdir(build):
        shutil.rmtree(build)
    os.makedirs(os.path.join(build, 'Addon'))
    patch_path = os.path.join(build, 'Addon', '%s.patch_0' % BUNDLE)
    open(patch_path, 'wb').write(patch)
    for suffix in ('.stream', '.gpu_resources'):
        open(patch_path + suffix, 'wb').close()

    manifest = {
        'Version': 1,
        'Guid': args.guid,
        'Name': args.name,
        'Description': args.description or ('Lua addon for Helldivers 2. Requires Bingus Shared Loader (API 1).'),
        'Options': [{
            'Name': args.name,
            'Description': args.description or 'Enable with Bingus Shared Loader and deploy.',
            'Include': ['Addon'],
        }],
    }
    open(os.path.join(build, 'manifest.json'), 'w', encoding='utf-8').write(
        json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    open(os.path.join(build, 'README.txt'), 'w', encoding='utf-8', newline='\r\n').write(
        '%s v%s\naddon path: %s\nLog: %%LOCALAPPDATA%%\\CowboyBingus\\Helldivers2\\Logs\\\n'
        % (args.name, args.version, args.path))

    zip_path = os.path.join(args.dist, '%s-%s.zip' % (args.delivery, args.version))
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
        for base_dir, _, names in os.walk(build):
            for name in names:
                full = os.path.join(base_dir, name)
                z.write(full, os.path.relpath(full, build))
    print('mod folder : %s' % build)
    print('mod zip    : %s (%d bytes)' % (zip_path, os.path.getsize(zip_path)))
    print('zip sha256 : %s' % hashlib.sha256(open(zip_path, 'rb').read()).hexdigest())
    return 0


if __name__ == '__main__':
    sys.exit(main())
