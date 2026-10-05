#!/usr/bin/env python3
"""merge-index.py <existing> <new...> — merge Debian Packages index stanzas.

Stanzas are keyed by (Package, Version); a later file's stanza replaces the
same key in place, every other stanza is preserved byte-for-byte, and the
output keeps first-appearance order (existing order first, then new stanzas
in file order). Writes the merged Packages file to stdout.
"""
import re
import sys

SEP = re.compile(rb"\n[ \t]*\n")


def fail(msg):
    print(f"merge-index.py: {msg}", file=sys.stderr)
    raise SystemExit(1)


def read_stanzas(path):
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        fail(f"cannot read {path}: {exc}")
    body = data.strip(b"\n")
    return SEP.split(body) if body else []


def stanza_key(stanza, path):
    pkg = re.search(rb"(?m)^Package:[ \t]*(.*)$", stanza)
    ver = re.search(rb"(?m)^Version:[ \t]*(.*)$", stanza)
    if pkg is None or ver is None:
        fail(f"stanza without Package/Version in {path}")
    return (pkg.group(1), ver.group(1))


def main(argv):
    if len(argv) < 2:
        print("usage: merge-index.py <existing> <new...>", file=sys.stderr)
        return 2
    order = []
    stanzas = {}
    for path in argv[1:]:
        for stanza in read_stanzas(path):
            key = stanza_key(stanza, path)
            if key not in stanzas:
                order.append(key)
            stanzas[key] = stanza
    sys.stdout.buffer.write(b"\n\n".join(stanzas[key] for key in order) + b"\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
