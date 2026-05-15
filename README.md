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
