"""Put helper/hd2bc_helper.js inside the mod source, or check that both copies agree.

  python tools/embed_helper.py            write the script into src/bilingual_chat.lua
  python tools/embed_helper.py --check    fail if the two copies differ (used by install_live)

A patch container carries exactly one Lua resource, so the helper script has to live inside the
Lua as a long string.  This is the only thing allowed to write that string: editing it by hand
would drift from helper/hd2bc_helper.js without anyone noticing.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, 'src', 'bilingual_chat.lua')
SCRIPT = os.path.join(ROOT, 'helper', 'hd2bc_helper.js')
OPEN = 'local HELPER_JS = [==['
CLOSE = ']==]'


def sync(check=False):
    """write the helper script into the source, or report whether both copies agree"""
    js = open(SCRIPT, encoding='utf-8', newline='').read().replace('\r\n', '\n')
    assert CLOSE not in js, 'the helper script contains the long string terminator'
    text = open(SOURCE, encoding='utf-8', newline='').read()
    start = text.find(OPEN)
    assert start >= 0, 'HELPER_JS marker not found in ' + SOURCE
    at = start + len(OPEN)
    end = text.find(CLOSE, at)
    assert end >= 0, 'HELPER_JS terminator not found in ' + SOURCE
    have = text[at:end]
    if have == js:
        print('HELPER_JS in sync: %d bytes' % len(js))
        return 0
    if check:
        print('HELPER_JS OUT OF SYNC: source has %d bytes, %s has %d bytes'
              % (len(have), SCRIPT, len(js)))
        return 1
    open(SOURCE, 'w', encoding='utf-8', newline='').write(text[:at] + js + text[end:])
    print('HELPER_JS written: %d bytes' % len(js))
    return 0


def main():
    return sync(check='--check' in sys.argv)


if __name__ == '__main__':
    sys.exit(main())
