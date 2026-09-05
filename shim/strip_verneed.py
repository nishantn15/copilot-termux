#!/data/data/com.termux/files/usr/bin/python3
"""Strip GLIBC symbol versioning and DT_VERNEED/DT_VERSYM entries from a
glibc-built ELF shared object so it can dlopen on Termux/Android bionic.

Steps performed in place:
  1. Zero out every entry in the .gnu.version section (so each dynsym is "unversioned").
  2. Remove DT_VERNEED, DT_VERNEEDNUM, DT_VERSYM from .dynamic by COMPACTING the
     array (keep all other tags in order, shift them up, pad the freed tail with
     DT_NULL entries). The earlier approach overwrote the version tags with
     DT_NULL *in place*, which inserted a DT_NULL in the MIDDLE of .dynamic —
     bionic's linker stops parsing at the first DT_NULL, silently dropping every
     tag after it (e.g. DT_RELACOUNT, and on other layouts potentially
     DT_RELA/DT_JMPREL/DT_INIT_ARRAY). That truncation manifested as a runtime
     NULL-pointer crash on the TLS path in @github/copilot 1.0.61 even though
     the module dlopen'd and exported symbols fine. Compacting keeps the single
     terminator at the very end where it belongs.
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

    # 2. Find .dynamic section and COMPACT out the version tags.
    dyn = elf.get_section_by_name('.dynamic')
    if dyn is None:
        sys.exit('no .dynamic section')
    off = dyn['sh_offset']
    entsize = dyn['sh_entsize'] or 16  # 8 bytes tag + 8 bytes val on aarch64
    nentries = dyn['sh_size'] // entsize

    # Read all (tag,val) pairs.
    entries = []
    for i in range(nentries):
        eoff = off + i * entsize
        tag, val = struct.unpack_from(endian + 'QQ', data, eoff)
        entries.append((tag, val))

    # Keep everything except the version tags, preserving order. Stop copying at
    # the original terminating DT_NULL (don't carry trailing garbage forward).
    kept = []
    for tag, val in entries:
        if tag in TARGET_TAGS:
            continue
        kept.append((tag, val))
        if tag == DT_NULL:
            break  # original terminator reached; rest is padding

    removed = nentries - len([1 for t, _ in entries if t not in TARGET_TAGS])
    # Rewrite: kept entries first, then pad the remainder of the section with
    # DT_NULL so the terminator(s) sit only at the tail.
    for i in range(nentries):
        eoff = off + i * entsize
        if i < len(kept):
            struct.pack_into(endian + 'QQ', data, eoff, kept[i][0], kept[i][1])
        else:
            struct.pack_into(endian + 'QQ', data, eoff, DT_NULL, 0)
    print(f'compacted .dynamic: removed {removed} version tag(s), '
          f'{len(kept)} entries kept, padded to {nentries} with DT_NULL at tail')

    with open(path, 'wb') as f:
        f.write(data)
    print(f'wrote {path}')

if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: strip_verneed.py <path-to-.node>')
    main(sys.argv[1])
