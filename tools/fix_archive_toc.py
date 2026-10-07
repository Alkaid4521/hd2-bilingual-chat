"""Repairs a hand-edited HD2 Lua resource archive (patch container).

An archive is: 72-byte header (magic 0xf0000011, resource count @0x08, total size @0x20),
a 32-byte type record, then one 80-byte TOC entry per resource
(`<7Q6I`: name_hash, type, data_offset, x4, resource_len @+56, x2, 16, 16, index).
Each resource is an 8-byte envelope (`u32 source_len`, `u32 kind=2`) plus the source, and
the payload regions are padded to 16 bytes.

Editing the source of the LAST resource by hand changes its length, which must be written to
both the envelope and the TOC entry, and the 16-byte alignment has to be re-established --
otherwise the loader reads only `toc_len` bytes and silently truncates the tail of the source
(observed in-game: the whole addon stops loading, no log, no state files).

Usage: fix_archive_toc.py <archive> [<archive> ...]
"""
import hashlib
import os
import struct
import sys

HEADER = struct.Struct("<III20sQQ24s")
TYPE_RECORD = struct.Struct("<IIQIIII")
TOC_ENTRY = struct.Struct("<7Q6I")
HEADER_SIZE = 72
TYPE_RECORD_SIZE = 32
ENTRY_SIZE = 80


def parse(blob):
    magic, one, count, _pad, total, zero, _pad2 = HEADER.unpack_from(blob, 0)
    if magic != 0xF0000011 or one != 1 or count < 1:
        raise ValueError("unexpected archive header")
    type_record = TYPE_RECORD.unpack_from(blob, HEADER_SIZE)
    entries = []
    for index in range(count):
        at = HEADER_SIZE + TYPE_RECORD_SIZE + ENTRY_SIZE * index
        fields = TOC_ENTRY.unpack_from(blob, at)
        source_len, kind = struct.unpack_from("<II", blob, fields[2])
        entries.append({"at": at, "hash": fields[0], "type": fields[1], "off": fields[2],
                        "len": fields[7], "index": fields[12],
                        "env_len": source_len, "env_kind": kind})
    return {"count": count, "total": total, "type": type_record[2], "entries": entries}


def repair(path):
    blob = bytearray(open(path, "rb").read())
    info = parse(blob)
    print("--- %s (%d bytes) ---" % (path, len(blob)))
    changed = False
    for entry in info["entries"]:
        real = entry["env_len"] + 8
        if entry["len"] != real:
            print("    entry%d TOC len %d -> %d (envelope says %d)"
                  % (entry["index"], entry["len"], real, entry["env_len"]))
            struct.pack_into("<Q", blob, entry["at"] + 56, real)
            changed = True
        if entry["env_kind"] != 2:
            raise ValueError("entry%d is not a plaintext Lua resource" % entry["index"])
    last = info["entries"][-1]
    need = (last["off"] + (last["env_len"] + 8) + 15) & ~15
    if len(blob) < need:
        print("    padded %d -> %d bytes" % (len(blob), need))
        blob.extend(bytes(need - len(blob)))
        changed = True
    if info["total"] != len(blob):
        print("    archive size field %d -> %d" % (info["total"], len(blob)))
        struct.pack_into("<Q", blob, 0x20, len(blob))
        changed = True
    if not changed:
        print("    already consistent, nothing to do")
    else:
        open(path, "wb").write(blob)
    check(path if changed else path)
    return changed


def check(path):
    blob = open(path, "rb").read()
    info = parse(blob)
    assert len(blob) % 16 == 0, "archive length %d is not 16-byte aligned" % len(blob)
    assert info["total"] == len(blob), "size field %d != file size %d" % (info["total"], len(blob))
    for entry in info["entries"]:
        end = entry["off"] + entry["len"]
        assert entry["off"] % 16 == 0, "entry%d data is not 16-byte aligned" % entry["index"]
        assert end <= len(blob), "entry%d overruns the file" % entry["index"]
        source = blob[entry["off"] + 8:end]
        assert len(source) == entry["env_len"], "entry%d source length mismatch" % entry["index"]
        print("    entry%d hash=0x%016x off=%-6d len=%-7d source=%d bytes  first=%r  last=%r"
              % (entry["index"], entry["hash"], entry["off"], entry["len"], len(source),
                 source[:40], source[-24:]))
        if not source.startswith(b"\x1bLJ"):
            assert source.count(b"\x00") == 0, "entry%d plaintext source has NUL padding" % entry["index"]
            assert source.endswith(b"\n"), "entry%d plaintext source is truncated" % entry["index"]
    print("    ok: aligned=%d size_field=%d entries=%d" % (len(blob), info["total"], info["count"]))
    return info


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__.strip().splitlines()[0])
    for target in sys.argv[1:]:
        if not os.path.isfile(target):
            raise SystemExit("missing: %s" % target)
        repair(target)
        print("    sha256=%s" % hashlib.sha256(open(target, "rb").read()).hexdigest()[:32])
