#!/usr/bin/env python3
"""Patch @github/copilot's minified JS so process.platform === 'android' no longer
throws "Unsupported platform". The native-binding loader has a libc-variant
helper that switches on process.platform with cases for win32/darwin/linux only
and `default: throw new Error(...)`. We rewrite that throw to return a benign
fallback string. The primary lookup path (prebuilds/<platform>-<arch>/) hits
before the helper's value is consumed, so the return value is unused — we hard-
code `linux-arm64-gnu` rather than try to template-interpolate variables whose
names differ between index.js and app.js.

Anchor: the unique tail r'default:throw new Error(`Unsupported platform: ...`)'.
This is more stable than anchoring on the preceding `case"linux"` arm because
upstream is free to reorder/rename cases but the throw text is user-facing and
won't be reworded silently.

Returns exit code 0 on success (patched or already patched), 2 if the throw
marker is present but the regex didn't match (signaling upstream changed the
shape — wrapper should surface this loudly).
"""
import re, sys, pathlib

# Anchor only on the throw template — independent of case ordering and var names.
# Captures the platform and arch var names so error messages can be informative.
THROW_PAT = re.compile(
    rb'default:throw new Error\(`Unsupported platform: \$\{(\w+)\}/\$\{(\w+)\}`\)'
)
# The replacement returns a static fallback. The function's return value is
# only consumed by a fallback file lookup that we never hit because the
# primary `prebuilds/<plat>-<arch>/` path matches first.
REPLACEMENT = b'default:return"linux-arm64-gnu"'

MARKER = b'Unsupported platform: '

def patch(path: pathlib.Path) -> tuple[int, str]:
    """Return (exit_code, message). 0=patched/already-patched, 2=marker present but pattern unmatched."""
    data = path.read_bytes()
    if MARKER not in data:
        return 0, f'{path.name}: already patched or different version (no marker)'
    m = THROW_PAT.search(data)
    if not m:
        return 2, (
            f'{path.name}: MARKER PRESENT BUT PATTERN UNMATCHED — upstream JS '
            f'shape changed. The throw still exists but our regex anchor no '
            f'longer matches. Inspect ~80 bytes around the marker and update '
            f'THROW_PAT in patch_js.py.'
        )
    new_data = THROW_PAT.sub(REPLACEMENT, data, count=1)
    if new_data == data:
        return 0, f'{path.name}: no change'
    bak = path.with_suffix(path.suffix + '.preandroid')
    if not bak.exists():
        bak.write_bytes(data)
    path.write_bytes(new_data)
    return 0, f'PATCHED {path.name} ({len(data)} → {len(new_data)} bytes, backup at {bak.name})'

def main():
    pkg = pathlib.Path('/data/data/com.termux/files/home/.npm-global/lib/node_modules/@github/copilot')
    if len(sys.argv) > 1:
        pkg = pathlib.Path(sys.argv[1])
    worst = 0
    for t in [pkg / 'index.js', pkg / 'app.js']:
        if not t.exists():
            print(f'skip {t} (missing)')
            continue
        rc, msg = patch(t)
        print(msg, file=sys.stderr if rc else sys.stdout)
        worst = max(worst, rc)
    sys.exit(worst)

if __name__ == '__main__':
    main()
