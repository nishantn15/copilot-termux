#!/usr/bin/env python3
"""Strip GLIBC symbol versioning and DT_VERNEED/DT_VERSYM entries from a
glibc-built ELF shared object so it can dlopen on Termux/Android bionic.

Steps performed in place:
  1. Zero out every entry in the .gnu.version section (so each dynsym is "unversioned").
  2. Replace DT_VERNEED, DT_VERNEEDNUM, DT_VERSYM with DT_NULL in the .dynamic section.
"""
import sys, struct

DT_NULL       = 0
DT_VERSYM     = 0x6ffffff0
DT_VERNEED    = 0x6ffffffe
DT_VERNEEDNUM = 0x6fffffff
TARGET_TAGS = {DT_VERSYM, DT_VERNEED, DT_VERNEEDNUM}

def main(path):
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    from elftools.elf.elffile import ELFFile
    import io
    elf = ELFFile(io.BytesIO(bytes(data)))
    assert elf.elfclass == 64, "Only 64-bit ELF supported"
    endian = '<' if elf.little_endian else '>'

    # 1. Zero out .gnu.version (the version-symbol table).
    versym = elf.get_section_by_name('.gnu.version')
    if versym is None:
        print('no .gnu.version section — nothing to strip')
    else:
        off = versym['sh_offset']
        size = versym['sh_size']
        for i in range(size):
            data[off + i] = 0
        print(f'zeroed .gnu.version: {size} bytes at {off:#x}')

    # 2. Find .dynamic section and patch out version tags.
    dyn = elf.get_section_by_name('.dynamic')
    if dyn is None:
        sys.exit('no .dynamic section')
    off = dyn['sh_offset']
    entsize = dyn['sh_entsize'] or 16  # 8 bytes tag + 8 bytes val on aarch64
    nentries = dyn['sh_size'] // entsize
    patched = 0
    for i in range(nentries):
        eoff = off + i * entsize
        tag = struct.unpack_from(endian + 'Q', data, eoff)[0]
        if tag in TARGET_TAGS:
            struct.pack_into(endian + 'QQ', data, eoff, DT_NULL, 0)
            patched += 1
    print(f'patched {patched} dynamic entries (DT_VERSYM/VERNEED/VERNEEDNUM → DT_NULL)')

    with open(path, 'wb') as f:
        f.write(data)
    print(f'wrote {path}')

if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: strip_verneed.py <path-to-.node>')
    main(sys.argv[1])
