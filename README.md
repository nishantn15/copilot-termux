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
- `@github/copilot` 1.0.45 → 1.0.48 (1.0.46+ requires Termux `clang`, `patchelf`, `python3`, `pyelftools`, and `libunwind.a` from `ndk-sysroot`)

## License

MIT

## Usage

Once the installation is complete, you can start the GitHub Copilot CLI by running:

```bash
copilot
```

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

There are **no** imports of `pthread_condattr_*`, `pthread_spin_*`, `sem_*`, or
`pthread_mutexattr_get*/setpshared/setprotocol`, so the two latent 8-vs-4 types
below are genuinely unreachable today. `pthread_attr_t`, `pthread_rwlock_t`,
`pthread_once_t` and `pthread_key_t` are all equal-or-larger on bionic and are
created and consumed entirely by bionic, so they are safe (their internal
encodings differ, but no object ever crosses libcs).

### Related ABI widths worth watching

Bionic is **wider** than musl for three types on aarch64 LP64. Only the first is
currently imported by `runtime.node`, but re-audit if a future release adds
pthread calls:

| type | bionic | musl | status |
|---|---|---|---|
| `pthread_mutexattr_t` | 8 | 4 | **was the bug** |
| `pthread_condattr_t` | 8 | 4 | latent, not imported |
| `pthread_spinlock_t` | 8 | 4 | latent, not imported |

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
