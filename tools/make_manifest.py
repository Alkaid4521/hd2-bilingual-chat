"""Regenerate MANIFEST.sha256 over everything git tracks.

  python tools/make_manifest.py

The manifest is a release-time snapshot of the tree: run it right before committing a release and
commit the result.  It lists itself's own absence on purpose (a manifest cannot hash itself).
"""
import hashlib
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'MANIFEST.sha256')


def main():
    names = subprocess.run(['git', 'ls-files'], cwd=ROOT, capture_output=True, text=True, check=True)
    files = [n for n in names.stdout.splitlines()
             if n and n != 'MANIFEST.sha256' and os.path.isfile(os.path.join(ROOT, n))]
    lines = []
    for name in sorted(files):
        with open(os.path.join(ROOT, name), 'rb') as handle:
            lines.append('%s  %s' % (hashlib.sha256(handle.read()).hexdigest(), name))
    with open(OUT, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write('\n'.join(lines) + '\n')
    print('%s: %d file(s)' % (OUT, len(lines)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
