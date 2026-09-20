#!/data/data/com.termux/files/usr/bin/python3
"""Extract the application tarball from a Node SEA `copilot` binary (1.0.85+).

From 1.0.85 the platform package ships only a ~167MB Node SEA and three text
files - no app.js, no prebuilds/*.node. The app is still ordinary JS plus
musl-built addons; it is just carried inside the SEA as a gzipped tar asset that
the bootstrap unpacks at first run:

    let e = ci.getRawAsset("copilot.tgz"), t = Buffer.from(e); await mkdir(...)

Because that payload is gzip, searching the binary for app strings or for
embedded ELF headers finds NOTHING, which makes the binary look monolithic and
unpatchable. It is not. Extracting the tarball restores exactly the pre-1.0.85
layout (app.js + prebuilds/linuxmusl-<arch>/*.node), so the existing
.dynstr-rename / libm / mouse patches all apply unchanged.

We extract it ourselves rather than letting the SEA do it because the SEA cannot
run on bionic at all: it is a musl-DYNAMIC PIE needing /lib/ld-musl-aarch64.so.1.

Usage:
    extract_sea.py <sea-binary> <dest-dir> [--check] [--version VER]

--check exits 0 if dest already holds a usable tree (and matches --version when
given), 1 if extraction is needed. Without --check it extracts, stripping the
archive's leading "package/" component so dest mirrors the old package layout.
"""
import os
import sys
import tarfile
import tempfile
import zlib

ASSET_KEY = b"copilot.tgz"
GZIP_MAGIC = b"\x1f\x8b\x08"
NEEDED = ("app.js", "index.js")
MARKER = ".sea-extracted-version"


def log(msg):
    print("[extract_sea] %s" % msg, file=sys.stderr)


def already_extracted(dest, version=None):
    if not all(os.path.isfile(os.path.join(dest, n)) for n in NEEDED):
        return False
    if not os.path.isdir(os.path.join(dest, "prebuilds")):
        return False
    if version:
        try:
            with open(os.path.join(dest, MARKER)) as fh:
                if fh.read().strip() != version:
                    return False
        except OSError:
            return False
    return True


def gzip_candidates(data):
    """Offsets of plausible gzip streams, best guess first.

    The asset key appears more than once: in the bootstrap JS source, and again
    as the blob's asset name immediately before the payload. So walk the
    occurrences from last to first and take the next gzip magic after each. Fall
    back to every gzip magic in the file, which is slow but cannot miss.
    """
    seen = []
    keys = []
    start = 0
    while True:
        i = data.find(ASSET_KEY, start)
        if i == -1:
            break
        keys.append(i)
        start = i + 1
    for k in reversed(keys):
        g = data.find(GZIP_MAGIC, k, k + 65536)
        if g != -1 and g not in seen:
            seen.append(g)
    for m in _all_magic(data):
        if m not in seen:
            seen.append(m)
    return seen


def _all_magic(data):
    out = []
    start = 0
    while True:
        i = data.find(GZIP_MAGIC, start)
        if i == -1:
            return out
        out.append(i)
        start = i + 1


def inflate(data, offset, out_path):
    """Inflate one gzip stream to out_path. Returns bytes written, or None."""
    dec = zlib.decompressobj(31)
    total = 0
    chunk = 1 << 20
    pos = offset
    with open(out_path, "wb") as fh:
        while pos < len(data):
            try:
                fh.write(dec.decompress(data[pos:pos + chunk]))
            except zlib.error:
                return None
            total = fh.tell()
            pos += chunk
            if dec.eof:
                return total
    return total if dec.eof else None


def tar_is_app(path):
    try:
        with tarfile.open(path) as t:
            names = t.getnames()
    except (tarfile.TarError, OSError):
        return None
    roots = {n.split("/")[0] for n in names}
    if len(roots) != 1:
        return None
    root = roots.pop()
    want = {"%s/%s" % (root, n) for n in NEEDED}
    if not want.issubset(set(names)):
        return None
    return root


def safe_members(t, root):
    """Yield members with the leading root/ stripped, rejecting unsafe paths."""
    prefix = root + "/"
    for m in t.getmembers():
        if not m.name.startswith(prefix):
            continue
        rel = m.name[len(prefix):]
        if not rel or rel.startswith("/") or os.path.isabs(rel):
            continue
        if any(part == ".." for part in rel.split("/")):
            continue
        if m.issym() or m.islnk():
            tgt = m.linkname
            if os.path.isabs(tgt) or any(p == ".." for p in tgt.split("/")):
                continue
        m.name = rel
        yield m


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    sea, dest = argv[1], argv[2]
    check = "--check" in argv
    version = None
    if "--version" in argv:
        version = argv[argv.index("--version") + 1]

    if already_extracted(dest, version):
        if check:
            print("already extracted%s" % (" (%s)" % version if version else ""))
            return 0
        log("already extracted, nothing to do")
        return 0
    if check:
        print("extraction needed")
        return 1

    if not os.path.isfile(sea):
        log("no SEA binary at %s" % sea)
        return 2
    with open(sea, "rb") as fh:
        data = fh.read()

    tmp_dir = os.path.dirname(os.path.abspath(dest)) or "."
    os.makedirs(tmp_dir, exist_ok=True)
    tmp = tempfile.NamedTemporaryFile(prefix=".sea-tar-", dir=tmp_dir, delete=False)
    tmp.close()
    try:
        root = None
        for off in gzip_candidates(data):
            n = inflate(data, off, tmp.name)
            if not n:
                continue
            root = tar_is_app(tmp.name)
            if root:
                log("found app tarball at offset %d (%d bytes inflated)" % (off, n))
                break
        if not root:
            log("could not find an app tarball inside %s" % sea)
            log("upstream may have changed the SEA asset; nothing was written")
            return 2
        os.makedirs(dest, exist_ok=True)
        with tarfile.open(tmp.name) as t:
            members = safe_members(t, root)
            try:
                # Python 3.12+ wants an explicit filter; 3.14 makes it mandatory.
                # We already reject unsafe paths and links above; "data" also
                # drops ownership and special files, which is right for an
                # archive we did not create.
                t.extractall(dest, members=members, filter="data")
            except TypeError:
                t.extractall(dest, members=members)
        if version:
            with open(os.path.join(dest, MARKER), "w") as fh:
                fh.write(version + "\n")
        log("extracted to %s" % dest)
        return 0
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main(sys.argv))
