#!/data/data/com.termux/files/usr/bin/bash
# GitHub Copilot CLI launcher with Termux/bionic compat patches.
# Self-heals after `npm install -g` replaces the platform package.
#
# ============================================================================
# 1.0.61+ ROOT CAUSE (solved 2026-07-30) - pthread_mutexattr_t width mismatch
# ============================================================================
# Every version from 1.0.61 to 1.0.75 segfaulted on Termux after startup. The
# cause was NOT bionic's static-TLS surplus (an earlier theory, now disproven).
# It is a plain ABI width mismatch:
#
#     musl   pthread_mutexattr_t = unsigned  (4 bytes)
#     bionic pthread_mutexattr_t = long      (8 bytes)
#
# runtime.node is musl-built, so it reserves only 4 bytes for the attr. In the
# faulting singleton-init the attr lives on the stack directly BELOW the
# callee-saved spill slot written by `stp x20, x19, [sp, #0x10]`. bionic then
# writes 8 bytes through that pointer - pthread_mutexattr_init() zeroes 8, and
# pthread_mutexattr_destroy() writes 8x 0xFF - so the upper 4 bytes land on the
# saved x19/x20 and the register returns as 0x..ffffffff. Which register gets
# hit depends on the caller's frame layout, which is why it looked random.
#
# Fix: libpthread_xlate.so keeps a real 8-byte bionic attr in a local and only
# ever writes the low 4 bytes back to the musl-sized slot.
#
# Verified A/B on 1.0.76 (same binary, same shim, same prompt):
#   unpatched                -> SIGSEGV (exit 139), no output
#   gai translator only      -> SIGSEGV (exit 139)
#   gai + pthread translator -> exit 0, prompt answered, credits billed
#
# ============================================================================
# Layout history
# ============================================================================
#   1.0.45          - no native runtime, pure JS, no patch needed
#   1.0.46-1.0.47   - native/runtime/runtime.<plat>-<libc>.node (musl shipped)
#   1.0.48-1.0.72   - prebuilds/<plat>/runtime.node, glibc-only
#   1.0.73+         - SPLIT PACKAGE: @github/copilot is a tiny loader stub;
#                     real binaries live in per-platform optional deps
#                     @github/copilot-linuxmusl-arm64 (musl) and
#                     @github/copilot-linux-arm64 (glibc). We use the MUSL one.
#
# On 1.0.73+ npm SKIPS the platform package (its os field is "linux", we are
# "android"), so setup installs it explicitly with --force. The stub's
# npm-loader.js also gates on process.platform === "linux" and would spawn the
# musl SEA binary (needs /lib/ld-musl-aarch64.so.1, absent on bionic), so we
# bypass the stub entirely and run the platform package's index.js under
# Termux node.
#
# ============================================================================
# Patches applied to the musl runtime.node
# ============================================================================
#   1. LD_PRELOAD libbionic_shim.so - bcmp, __xpg_strerror_r,
#      __errno_location, __xstat64-family, __ctype_b_loc, __assert_fail,
#      gnu_get_libc_version, __res_init, getrandom/gettid/statx, fcntl64,
#      plus statically-linked _Unwind_*.
#   2. .dynstr in-place import renames (same length, so no offsets shift) that
#      scope six libc calls to translator shims add-needed BEFORE libc.so:
#        getaddrinfo/freeaddrinfo -> libgai_xlate.so
#          (musl vs bionic swap ai_addr and ai_canonname in struct addrinfo;
#           also Termux's node itself exports getaddrinfo and wins bionic
#           symbol resolution, which is why LD_PRELOAD alone never worked)
#        pthread_mutexattr_init/settype/destroy + pthread_mutex_init
#          -> libpthread_xlate.so   (the 8-vs-4-byte fix described above)
#      Scoping via DT_NEEDED (not LD_PRELOAD) means node's own libuv/c-ares
#      keep calling bionic directly, untouched.
#   3. patchelf --add-needed libm.so libdl.so, --set-rpath '$ORIGIN'.
#   4. prebuilds/linux-arm64 -> linuxmusl-arm64 symlink, because detect-libc
#      reports "glibc" on bionic so the loader looks in the linux-arm64 dir.

SHIM_DIR="$HOME/.copilot-versions/shim"
SHIM_LIB="$SHIM_DIR/libbionic_shim.so"
SHIM_SRC="$SHIM_DIR/bionic_shim.c"
GAI_LIB="$SHIM_DIR/libgai_xlate.so"
GAI_SRC="$SHIM_DIR/gai_xlate.c"
PTH_LIB="$SHIM_DIR/libpthread_xlate.so"
PTH_SRC="$SHIM_DIR/pthread_xlate.c"
RENAME_PY="$SHIM_DIR/rename_imports.py"
STRIP_PY="$SHIM_DIR/strip_verneed.py"
PATCH_JS_PY="$SHIM_DIR/patch_js.py"
PATCH_MOUSE_PY="$SHIM_DIR/patch_mouse.py"

NODE_MODULES="$HOME/.npm-global/lib/node_modules"
STUB_PKG="$NODE_MODULES/@github/copilot"
ARCH_SUFFIX="arm64"
MUSL_PKG="$NODE_MODULES/@github/copilot-linuxmusl-$ARCH_SUFFIX"
LEGACY_PKG="$STUB_PKG"

LIBUNWIND="/data/data/com.termux/files/usr/lib/libunwind.a"
PTY_BACKUP_DIR="$HOME/.copilot-termux-backups"
ANDROID_ARCH="android-arm64"

# Symbols whose .dynstr names get capitalised so they bind to our translators.
GAI_SYMS="getaddrinfo freeaddrinfo"
# NOTE: only symbols a module ACTUALLY imports may be listed per-module;
# rename_imports.py refuses to patch if any named symbol is absent. So each
# module gets its own set, computed below by intersecting with its imports.
PTH_SYMS="pthread_mutexattr_init pthread_mutexattr_settype pthread_mutexattr_destroy pthread_mutex_init"
# pthread_condattr_t is bionic 8 / musl 4 exactly like the mutex attr, and
# cli-native.node (the TUI renderer) imports it - that is why the interactive
# path still segfaulted when only runtime.node was patched.
COND_SYMS="pthread_condattr_init pthread_condattr_destroy pthread_condattr_setclock pthread_condattr_setpshared pthread_condattr_getclock pthread_condattr_getpshared pthread_cond_init"
MUTEX_EXTRA_SYMS="pthread_mutexattr_gettype pthread_mutexattr_setpshared pthread_mutexattr_getpshared"
ALL_XLATE_SYMS="$GAI_SYMS $PTH_SYMS $COND_SYMS $MUTEX_EXTRA_SYMS"

# Echo the subset of $ALL_XLATE_SYMS that $1 actually imports (UND in .dynsym),
# in either the original or already-renamed spelling.
imported_xlate_syms() {
    local elf="$1" have sym
    have=$(readelf --dyn-syms -W "$elf" 2>/dev/null \
           | command grep ' UND ' | awk '{print $8}' | sort -u)
    for sym in $ALL_XLATE_SYMS; do
        local cap="$(printf '%s' "${sym%"${sym#?}"}" | tr 'a-z' 'A-Z')${sym#?}"
        if printf '%s\n' "$have" | command grep -qx -e "$sym" -e "$cap"; then
            printf '%s ' "$sym"
        fi
    done
}

warn() { echo "[copilot-wrapper] $*" >&2; }

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

build_translator() {
    # $1 = output .so, $2 = source .c
    [ -f "$2" ] || return 1
    command -v clang >/dev/null 2>&1 || return 1
    clang -O2 -shared -fPIC -fvisibility=default -ldl -o "$1" "$2" 2>/dev/null
}

# --- 1.0.73+ split-package path -------------------------------------------

patch_one_node() {
    # $1 = path to a musl-built .node module. Idempotent: rename_imports.py
    # verifies the exact expected bytes and refuses to double-apply, and
    # patchelf --add-needed is a no-op when the entry already exists.
    local elf="$1" syms
    [ -f "$elf" ] || return 0          # module absent in this version, fine
    syms="$(imported_xlate_syms "$elf")"
    if [ -n "$syms" ]; then
        if python3 "$RENAME_PY" --check "$elf" $syms >/dev/null 2>&1; then
            python3 "$RENAME_PY" "$elf" $syms >/dev/null 2>&1 || {
                warn "ERROR: .dynstr rename failed on $elf. Copilot will segfault."
                warn "       python3 $RENAME_PY --check $elf $syms"
                return 1
            }
        fi
    fi
    # patchelf --add-needed does NOT deduplicate, so check first. A duplicate
    # DT_NEEDED is harmless at runtime but grows on every launch.
    local needed
    needed=$(readelf -d "$elf" 2>/dev/null | command grep NEEDED)
    for lib in libm.so libdl.so libgai_xlate.so libpthread_xlate.so; do
        printf '%s\n' "$needed" | command grep -qF "[$lib]" || \
            patchelf --add-needed "$lib" "$elf" 2>/dev/null
    done
    patchelf --set-rpath '$ORIGIN' "$elf" 2>/dev/null
    return 0
}

patch_musl_runtime() {
    local dir="$MUSL_PKG/prebuilds/linuxmusl-$ARCH_SUFFIX"
    [ -d "$dir" ] || return 1
    [ -f "$RENAME_PY" ] || { warn "missing $RENAME_PY"; return 1; }
    [ -f "$dir/runtime.node" ] || return 1

    cp -f "$GAI_LIB" "$PTH_LIB" "$dir/" 2>/dev/null

    # EVERY musl .node in the dir needs this, not just runtime.node.
    # cli-native.node drives the TUI and imports pthread_mutexattr_* AND
    # pthread_condattr_* - leaving it unpatched segfaults the interactive path
    # (~60% of launches) while headless -p prompts look completely fine.
    local rc=0 f
    for f in "$dir"/*.node; do
        [ -f "$f" ] || continue
        patch_one_node "$f" || rc=1
    done

    # detect-libc says "glibc" on bionic, so the loader looks in linux-arm64.
    ln -sfn "linuxmusl-$ARCH_SUFFIX" "$MUSL_PKG/prebuilds/linux-$ARCH_SUFFIX" 2>/dev/null
    return $rc
}

runtime_is_patched() {
    # Every .node in the dir must carry the translator, and none may still have
    # an un-renamed attr import. Either condition failing triggers a re-patch.
    local dir="$MUSL_PKG/prebuilds/linuxmusl-$ARCH_SUFFIX" f
    [ -f "$dir/runtime.node" ] || return 1
    for f in "$dir"/*.node; do
        [ -f "$f" ] || continue
        readelf -d "$f" 2>/dev/null | command grep -q 'libpthread_xlate\.so' || return 1
        readelf --dyn-syms -W "$f" 2>/dev/null | command grep ' UND ' | awk '{print $8}' \
            | command grep -q -e '^pthread_mutexattr' -e '^pthread_condattr' && return 1
    done
    return 0
}

# --- legacy (<=1.0.72) single-package path ---------------------------------

patch_glibc_node() {
    local src="$1" dst="$2"
    [ -f "$src" ] || return 1
    [ -f "$STRIP_PY" ] || return 1
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
    python3 "$STRIP_PY" "$dst" >/dev/null 2>&1 || return 1
    patchelf --remove-needed libgcc_s.so.1 "$dst" 2>/dev/null
    patchelf --remove-needed libpthread.so.0 "$dst" 2>/dev/null
    patchelf --remove-needed libdl.so.2 "$dst" 2>/dev/null
    patchelf --replace-needed libc.so.6 libc.so "$dst" 2>/dev/null
    patchelf --replace-needed libm.so.6 libm.so "$dst" 2>/dev/null
}

legacy_selfheal() {
    local NEW_DST="$LEGACY_PKG/prebuilds/android-arm64/runtime.node"
    local NEW_SRC="$LEGACY_PKG/prebuilds/linux-arm64/runtime.node"
    local OLD_DST="$LEGACY_PKG/native/runtime/runtime.android-arm64.node"
    local OLD_SRC="$LEGACY_PKG/native/runtime/runtime.linux-arm64-musl.node"

    local PTY_DST="$LEGACY_PKG/prebuilds/$ANDROID_ARCH/pty.node"
    local PTY_BACKUP="$PTY_BACKUP_DIR/pty.node.$ANDROID_ARCH"
    if [ ! -f "$PTY_DST" ] && [ -f "$PTY_BACKUP" ]; then
        mkdir -p "$(dirname "$PTY_DST")"; cp -f "$PTY_BACKUP" "$PTY_DST"
    fi
    if [ -f "$PTY_DST" ] && { [ ! -f "$PTY_BACKUP" ] || [ "$PTY_DST" -nt "$PTY_BACKUP" ]; }; then
        mkdir -p "$PTY_BACKUP_DIR"; cp -f "$PTY_DST" "$PTY_BACKUP"
    fi

    if [ -f "$NEW_SRC" ]; then
        if [ ! -f "$NEW_DST" ] || [ "$NEW_SRC" -nt "$NEW_DST" ]; then
            patch_glibc_node "$NEW_SRC" "$NEW_DST" || warn "WARN: failed to patch runtime.node (1.0.48+ layout)"
        fi
        local CN_SRC="$LEGACY_PKG/prebuilds/linux-arm64/cli-native.node"
        local CN_DST="$LEGACY_PKG/prebuilds/android-arm64/cli-native.node"
        if [ -f "$CN_SRC" ]; then
            if [ ! -f "$CN_DST" ] || [ "$CN_SRC" -nt "$CN_DST" ]; then
                patch_glibc_node "$CN_SRC" "$CN_DST" || warn "WARN: failed to patch cli-native.node - TUI may render blank"
            fi
        elif [ -f "$CN_DST" ]; then
            rm -f "$CN_DST"
        fi
    elif [ -f "$OLD_SRC" ]; then
        if [ ! -f "$OLD_DST" ] || [ "$OLD_SRC" -nt "$OLD_DST" ]; then
            cp -f "$OLD_SRC" "$OLD_DST" && patchelf --add-needed libm.so "$OLD_DST" 2>/dev/null
        fi
    fi

    if [ -f "$PATCH_JS_PY" ] && [ -f "$LEGACY_PKG/index.js" ]; then
        if command grep -q 'default:throw new Error(`Unsupported platform' "$LEGACY_PKG/index.js" 2>/dev/null; then
            python3 "$PATCH_JS_PY" "$LEGACY_PKG" >&2 || \
                warn "ERROR: patch_js.py failed. Copilot will throw 'Unsupported platform: android/arm64'."
        fi
    fi
}

# --- self-heal shims ------------------------------------------------------

[ -f "$SHIM_LIB" ] || build_shim
[ -f "$GAI_LIB" ] || build_translator "$GAI_LIB" "$GAI_SRC"
[ -f "$PTH_LIB" ] || build_translator "$PTH_LIB" "$PTH_SRC"

for pair in "$SHIM_LIB:$SHIM_SRC" "$GAI_LIB:$GAI_SRC" "$PTH_LIB:$PTH_SRC"; do
    lib="${pair%%:*}"; src="${pair#*:}"
    if [ -f "$src" ] && [ -f "$lib" ] && [ "$src" -nt "$lib" ]; then
        if [ "$lib" = "$SHIM_LIB" ]; then build_shim; else build_translator "$lib" "$src"; fi
    fi
done

# --- mouse-scroll patch (Termux swipe -> wheel, not arrow keys) -----------
#
# Termux's terminal maps a fixed set of DECSET codes; its mouse tracking is
# driven by the 1000/1002 bits. When the server-side TIMELINE_TOUCHUP flag is
# on, copilot enables "any-event" tracking as mode 1003 ALONE, which Termux does
# not map - so tracking stays off, and in the alternate screen Termux converts
# finger swipes into DPAD_UP/DPAD_DOWN. Those arrows land in the prompt box, so
# a swipe cycles prompt history instead of scrolling the transcript.
#
# patch_mouse.py adds 1002 alongside 1003. Independent bits, so terminals that
# honour 1003 lose nothing, and copilot's own MOUSE_OFF already sends 1002l so
# the terminal is not left reporting mouse events after exit. Re-applied here
# because npm restores a pristine app.js on every upgrade.
patch_mouse_js() {
    local app="$1"
    [ -f "$PATCH_MOUSE_PY" ] || return 0
    [ -f "$app" ] || return 0
    python3 "$PATCH_MOUSE_PY" "$app" >/dev/null 2>&1 || \
        warn "WARN: mouse-scroll patch did not apply to $app (upstream constant changed?) - swipe may fall back to arrow keys"
}

# --- pick entry point ----------------------------------------------------

ENTRY=""
if [ -f "$MUSL_PKG/index.js" ]; then
    # 1.0.73+ split package. Re-patch if npm replaced the runtime.
    runtime_is_patched || patch_musl_runtime || \
        warn "WARN: could not patch $MUSL_PKG runtime.node - expect a segfault"
    patch_mouse_js "$MUSL_PKG/app.js"
    ENTRY="$MUSL_PKG/index.js"
elif [ -f "$LEGACY_PKG/index.js" ]; then
    legacy_selfheal
    patch_mouse_js "$LEGACY_PKG/app.js"
    if [ -f "$LEGACY_PKG/npm-loader.js" ]; then
        ENTRY="$LEGACY_PKG/npm-loader.js"
    else
        ENTRY="$LEGACY_PKG/index.js"
    fi
else
    warn "ERROR: no copilot entry point found."
    warn "       Looked for $MUSL_PKG/index.js and $LEGACY_PKG/index.js."
    warn "       For 1.0.73+ you need BOTH packages:"
    warn "         npm install -g @github/copilot"
    warn "         npm install -g --force @github/copilot-linuxmusl-$ARCH_SUFFIX"
    warn "       (the second needs --force: its os field is \"linux\", Termux is \"android\")"
    exit 1
fi

if [ -f "$SHIM_LIB" ]; then
    export LD_PRELOAD="${SHIM_LIB}${LD_PRELOAD:+:$LD_PRELOAD}"
fi

# LD_PRELOAD is intentionally inherited by children (MCP servers,
# worker_threads, fork()'d node, ! shell children). The runtime loads in worker
# threads that need __ctype_b_loc etc. too. The shim is harmless to native
# bionic binaries since they never reference those glibc names. Note the
# translator shims are deliberately NOT preloaded - they are scoped to
# runtime.node via DT_NEEDED so node's own libuv keeps calling bionic.

# ---------------------------------------------------------------------------
# TLS trust store (fixes "auth failed" + the follow-on SIGSEGV)
# ---------------------------------------------------------------------------
# The Rust runtime uses rustls-native-certs, which probes the standard Linux
# paths (/etc/ssl/certs, /etc/ssl/cert.pem, ...). NONE of those exist on
# Android - the system store is /system/etc/security/cacerts (individual
# hash-named files, not a bundle). So the runtime loads ZERO roots and every
# HTTPS request fails at client-build time with:
#
#     request failed: builder error: unexpected error:
#     No CA certificates were loaded from the system
#
# Symptoms: "Authentication token found but could not be validated", "Failed to
# fetch OAuth user login", MCP servers over HTTPS refusing to connect, and then
# a SIGSEGV inside the TUI (the cert failure path crashes rather than erroring
# out cleanly - reproducible under a pty, and it goes away entirely once roots
# load). It looks like a broken install but the token is fine.
#
# Verified A/B under a real pty on 1.0.76:
#   no SSL_CERT_FILE  -> SIGSEGV (signal 11), auth errors on screen
#   SSL_CERT_FILE set -> exit 0, auth fine
#
# Termux ships the ca-certificates bundle, so point rustls at it. Only set it
# if the caller has not, and only if the bundle actually exists.
if [ -z "${SSL_CERT_FILE:-}" ] && [ -f /data/data/com.termux/files/usr/etc/tls/cert.pem ]; then
    export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem
fi
if [ -z "${SSL_CERT_DIR:-}" ] && [ -d /data/data/com.termux/files/usr/etc/tls ]; then
    export SSL_CERT_DIR=/data/data/com.termux/files/usr/etc/tls
fi
if [ -z "${NODE_EXTRA_CA_CERTS:-}" ] && [ -f "${SSL_CERT_FILE:-}" ]; then
    export NODE_EXTRA_CA_CERTS="$SSL_CERT_FILE"
fi

# ---------------------------------------------------------------------------
# Keep child processes on Termux-native binaries
# ---------------------------------------------------------------------------
# If copilot is launched from a shell running under glibc-runner (`grun`), PATH
# starts with $PREFIX/glibc/bin and `bash`, `uname`, `ls` etc. resolve to GLIBC
# builds. Our LD_PRELOAD is a BIONIC shim needing libm.so, which those binaries
# then resolve from $PREFIX/glibc/lib/libm.so - a GNU ld script, not an ELF. So
# every shell command copilot runs dies with:
#
#     error while loading shared libraries: .../glibc/lib/libm.so:
#     invalid ELF header
#
# which surfaces in chat as "the bash environment is broken". Nothing is
# actually wrong with copilot or with Termux; the two libcs simply cannot be
# mixed in one process. Drop glibc entries so children get the Termux tools.
TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_DIR="${GLIBC_PREFIX:-$TERMUX_PREFIX/glibc}"
strip_glibc_from() {
    # $1 = a colon-separated path list; echoes it without $GLIBC_DIR entries
    local out="" part
    local IFS=':'
    for part in $1; do
        [ -n "$part" ] || continue
        case "$part" in
            "$GLIBC_DIR"|"$GLIBC_DIR"/*) continue ;;
        esac
        out="${out:+$out:}$part"
    done
    printf '%s' "$out"
}
case ":$PATH:" in
    *":$GLIBC_DIR/bin:"*|*":$GLIBC_DIR/"*)
        PATH="$(strip_glibc_from "$PATH")"
        case ":$PATH:" in
            *":$TERMUX_PREFIX/bin:"*) ;;
            *) PATH="${PATH:+$PATH:}$TERMUX_PREFIX/bin" ;;
        esac
        export PATH
        ;;
esac
if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    LD_LIBRARY_PATH="$(strip_glibc_from "$LD_LIBRARY_PATH")"
    if [ -n "$LD_LIBRARY_PATH" ]; then export LD_LIBRARY_PATH; else unset LD_LIBRARY_PATH; fi
fi
# These only tell child shells they are inside grun; the shell tool is not.
unset RUNNING_IN_GLIBC_RUNNER ENABLED_LIBTERMUX_EXEC_GLIBC 2>/dev/null || true

exec /data/data/com.termux/files/usr/bin/node "$ENTRY" "$@"
