#!/usr/bin/env python3
"""In-place .dynstr symbol renaming for scoping a module's libc imports to a shim.

Renames UND symbol names inside .dynstr by overwriting the bytes in place. The
replacement MUST be the same length as the original so no offsets shift. We just
change the first character's case, e.g.

    getaddrinfo            -> Getaddrinfo
    pthread_mutexattr_init -> Pthread_mutexattr_init

The renamed imports then resolve against a small translator .so that is
add-needed to this module (ordered before libc.so), so ONLY this module's calls
are translated. Everything else in the process keeps calling bionic directly.

Usage:  rename_imports.py <elf> <sym> [<sym> ...]
        rename_imports.py --check <elf> <sym> [<sym> ...]
"""
import sys, mmap

from elftools.elf.elffile import ELFFile


def collect(path, names):
    """Return {name: [(abs_file_offset, bytes)]} for UND dynsyms matching names."""
    want = set(names)
    hits = {}
    with open(path, 'rb') as f:
        elf = ELFFile(f)
        dynsym = elf.get_section_by_name('.dynsym')
        dynstr = elf.get_section_by_name('.dynstr')
        if dynsym is None or dynstr is None:
            raise SystemExit('no .dynsym/.dynstr in %s' % path)
        strbase = dynstr['sh_offset']
        for i, sym in enumerate(dynsym.iter_symbols()):
            nm = sym.name
            if nm not in want:
                continue
            # st_name is the byte offset into .dynstr
            st_name = sym['st_name']
            hits.setdefault(nm, []).append((strbase + st_name, i))
    return hits


def main():
    args = sys.argv[1:]
    check = False
    if args and args[0] == '--check':
        check = True
        args = args[1:]
    if len(args) < 2:
        raise SystemExit(__doc__)
    path, names = args[0], args[1:]

    hits = collect(path, names)
    missing = [n for n in names if n not in hits]

    for n in names:
        if n in hits:
            for off, idx in hits[n]:
                print('  found %-26s dynsym#%-4d .dynstr@0x%x' % (n, idx, off))
    for n in missing:
        print('  MISSING %s' % n)

    if check:
        return 0 if not missing else 1
    if missing:
        raise SystemExit('refusing to patch: %d symbol(s) not found' % len(missing))

    with open(path, 'r+b') as f:
        mm = mmap.mmap(f.fileno(), 0)
        try:
            for n in names:
                new = (n[0].upper() + n[1:]).encode()
                old = n.encode()
                assert len(new) == len(old), (n, new)
                for off, idx in hits[n]:
                    cur = mm[off:off + len(old) + 1]
                    if cur == new + b'\0':
                        print('  already renamed: %s' % n)
                        continue
                    if cur != old + b'\0':
                        raise SystemExit('unexpected bytes at 0x%x for %s: %r'
                                         % (off, n, cur))
                    mm[off:off + len(new)] = new
                    print('  renamed %s -> %s at 0x%x' % (n, new.decode(), off))
            mm.flush()
        finally:
            mm.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
