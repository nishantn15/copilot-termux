# GitHub Copilot CLI on Termux (Android)

Run **GitHub Copilot CLI** (`@github/copilot`) natively on Android via [Termux](https://termux.dev) — no root required.

## The Problem

The official `@github/copilot` npm package doesn't support Android. Multiple things break, and they keep moving as upstream restructures:

1. **node-pty** — no `android-arm64` prebuild ships; npm update wipes any manually-placed binary
2. **Platform check** — `@openai/codex` dependency declares `os:linux`; Termux reports `android`
3. **Native runtime (v1.0.46+)** — Rust napi-rs binding has no Android target in its build matrix; on launch it throws "Cannot find native binding"
4. **JS platform allowlist (v1.0.48+)** — `index.js`/`app.js` libc-variant helper throws `Unsupported platform: android/arm64` before the native binding is even looked up

### Layout shifts between versions

| Version | Where runtime binding lives             | libc variant shipped | JS throws on android? |
|---------|------------------------------------------|----------------------|------------------------|
| 1.0.45  | (no native binding — pure JS)            | n/a                  | no                     |
| 1.0.46–1.0.47 | `native/runtime/runtime.<plat>-<libc>.node` | gnu **+ musl**       | no                     |
| 1.0.48+ | `prebuilds/<plat>/runtime.node`          | **gnu only**         | yes                    |

## The Solution

This repo provides a single `setup.sh` that:

- **Fresh install** (`./setup.sh`): Installs all dependencies, builds native modules from source, patches the runtime, installs a self-healing wrapper
- **Updates** (`./setup.sh --update`): Backs up binaries → npm update → restores binaries → re-patches runtime

### Patches Applied

| Issue | Fix |
|-------|-----|
| Missing `prebuilds/android-arm64/pty.node` | Build from source on first install; backup/restore on updates |
| `os:linux` platform check rejects `android` | `npm update --force` bypasses validation |
| 1.0.46/47 `native/runtime/` no Android target | Copy musl variant → `runtime.android-arm64.node` + `patchelf --add-needed libm.so` |
| 1.0.48+ `prebuilds/linux-arm64/runtime.node` is glibc-only | Copy to `prebuilds/android-arm64/runtime.node`, strip GLIBC symbol versions (`strip_verneed.py`), drop `libgcc_s`/`libpthread`/`libdl` NEEDED, rename `libc.so.6→libc.so`, `libm.so.6→libm.so` |
| 1.0.48+ JS throws "Unsupported platform" | `patch_js.py` rewrites the `default:throw` in `index.js`+`app.js` to fall through |
| musl/glibc symbols missing on bionic | LD_PRELOAD shim exports `bcmp`, `__xpg_strerror_r`, `__errno_location`, `__xstat64`/`__lxstat64`/`__fxstat64`/`__fxstatat64`, `__ctype_b_loc`, `__assert_fail`, and statically-linked `_Unwind_*` (from Termux `libunwind.a`) |
| `pthread_mutexattr_t`/`pthread_condattr_t` are 8 bytes on bionic, 4 on musl | `.dynstr` import rename + `libpthread_xlate.so`, applied to **every** `*.node` (`runtime.node` and `cli-native.node`) |
| No CA trust store on Android, so all HTTPS fails at client-build time | Wrapper exports `SSL_CERT_FILE=$PREFIX/etc/tls/cert.pem` |
| npm update wipes all patches | Self-healing wrapper at `~/.local/bin/copilot` re-applies on launch |

## Prerequisites

- [Termux](https://f-droid.org/en/packages/com.termux/) (F-Droid version recommended)
- [Termux:API](https://f-droid.org/en/packages/com.termux.api/) (for clipboard support)
- ARM64 device (aarch64) — x86_64 and armv7l are detected but untested

## Installation

```bash
# Clone this repo
git clone https://github.com/nishantn15/copilot-termux.git
cd copilot-termux

# Run the full setup (takes 5-15 min for native builds)
chmod +x setup.sh
./setup.sh

# Authenticate with GitHub
copilot auth
```

The script will:
1. Install Node.js, clang, make, python, patchelf, and other build deps
2. Install `@github/copilot` globally
3. Build node-pty, keytar, and sharp from source
4. Set up clipboard wrapper using Termux API
5. Create the bionic compatibility shim
6. Patch the native runtime for Android
7. Install the self-healing launcher wrapper
8. Verify everything works

## Updating

```bash
cd ~/copilot-termux  # or wherever you cloned
./setup.sh --update
```

This will:
1. Check if a newer version is available (skips if already latest)
2. Back up `pty.node` to `~/.copilot-termux-backups/`
3. Run `npm update -g @github/copilot --force`
4. Restore `pty.node` to `prebuilds/android-arm64/`
5. Re-patch `native/runtime/` with patchelf
6. Verify the new version launches

## How It Works

### Architecture

```
~/.local/bin/copilot          ← Self-healing wrapper (first in PATH)
    │
    ├── Sets LD_PRELOAD → ~/.copilot-versions/shim/libbionic_shim.so
    │                       (exports bcmp, __xpg_strerror_r, __errno_location)
    │
    ├── Self-heals runtime.android-arm64.node if wiped by npm
    │
    └── exec node ~/.npm-global/lib/node_modules/@github/copilot/npm-loader.js
```

### The Bionic Shim

The Rust napi-rs binding is compiled against musl libc, which uses symbols that Android's bionic libc either doesn't export or exports under different names:

- `bcmp` → forwarded to `memcmp` (deprecated POSIX, bionic doesn't export)
- `__xpg_strerror_r` → forwarded to `strerror_r` (musl/glibc alias)
- `__errno_location` → forwarded to `__errno` (bionic's equivalent)

### The patchelf Fix

The musl `.node` binary expects `libm` to be part of libc (as musl bundles it). On bionic, `libm.so` is a separate shared library. Running `patchelf --add-needed libm.so` on the binary makes the dynamic linker load `libm.so` alongside it.

## File Layout

```
~/.npm-global/lib/node_modules/@github/copilot/
├── prebuilds/android-arm64/pty.node       ← Built by setup, restored on update
├── native/runtime/
│   ├── runtime.linux-arm64-musl.node      ← Ships with package (source)
│   └── runtime.android-arm64.node         ← Patched copy (created by setup/wrapper)
└── ...

~/.copilot-versions/shim/
├── bionic_shim.c                          ← Source for LD_PRELOAD shim
└── libbionic_shim.so                      ← Compiled shim

~/.copilot-termux-backups/
└── pty.node.android-arm64                 ← Permanent backup (survives updates)

~/.local/bin/copilot                       ← Self-healing launcher wrapper
```

## Troubleshooting

### "Cannot find native binding"
The native runtime patch wasn't applied. Run:
```bash
./setup.sh --update
```
Or manually:
```bash
COPILOT_PKG="$HOME/.npm-global/lib/node_modules/@github/copilot"
cp "$COPILOT_PKG/native/runtime/runtime.linux-arm64-musl.node" \
   "$COPILOT_PKG/native/runtime/runtime.android-arm64.node"
patchelf --add-needed libm.so "$COPILOT_PKG/native/runtime/runtime.android-arm64.node"
```

### "Authentication token found but could not be validated"
Missing CA trust store, not a bad token. Quick check:
```bash
pkg install ca-certificates
export SSL_CERT_FILE=$PREFIX/etc/tls/cert.pem
```
If that fixes it, your wrapper is out of date - re-run `./setup.sh --update`.
Full explanation below under "SOLVED: auth failed (no fetch)".

### Segfault the moment the TUI paints
A separate bug from the auth one. `cli-native.node` needs the same
`pthread_*attr_t` width patch as `runtime.node`. Check:
```bash
readelf -d ~/.npm-global/lib/node_modules/@github/copilot-linuxmusl-arm64/\
prebuilds/linuxmusl-arm64/cli-native.node | grep libpthread_xlate
```
No output means unpatched - re-run `./setup.sh --update`. See "SOLVED: the TUI
segfault" below.

### "Ignoring unknown top-level key(s) in user settings file"
Cosmetic, not a Termux bug - your `~/.copilot/settings.json` has a key the
runtime does not recognise. Two common causes:

- **A dotted key that should be nested.** `"builtInAgents.rubberDuck": true` is
  ignored; the reader is `settings.builtInAgents?.rubberDuck`, so it has to be
  `"builtInAgents": { "rubberDuck": true }`.
- **A key that has since been retired.** The rubber-duck keys in particular are
  legacy: `rubber-duck` is now an ordinary built-in agent gated by a feature
  flag, and the CLI ships a `migrateLegacyRubberDuckSettingsOnDisk` routine that
  drops them. Delete rather than nest them - with no `builtInAgents` key at all,
  `rubber-duck` still appears in the agent list.

Do **not** grep `app.js` to decide whether a key is valid - `renderMarkdown` has
zero hits there and is perfectly valid. Ask the Rust runtime for the real list
(85 keys as of 1.0.80) and diff your file against it:

```bash
cat > "$PREFIX/tmp/val.cjs" <<'EOF'
const rt = process.env.HOME +
  "/.npm-global/lib/node_modules/@github/copilot-linuxmusl-arm64" +
  "/prebuilds/linuxmusl-arm64/runtime.node";
const known = new Set(JSON.parse(require(rt).userSettingsKeysJson()));
known.add("$schema");
const s = JSON.parse(require("fs")
  .readFileSync(process.env.HOME + "/.copilot/settings.json", "utf8"));
const bad = Object.keys(s).filter(k => !known.has(k));
console.log("keys=" + Object.keys(s).length +
            "  unknown=" + (bad.length ? bad.join(",") : "NONE"));
EOF
env SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem" \
    LD_PRELOAD="$HOME/.copilot-versions/shim/libbionic_shim.so" \
    node "$PREFIX/tmp/val.cjs"
```

It must be `.cjs` (or `node -e`) - as ESM you get `require is not defined`. The
two env vars are needed because loading `runtime.node` on bionic pulls in the
shim and the CA bundle.

Note only **top-level** keys are checked, so a typo nested inside a valid object
is silently ignored with no warning at all.

**Gotcha:** `XDG_CONFIG_HOME` does *not* relocate Copilot's config dir, so you
cannot A/B a settings change by pointing it at a scratch directory - it keeps
reading `~/.copilot/settings.json`. Back that file up and edit it in place.

### Swiping scrolls nothing - it cycles through prompt history instead

Symptom: in the interactive TUI a finger swipe does not scroll the transcript.
Instead the prompt box cycles through previously typed prompts, as if you were
pressing Up and Down.

That is exactly what is happening. Termux's terminal maps a fixed set of DECSET
codes, and its mouse tracking is driven by the 1000/1002 bits. When the
server-side `TIMELINE_TOUCHUP` feature flag is on, copilot enables "any-event"
tracking as mode **1003 alone**:

```
MOUSE_ANY: "\x1B[?1003h\x1B[?1006h"
```

Termux does not map 1003, so tracking never turns on, and in the alternate
screen Termux converts vertical swipes into `DPAD_UP`/`DPAD_DOWN` key presses.
Those arrows land in the prompt box, which owns Up/Down for history.

Confirmed on a real device: after the patch, swiping scrolls the transcript. So
Termux does activate tracking on 1002 and does not on 1003.

`shim/patch_mouse.py` adds mode 1002 alongside 1003. They are independent bits,
so terminals that honour 1003 lose nothing, and copilot's own `MOUSE_OFF`
already sends `1002l`, so the terminal is not left reporting mouse events after
exit. The wrapper re-applies it on every launch, because npm restores a pristine
`app.js` on each upgrade.

Verify what copilot actually asks for:

```bash
python3 ~/.copilot-versions/pty_tui_test.py --wait 18 --raw "$PREFIX/tmp/c.raw"
python3 -c 'import os,sys
b=open(os.environ["PREFIX"]+"/tmp/c.raw","rb").read()
for n,q in [("1002h",b"\x1b[?1002h"),("1003h",b"\x1b[?1003h"),("1002l",b"\x1b[?1002l")]:
    print(n, b.count(q))'
```

`1002h 1` means the patch is live. (Use `$PREFIX/tmp`, not `/tmp` - `/tmp` is not
writable on Termux. And `command grep` if your shell aliases `grep`.)

Trade-off: with tracking active the terminal forwards taps to copilot, so
Termux's own long-press text selection may behave differently inside copilot. To
turn mouse support off entirely instead, put `"mouse": false` in
`~/.copilot/settings.json` - but note that returns you to the arrow-key
behaviour above.

**Keyboard scrolling works regardless** (no patch needed). The transcript pane
binds:

| Keys | Action |
|---|---|
| `PageUp` / `PageDown` | scroll one screen |
| `Ctrl+U` / `Ctrl+D` | scroll half a screen |
| `Home` / `End` (or `g` / `G`) | jump to top / bottom |
| `Up` / `Down`, `Ctrl+P` / `Ctrl+N`, `k` / `j` | one line |

On a touch keyboard, add the keys you need to Termux's extra-keys row in
`~/.termux/termux.properties`, then run `termux-reload-settings`:

```
extra-keys = [['ESC','/','-','HOME','UP','END','PGUP'], \
              ['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN']]
```

### "The bash environment is broken" / `libm.so: invalid ELF header`

Every shell command copilot runs fails, and it reports something like *"the bash
environment is broken (a corrupted libm.so)"*. Nothing is corrupted. This happens
when copilot is launched from a shell running under **glibc-runner** (`grun`),
which puts `$PREFIX/glibc/bin` first on `PATH`:

```bash
command -v bash        # /data/data/com.termux/files/usr/glibc/bin/bash  <- glibc
echo "$RUNNING_IN_GLIBC_RUNNER"
```

Our `LD_PRELOAD` is a **bionic** shim that needs `libm.so`. A glibc binary
resolves that from `$PREFIX/glibc/lib/libm.so`, which is a GNU ld script rather
than an ELF object, so the loader rejects it. The two libcs cannot be mixed in
one process.

The wrapper now strips `$GLIBC_PREFIX` entries from `PATH` and `LD_LIBRARY_PATH`
before exec, so children always get the Termux-native tools. If you hit this with
an older wrapper, either re-run `./setup.sh --update` or launch copilot from a
plain Termux shell.

### `bad interpreter: /usr/bin/env` when running `copilot`

Termux has no `/usr` at all, so a `#!/usr/bin/env bash` shebang fails with
`bad interpreter: No such file or directory` - and confusingly, running it via
`env` reports the *script* as missing rather than the interpreter. Every script
here therefore uses an absolute `$PREFIX` shebang
(`#!/data/data/com.termux/files/usr/bin/bash`), which is what `termux-fix-shebang`
does. If you copy these scripts somewhere with a different Termux prefix (a
secondary Android user, for instance), rewrite line 1 to match `$PREFIX`.

### "Failed to load native module: pty.node"
The prebuild was wiped. Run `./setup.sh --update` to restore from backup.

### npm errors about platform/os
Normal — `--force` flag handles this. The `@openai/codex` dependency declares `os:linux` but works fine on Termux.

### Wrapper not found / copilot not in PATH
```bash
export PATH="$HOME/.local/bin:$PATH"  # Add to ~/.bashrc
```

## Tested On

- Termux 0.118+ on Android 13/14/15
- ARM64 (aarch64) devices
- Node.js v24+/v25+
- `@github/copilot` 1.0.45 → **1.0.83** (1.0.46+ requires Termux `clang`, `patchelf`, `python3`, `pyelftools`, `ca-certificates`, and `libunwind.a` from `ndk-sysroot`)

## License

MIT

## Usage

Once the installation is complete, you can start the GitHub Copilot CLI by running:

```bash
copilot
```

## SOLVED: "auth failed" (no fetch) (fixed 2026-08-05)

These two failures look like one bug because they usually appear together, but
they are **independent** and were fixed separately. Verified by isolating each:

| symptom | cause | fixed by |
|---|---|---|
| auth fails, `builder error`, MCP over HTTPS refuses | no CA trust store on Android | `SSL_CERT_FILE` in the wrapper |
| SIGSEGV as soon as the TUI paints | `cli-native.node` unpatched (`pthread_*attr_t` 8-vs-4) | `.dynstr` rename + `libpthread_xlate.so` |

Proof they are independent, on 1.0.78 under a pty that answers terminal
capability queries so the TUI really renders:

| trust store | `cli-native.node` | result |
|---|---|---|
| present | patched | exit 0, TUI renders |
| present | **unpatched** | **SIGSEGV 3/3** |
| **absent** | patched | exit 0 - clean auth error on screen, no crash |

The middle row is the one that matters: certs were fine and it still crashed. So
a missing trust store never caused the segfault; it only breaks the network.

Symptoms of the trust-store half, on a version that otherwise works:

```
Authentication token found but could not be validated.
Failed to fetch OAuth user login: network fetch failed: request failed: builder error
Failed to fetch GitHub CLI user login: network fetch failed: request failed: builder error
Failed to connect to MCP server "...": failed to build Streamable HTTP client: builder error
Segmentation fault
```

This looks like a broken install or an expired token. It is neither: **the token
is fine.** The runtime just cannot find any CA certificates. The give-away is in
`~/.copilot/logs/process-*.log`:

```
[ERROR] Failed to fetch latest release: HttpError: request failed: builder error:
        builder error: unexpected error: No CA certificates were loaded from the system
```

### Why

The Rust runtime uses `rustls-native-certs`, which probes the standard Linux
trust-store paths. **None of them exist on Android:**

| path | on Android |
|---|---|
| `/etc/ssl/certs` | missing |
| `/etc/ssl/cert.pem` | missing |
| `/system/etc/security/cacerts` | present, but individual hash-named files, not a bundle |
| `$PREFIX/etc/tls/cert.pem` | present (Termux `ca-certificates`) |

So zero roots load and every HTTPS client fails at *build* time - which is why
the message is `builder error` rather than a handshake or certificate error.
Auth, update checks, and any HTTPS MCP server all fail together.

More precisely, the failing layer is `rustls-platform-verifier`: because the
addon is compiled for `linux-musl` and not `target_os = "android"`, Rust
conditional compilation picks the Unix branch, which calls
`rustls_native_certs::load_native_certs()` and errors during *verifier
construction* when the resulting root store is empty. It cannot discover at
runtime that it should be using Android's `TrustManager` - that needs an Android
target plus JNI, so no environment variable can reach it. `rustls-native-certs`
0.8.x does read `SSL_CERT_FILE` itself, which is why pointing it at a bundle is
a real fix at the right layer and not a workaround at the wrong one.

### Fix

The wrapper now exports the Termux bundle before exec'ing node, each variable
only if the caller has not already set it and only if the path exists:

```bash
SSL_CERT_FILE=$PREFIX/etc/tls/cert.pem
SSL_CERT_DIR=$PREFIX/etc/tls
NODE_EXTRA_CA_CERTS=$PREFIX/etc/tls/cert.pem
```

**`SSL_CERT_FILE` alone is what actually fixes it.** The other two are belt and
braces and should not be read as required: `SSL_CERT_DIR` only helps on
`rustls-native-certs` 0.8+ (0.7 documented no directory loading), and
`NODE_EXTRA_CA_CERTS` touches only node's own TLS stack, which is a completely
separate root set from rustls and already ships Mozilla's roots. Keep the last
one only if your *node-side* HTTPS needs a private CA. `setup.sh` now also
installs `ca-certificates`.

Note this bug is **environment-dependent**, which makes it easy to misattribute:
if some other tool in your shell profile already exports `SSL_CERT_FILE`,
Copilot works, and it only breaks in shells that don't.

Also note what the bundle is *not*: a reproduction of Android's trust policy. It
is the curl/Mozilla public-WebPKI set (145 roots vs 149 in the system store).
Concatenating `/system/etc/security/cacerts` instead would not be an
improvement - since Android 14 roots can also come from the updatable Conscrypt
APEX, Android tracks *removed* certificates separately (so a raw read can
re-trust a root the platform distrusts), and MDM/work-profile CAs may live in a
per-user store Termux cannot read at all. If you are behind a TLS-inspecting
corporate proxy, append your organisation's root to the bundle explicitly:

```bash
cat $PREFIX/etc/tls/cert.pem corp-root.pem > ~/.copilot-ca.pem
export SSL_CERT_FILE=~/.copilot-ca.pem   # the wrapper honours a pre-set value
```

## SOLVED: the TUI segfault (fixed 2026-08-05)

After the 1.0.61+ fix below, headless `copilot -p "..."` worked perfectly but
plain `copilot` still died with SIGSEGV the moment the TUI painted. The reason is
embarrassingly simple: **`runtime.node` was not the only musl module that needed
patching.** 1.0.76 added `cli-native.node` (2.5 MB, the TUI renderer), and it was
shipping with `DT_NEEDED` = `libc.so` only. Its imports:

```
getaddrinfo  freeaddrinfo
pthread_mutexattr_init  pthread_mutexattr_settype  pthread_mutexattr_destroy
pthread_condattr_init   pthread_condattr_destroy
```

The mutexattr three are the exact bug documented below. `pthread_condattr_t` is
the **same 8-vs-4 hazard** (bionic `long`, musl `unsigned`) - previously listed
as "latent, not imported", which was true of `runtime.node` but not of this new
module. So the interactive path had an unpatched copy of the original bug plus a
second instance of it, which is why only the TUI died.

### Fix

`libpthread_xlate.so` gained `pthread_condattr_init/destroy/setclock/setpshared/
getclock/getpshared` and `pthread_cond_init`, plus the mutexattr getters, so no
bionic entry point can ever receive the 4-byte pointer. 14 translated symbols in
total. The wrapper now loops over **every** `*.node` in the prebuilds dir instead
of hard-coding `runtime.node`, computing each module's symbol subset from its own
`UND` imports (`rename_imports.py` refuses to run if a named symbol is absent).

### Verification (pty that answers terminal capability queries)

The harness must reply to `DA`/`DSR`/`OSC` colour queries, otherwise the TUI
waits forever and never reaches the crash site - which is exactly how this bug
hid behind a "working" `--version` and a piped-stdin test. Harness:
`~/.copilot-versions/pty_tui_test.py`, installed by `setup.sh` from
`scripts/pty_tui_test.py` (deliberately *not* in `$PREFIX/tmp`, which gets wiped
on restart - a missing harness fails silently as an empty result line, which
reads exactly like a pass).

```bash
python3 ~/.copilot-versions/pty_tui_test.py            # patched build
COPILOT_CMD=<unpatched-launcher> python3 ~/.copilot-versions/pty_tui_test.py
```

Reading `RESULT=`: `EXIT 0` with `visible` in the hundreds is a pass; `SIGNAL 11`
is the bug; `HANG` means the app ignored every `/exit` and the harness killed it,
which is **not** a crash - judge those on `visible`. Two traps the harness now
handles, both of which produced phantom failures while testing 1.0.80:

- A `SIGKILL`ed copilot leaves its session registered and the WAL mid-flight, and
  the *next* startup then stalls in "Session has been disposed" /
  "NativeMcpHostHandle has been destroyed" cleanup and renders nothing. That
  looks like a fresh bug but is self-inflicted. The harness now escalates
  SIGINT -> SIGTERM -> SIGKILL, and it is worth pausing ~10 s between runs.
- On a crash the pty reaches EOF a moment *before* the child becomes waitable, so
  a single `waitpid(WNOHANG)` reports neither exit nor signal and a genuine
  SIGSEGV gets logged as a hang. The harness polls for up to 3 s instead.

| `cli-native.node` | 1.0.78 | 1.0.80 |
|---|---|---|
| patched | 6/6 exit 0, full render | 7/7 exit 0, full render (`visible` 800-900) |
| pristine from the npm tarball | 3/3 **SIGSEGV** ~7.6 s | 6/8 **SIGSEGV** ~7.4 s, 2/8 clean pass |

Both directions verified with the CA bundle present throughout, so this is
independent of the trust-store bug above. Run the pristine control **on every new
version**, not just once: it is what proves the harness can still detect the
crash. A patched-only sweep cannot distinguish "fixed" from "harness went blind".

The control is **not** deterministic on 1.0.80 (it was on 1.0.78): 2 of 8 runs
rendered fine. Expected for stack corruption - which callee-saved register the
8-byte store lands on depends on the caller's frame, so some frames survive it.
Practical consequence: **never conclude anything from a single control run**, and
note that crashes are sharply bimodal in time here - a crash lands at ~7.4 s,
a survivor reaches `/exit` at ~23 s.

Also verified: the wrapper self-heals both modules automatically after a fresh
`npm install -g` (fresh binaries land with 1 `DT_NEEDED` and raw imports; after
one launch, 5 `DT_NEEDED` with the translator first and 0 unrenamed), and stays
idempotent across many launches (5 `NEEDED` entries, 5 unique - no duplicates).

### Coverage audit (re-run on every upgrade)

Verified clean on 1.0.78 and 1.0.80: both modules import only
equal-width pthread types beyond the renamed set
(`pthread_attr_t` 56/56, `pthread_cond_t` 48/48, `pthread_mutex_t` 40/40,
`pthread_rwlock_t` 56/56) and no `sem_*` or `pthread_spin_*`. Re-run after every
upgrade:

```bash
for f in ~/.npm-global/lib/node_modules/@github/copilot-linuxmusl-arm64/\
prebuilds/linuxmusl-arm64/*.node; do
  echo "== $f"
  readelf --dyn-syms -W "$f" | grep ' UND ' | awk '{print $8}' \
    | grep -e '[Pp]thread' -e '^sem_' -e spin | sort -u
done
```

Anything lowercase and attr-bearing in that output is a new instance of the bug.

## SOLVED: the 1.0.61+ segfault (fixed 2026-07-30, ceiling lifted)

Versions **1.0.61 through 1.0.75** segfaulted on Termux/bionic shortly after
startup: `--version` and the TUI worked, but `-p`/chat died with SIGSEGV. This
repo pinned to 1.0.60 for weeks as a result. **That pin is now removed — 1.0.76
works end to end** (prompts, shell tools, MCP, session resume, interactive TUI).

### Root cause: `pthread_mutexattr_t` is twice as wide on bionic

```
musl   pthread_mutexattr_t = unsigned  (4 bytes)
bionic pthread_mutexattr_t = long      (8 bytes)   # bits/pthread_types.h
```

`runtime.node` is musl-built, so it reserves only **4 bytes** for the attr. In
the faulting singleton-init the attr lives on the stack at `sp+0xc`, immediately
below the callee-saved spill written by `stp x20, x19, [sp, #0x10]`. bionic then
writes **8** bytes through that pointer:

- `pthread_mutexattr_init()` zeroes 8 bytes
- `pthread_mutexattr_destroy()` writes 8× `0xFF`

The upper 4 bytes land on the saved `x19`/`x20`, so a callee-saved register
returns as `0x..ffffffff`. Which register gets hit depends on the caller's frame
layout, which is why the crash looked nondeterministic under ptrace.

### The fix: scoped `.dynstr` import renaming

`LD_PRELOAD` cannot fix this. Termux's `node` executable itself *exports*
`getaddrinfo`, and on bionic the main executable wins symbol resolution over both
`LD_PRELOAD` and a `dlopen`'d module's own `DT_NEEDED` libc — which is why every
earlier interpose silently never fired.

Instead, rename the module's `UND` import names **in place** in `.dynstr` to a
same-length capitalised spelling (`getaddrinfo` → `Getaddrinfo`), then
`patchelf --add-needed` a small translator `.so` ordered *before* `libc.so` with
`--set-rpath '$ORIGIN'`. Only that module's calls are redirected; node's own
libuv/c-ares keep calling bionic directly. Same-length renaming means no offsets
shift, so the 115 MB binary needs no relinking.

Two translators, both in `shim/`:

| translator | renames | what it fixes |
|---|---|---|
| `pthread_xlate.c` | `pthread_mutexattr_init`/`settype`/`destroy`, `pthread_mutex_init` | Keeps a real 8-byte bionic attr in a local; writes back **only the low 4 bytes** to the musl-sized slot. This is the 1.0.61+ fix. |
| `gai_xlate.c` | `getaddrinfo`, `freeaddrinfo` | musl and bionic **swap** `ai_addr` and `ai_canonname` in `struct addrinfo` (0x30 both). A musl consumer reads bionic's NULL `ai_canonname` as `ai_addr` and derefs `sa_family`. Deep-copies the list into musl order. |

`shim/rename_imports.py` performs the rename (pyelftools). It has a `--check`
mode and refuses to double-apply, so the wrapper can re-run it safely after any
`npm install`.

### Verification (clean A/B on 1.0.76)

Same binary, same `LD_PRELOAD` shim, same prompt:

| build | result |
|---|---|
| unpatched | SIGSEGV, exit 139, no output |
| `gai` translator only | SIGSEGV, exit 139 |
| `gai` + `pthread` translators | **exit 0**, prompt answered, credits billed |

The middle row is the important one: it isolates the mutexattr fix as the thing
that actually lifts the ceiling.

### Guard-page proof that the translator never writes a 5th byte

`shim/guard.c` places the 4-byte musl attr in the **last 4 bytes of a writable
page** with a `PROT_NONE` page immediately after, so any 5th byte written faults:

| call path | result |
|---|---|
| raw bionic `pthread_mutexattr_init` on that slot | **SIGSEGV** (exit 139) - bionic really does store 8 bytes |
| `libpthread_xlate.so` init/settype/mutex_init/destroy on that slot | no fault; slot ends `ffffffff`, guard page untouched |

The same probe also confirms semantics survive translation: an attr built through
the shim with `PTHREAD_MUTEX_RECURSIVE` produces a mutex that can be locked
twice, and a deliberately 4-mod-8 misaligned slot mid-page also survives.

### Wrapper-coverage audit

Every attr-touching import is renamed, and nothing bypasses the translator.
`runtime.node` 1.0.76 imports 30 `pthread_*` symbols; the only ones taking a
libc-owned *attribute* object are the four we intercept:

```
Pthread_mutexattr_init  Pthread_mutexattr_settype
Pthread_mutexattr_destroy  Pthread_mutex_init      <- renamed, ours
```

`runtime.node` has **no** imports of `pthread_condattr_*`, `pthread_spin_*`,
`sem_*`, or `pthread_mutexattr_get*/setpshared/setprotocol`. Note this audit
covers `runtime.node` **only**, and that was the trap: `cli-native.node` *does*
import `pthread_condattr_*`, which is the TUI segfault documented above. Always
audit every `*.node` in the directory, not just the runtime.
`pthread_attr_t`, `pthread_rwlock_t`,
`pthread_once_t` and `pthread_key_t` are all equal-or-larger on bionic and are
created and consumed entirely by bionic, so they are safe (their internal
encodings differ, but no object ever crosses libcs).

### Related ABI widths worth watching

Bionic is **wider** than musl for three types on aarch64 LP64. Two of the three
have now actually bitten:

| type | bionic | musl | status |
|---|---|---|---|
| `pthread_mutexattr_t` | 8 | 4 | **the 1.0.61+ bug**, imported by both modules |
| `pthread_condattr_t` | 8 | 4 | **the TUI segfault**, imported by `cli-native.node` |
| `pthread_spinlock_t` | 8 | 4 | latent - not imported by any module yet |

`pthread_mutex_t` (40), `pthread_cond_t` (48), `pthread_rwlock_t` (56),
`pthread_attr_t` (56), `pthread_barrier_t` (32), `pthread_once_t` (4) and
`pthread_key_t` (4) all match, so only the attr pointer needed widening.

### Previously-published theory, now disproven

Earlier revisions of this README blamed bionic's **static-TLS surplus** being
exhausted by the module's growing `PT_TLS` block, and concluded the crash was
"unfixable via LD_PRELOAD/patchelf" short of a proot glibc rootfs. That was
wrong. The decisive experiment: `LD_PRELOAD` the runtime *itself*, which makes it
an initial static-TLS module (preloads load before
`linker_finalize_static_tls()`). The crash was **identical**, same PC. bionic
does support `R_AARCH64_TLSDESC` for `dlopen`'d modules, and the faulting
`mov w0,#1; ldur x8,[x20,#0x6c]; blr x8` is ABI-incompatible with TLSDESC anyway
(TLSDESC passes the descriptor address in `x0`). No proot needed.

### Version pinning

The ceiling is lifted. To re-pin if a future release regresses:

```bash
COPILOT_MAX_VERSION=1.0.76 ./setup.sh --update
```

### 1.0.73+ needs two packages

From 1.0.73 upstream split the package: `@github/copilot` is a ~5 KB loader stub
and the real binaries ship in per-platform optional deps.

```bash
npm install -g @github/copilot
npm install -g --force @github/copilot-linuxmusl-arm64
```

The `--force` is required: the platform package declares `os: ["linux"]` and
Termux reports `"android"`, so npm silently skips it as an optional dependency.

Two loader quirks the wrapper handles for you:

1. The stub's `npm-loader.js` gates on `process.platform === "linux"` and would
   spawn the musl **SEA** binary (interpreter `/lib/ld-musl-aarch64.so.1`, absent
   on bionic). The wrapper bypasses the stub and runs the platform package's
   `index.js` under Termux node.
2. `detect-libc` reports "glibc" on bionic, so the loader looks in
   `prebuilds/linux-arm64`; the wrapper symlinks that to `linuxmusl-arm64`.

Good news: 1.0.76 no longer throws `Unsupported platform`, because `os.type()`
returns `"Linux"` on Termux even though `process.platform` is `"android"` — so
`patch_js.py` is no longer needed.
