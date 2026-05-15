#!/usr/bin/env bash
# GitHub Copilot CLI launcher with Termux/bionic compat patches.
# Self-heals after `npm update` wipes the prebuilds dir.
#
# Layout history:
#   1.0.45 — no native runtime, pure JS, no patch needed
#   1.0.46–1.0.47 — native/runtime/runtime.<plat>-<libc>.node (musl variant shipped)
#   1.0.48+ — prebuilds/<plat>/runtime.node (glibc-only, plus icu-native.node)
#
# Patches applied:
#   1. LD_PRELOAD libbionic_shim.so — shims bcmp/__xpg_strerror_r/__errno_location/
#      __xstat64-family/__assert_fail/__ctype_b_loc + statically-linked _Unwind_*.
#   2. prebuilds/android-arm64/runtime.node — derived from prebuilds/linux-arm64/
#      runtime.node by: strip GLIBC symbol versions, drop libgcc_s/libpthread/libdl
#      NEEDED, rename libc.so.6→libc.so, libm.so.6→libm.so.
#   3. (1.0.46–1.0.47 only) native/runtime/runtime.android-arm64.node — patchelf
#      copy of the musl variant with libm.so added to NEEDED.

SHIM_DIR="$HOME/.copilot-versions/shim"
SHIM_LIB="$SHIM_DIR/libbionic_shim.so"
SHIM_SRC="$SHIM_DIR/bionic_shim.c"
STRIP_PY="$SHIM_DIR/strip_verneed.py"
PATCH_JS_PY="$SHIM_DIR/patch_js.py"
COPILOT_PKG="$HOME/.npm-global/lib/node_modules/@github/copilot"
NPM_LOADER="$COPILOT_PKG/npm-loader.js"
LIBUNWIND="/data/data/com.termux/files/usr/lib/libunwind.a"
PTY_BACKUP_DIR="$HOME/.copilot-termux-backups"
ANDROID_ARCH="android-arm64"  # TODO: detect from uname -m for non-arm64 hosts

build_shim() {
    [ -f "$SHIM_SRC" ] || return 1
    command -v clang >/dev/null 2>&1 || return 1
    if [ -f "$LIBUNWIND" ]; then
        clang -O2 -shared -fPIC -fvisibility=default -Wl,--no-as-needed -lm \
            -Wl,--whole-archive "$LIBUNWIND" -Wl,--no-whole-archive \
            -o "$SHIM_LIB" "$SHIM_SRC" 2>/dev/null
        for sym in _Unwind_Backtrace _Unwind_DeleteException _Unwind_FindEnclosingFunction \
                   _Unwind_ForcedUnwind _Unwind_GetCFA _Unwind_GetDataRelBase _Unwind_GetGR \
                   _Unwind_GetIP _Unwind_GetIPInfo _Unwind_GetLanguageSpecificData \
                   _Unwind_GetRegionStart _Unwind_GetTextRelBase _Unwind_RaiseException \
                   _Unwind_Resume _Unwind_Resume_or_Rethrow _Unwind_SetGR _Unwind_SetIP; do
            llvm-objcopy --globalize-symbol="$sym" --set-symbol-visibility="$sym"=default \
                "$SHIM_LIB" 2>/dev/null
        done
    else
        clang -O2 -shared -fPIC -fvisibility=default -Wl,--no-as-needed -lm \
            -o "$SHIM_LIB" "$SHIM_SRC" 2>/dev/null
    fi
}

patch_runtime_148() {
    local src="$COPILOT_PKG/prebuilds/linux-arm64/runtime.node"
    local dst_dir="$COPILOT_PKG/prebuilds/android-arm64"
    local dst="$dst_dir/runtime.node"
    [ -f "$src" ] || return 1
    [ -f "$STRIP_PY" ] || return 1
    mkdir -p "$dst_dir"
    cp -f "$src" "$dst"
    python3 "$STRIP_PY" "$dst" >/dev/null 2>&1 || return 1
    patchelf --remove-needed libgcc_s.so.1 "$dst" 2>/dev/null
    patchelf --remove-needed libpthread.so.0 "$dst" 2>/dev/null
    patchelf --remove-needed libdl.so.2 "$dst" 2>/dev/null
    patchelf --replace-needed libc.so.6 libc.so "$dst" 2>/dev/null
    patchelf --replace-needed libm.so.6 libm.so "$dst" 2>/dev/null
}

patch_runtime_147() {
    local src="$COPILOT_PKG/native/runtime/runtime.linux-arm64-musl.node"
    local dst="$COPILOT_PKG/native/runtime/runtime.android-arm64.node"
    [ -f "$src" ] || return 1
    cp -f "$src" "$dst"
    patchelf --add-needed libm.so "$dst" 2>/dev/null
}

# Self-heal: rebuild shim if missing.
[ ! -f "$SHIM_LIB" ] && build_shim

# Self-heal: restore pty.node from permanent backup if missing.
# `npm install -g @github/copilot` wipes prebuilds/$ANDROID_ARCH/ on every
# install, including the user-built pty.node. The first install (or `setup.sh`)
# stashes a copy at $PTY_BACKUP_DIR/pty.node.$ANDROID_ARCH; restore it here so
# `node-pty` (used by every shell-tool invocation) keeps working after updates.
PTY_DST="$COPILOT_PKG/prebuilds/$ANDROID_ARCH/pty.node"
PTY_BACKUP="$PTY_BACKUP_DIR/pty.node.$ANDROID_ARCH"
if [ ! -f "$PTY_DST" ] && [ -f "$PTY_BACKUP" ]; then
    mkdir -p "$(dirname "$PTY_DST")"
    cp -f "$PTY_BACKUP" "$PTY_DST"
fi
# Keep the backup mirror in sync if the on-disk pty.node is newer (e.g. user
# rebuilt it manually after a node-pty version bump).
if [ -f "$PTY_DST" ] && [ ! -f "$PTY_BACKUP" -o "$PTY_DST" -nt "$PTY_BACKUP" ]; then
    mkdir -p "$PTY_BACKUP_DIR"
    cp -f "$PTY_DST" "$PTY_BACKUP"
fi
if [ ! -f "$PTY_DST" ]; then
    echo "[copilot-wrapper] WARN: $PTY_DST missing and no backup at $PTY_BACKUP. Run setup.sh (full install) to rebuild node-pty for $ANDROID_ARCH; shell tools will fail until then." >&2
fi

# Self-heal: rebuild patched runtime if missing/stale. Detect layout.
NEW_LAYOUT_DST="$COPILOT_PKG/prebuilds/android-arm64/runtime.node"
NEW_LAYOUT_SRC="$COPILOT_PKG/prebuilds/linux-arm64/runtime.node"
OLD_LAYOUT_DST="$COPILOT_PKG/native/runtime/runtime.android-arm64.node"
OLD_LAYOUT_SRC="$COPILOT_PKG/native/runtime/runtime.linux-arm64-musl.node"

if [ -f "$NEW_LAYOUT_SRC" ]; then
    # 1.0.48+ layout
    if [ ! -f "$NEW_LAYOUT_DST" ] || [ "$NEW_LAYOUT_SRC" -nt "$NEW_LAYOUT_DST" ]; then
        patch_runtime_148 || echo "[copilot-wrapper] WARN: failed to patch runtime.node for 1.0.48+ layout" >&2
    fi
elif [ -f "$OLD_LAYOUT_SRC" ]; then
    # 1.0.46–1.0.47 layout
    if [ ! -f "$OLD_LAYOUT_DST" ] || [ "$OLD_LAYOUT_SRC" -nt "$OLD_LAYOUT_DST" ]; then
        patch_runtime_147 || echo "[copilot-wrapper] WARN: failed to patch runtime.node for 1.0.46/47 layout" >&2
    fi
else
    # Neither known source layout present — upstream may have moved things again.
    # Remove any stale patched binaries so node fails with an honest "not found"
    # rather than a napi-version mismatch from loading the wrong-version binary.
    if [ -f "$NEW_LAYOUT_DST" ] || [ -f "$OLD_LAYOUT_DST" ]; then
        rm -f "$NEW_LAYOUT_DST" "$OLD_LAYOUT_DST"
        echo "[copilot-wrapper] WARN: neither known runtime source layout found in $COPILOT_PKG — removed stale patched binaries. Upstream may have moved things; check /sdcard/Download/copilot-version/README.md." >&2
    fi
fi

# JS platform-allowlist patch (idempotent). Required from 1.0.48 onwards: the
# native-binding loader's libc-variant helper throws "Unsupported platform" on
# Android before reaching the prebuilds lookup. Patch index.js + app.js to fall
# through instead of throwing. Re-applies if npm restored fresh JS.
# Surface failure loudly: if patch_js.py reports the marker is present but the
# regex didn't match, upstream changed the JS shape — copilot will throw on
# launch and the user needs to know to update patch_js.py rather than silently
# get a broken cli.
if [ -f "$PATCH_JS_PY" ] && [ -f "$COPILOT_PKG/index.js" ]; then
    if command grep -q 'default:throw new Error(`Unsupported platform' "$COPILOT_PKG/index.js" 2>/dev/null; then
        if ! python3 "$PATCH_JS_PY" "$COPILOT_PKG" >&2; then
            echo "[copilot-wrapper] ERROR: patch_js.py failed to apply. Copilot will throw 'Unsupported platform: android/arm64' on launch. See /sdcard/Download/copilot-version/README.md or update shim/patch_js.py to match the new JS shape." >&2
        fi
    fi
fi

if [ -f "$SHIM_LIB" ]; then
    export LD_PRELOAD="${SHIM_LIB}${LD_PRELOAD:+:$LD_PRELOAD}"
fi

# Note: LD_PRELOAD is intentionally inherited by child processes (MCP servers,
# worker_threads, fork()'d node, ! shell exec children). Copilot loads
# runtime.node in worker threads that need __ctype_b_loc and other shim
# symbols too. The shim is bionic-compatible: its forwarders (bcmp→memcmp,
# __errno_location→__errno, __xstat64-family→fstat etc.) are no-ops for
# native bionic binaries because they don't reference those glibc names. The
# preload.js variant of this wrapper that stripped LD_PRELOAD broke workspace
# init and MCP host init for that reason — see /sdcard/Download/copilot-version
# /README.md "LD_PRELOAD scoping" note.

exec /data/data/com.termux/files/usr/bin/node "$NPM_LOADER" "$@"
