#!/bin/bash

# Ensure running under Termux
if [ -z "${TERMUX_VERSION:-}" ]; then
  echo "Error: This setup script must be run inside Termux (TERMUX_VERSION not set). Exiting." >&2
  exit 1
fi

set -e  # Exit on error
set -u  # Exit on undefined variable

# Detect architecture for Android platform string
ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64)
    ANDROID_ARCH="android-arm64"
    ;;
  x86_64|amd64)
    ANDROID_ARCH="android-x64"
    ;;
  i686|i386)
    ANDROID_ARCH="android-ia32"
    ;;
  armv7l|armv8l)
    ANDROID_ARCH="android-arm"
    ;;
  *)
    echo "Warning: Unknown architecture $ARCH, defaulting to android-arm64" >&2
    ANDROID_ARCH="android-arm64"
    ;;
esac

# Permanent backup directory for native prebuilds (survives npm updates)
BACKUP_DIR="$HOME/.copilot-termux-backups"

# Parse arguments: --update for quick update mode, path for install root override
UPDATE_MODE=false
POSITIONAL_ARG=""
for arg in "$@"; do
  case "$arg" in
    --update|-u) UPDATE_MODE=true ;;
    *) POSITIONAL_ARG="$arg" ;;
  esac
done

# Install root: allow override with positional argument, otherwise auto-detect from npm
if [ -n "$POSITIONAL_ARG" ]; then
  INSTALL_ROOT="$POSITIONAL_ARG"
else
  # Auto-detect: use npm root -g to find the actual global modules path
  # (handles custom prefix in ~/.npmrc e.g. ~/.npm-global)
  NPM_GLOBAL_ROOT="$(npm root -g 2>/dev/null || echo "${PREFIX}/lib/node_modules")"
  INSTALL_ROOT="${NPM_GLOBAL_ROOT}/@github/copilot"
fi

################################################################################
# UPDATE MODE: Quick update that backs up prebuilds, runs npm update, restores
#
# Usage: ./setup.sh --update
#
# IMPORTANT LEARNINGS (Termux/Android):
# - npm update/install of @github/copilot WIPES the prebuilds/ directory
# - The package does NOT ship android-arm64 prebuilds (only darwin/linux/win)
# - We must backup pty.node BEFORE update, then restore AFTER
# - The pty.node binary is arch-specific (ELF aarch64 for Android 24+)
# - Without pty.node, Copilot fails with: "Failed to load native module: pty.node"
################################################################################

if [ "$UPDATE_MODE" = true ]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  Copilot Termux Quick Update ($ANDROID_ARCH)"
  echo "═══════════════════════════════════════════════════════════"
  echo ""

  OLD_VERSION=$(npm list -g @github/copilot 2>/dev/null | grep copilot | sed 's/.*@//' || echo "unknown")
  echo "ℹ Current version: $OLD_VERSION"

  LATEST_VERSION=$(npm view @github/copilot version 2>/dev/null || echo "unknown")
  echo "ℹ Latest available: $LATEST_VERSION"

  if [ "$OLD_VERSION" = "$LATEST_VERSION" ]; then
    echo "✓ Already up to date ($OLD_VERSION)"
    exit 0
  fi

  # Step 1: Backup android prebuild
  mkdir -p "$BACKUP_DIR"
  PTY_SRC="$INSTALL_ROOT/prebuilds/$ANDROID_ARCH/pty.node"
  PTY_BACKUP="$BACKUP_DIR/pty.node.$ANDROID_ARCH"

  if [ -f "$PTY_SRC" ]; then
    cp "$PTY_SRC" "$PTY_BACKUP"
    echo "✓ Backed up pty.node to $PTY_BACKUP"
  elif [ -f "$PTY_BACKUP" ]; then
    echo "ℹ Using existing permanent backup at $PTY_BACKUP"
  else
    echo "⚠ No pty.node found to backup — will try to build after update"
  fi

  # Step 2: Run npm update
  # Use --force to bypass platform checks (e.g. @openai/codex requires os:linux
  # but Termux reports os:android — --force skips that validation)
  echo ""
  echo "▶ Updating @github/copilot..."
  if npm update -g @github/copilot --force 2>&1 | grep -v "^npm warn using --force"; then
    echo "✓ npm update succeeded"
  else
    echo "✗ npm update failed"
    exit 1
  fi

  # Step 3: Restore android prebuild (npm wipes it!)
  PREBUILD_DIR="$INSTALL_ROOT/prebuilds/$ANDROID_ARCH"
  mkdir -p "$PREBUILD_DIR"

  if [ -f "$PTY_BACKUP" ]; then
    cp "$PTY_BACKUP" "$PREBUILD_DIR/pty.node"
    echo "✓ Restored pty.node to $PREBUILD_DIR/pty.node"
  else
    echo "⚠ No pty.node backup available — attempting rebuild..."
    cd "$INSTALL_ROOT"
    if npm install node-pty 2>/dev/null && [ -f "node_modules/node-pty/build/Release/pty.node" ]; then
      cp "node_modules/node-pty/build/Release/pty.node" "$PREBUILD_DIR/pty.node"
      cp "$PREBUILD_DIR/pty.node" "$PTY_BACKUP" 2>/dev/null || true
      echo "✓ Rebuilt and installed pty.node"
    else
      echo "✗ Failed to rebuild pty.node — run full setup: ./setup.sh"
      exit 1
    fi
  fi

  # Step 4: Patch native runtime + JS platform allowlist (required since 1.0.46+)
  #
  # 1.0.46–1.0.47 layout:
  #   native/runtime/runtime.<plat>-<libc>.node — musl variant shipped.
  #   Patch: copy musl→android-arm64, patchelf --add-needed libm.so.
  #
  # 1.0.48+ layout:
  #   prebuilds/<plat>/runtime.node — glibc-only, depends on libgcc_s/libpthread/libdl.
  #   Patch: copy linux-arm64→android-arm64, strip GLIBC symbol versions
  #          (python3 strip_verneed.py), remove libgcc_s/libpthread/libdl NEEDED,
  #          rename libc.so.6→libc.so / libm.so.6→libm.so.
  #   Also: index.js + app.js have a libc-variant helper that throws
  #         "Unsupported platform" on android — patch via patch_js.py.
  #
  # Both layouts need the LD_PRELOAD shim (libbionic_shim.so) at runtime to
  # provide bcmp, __xpg_strerror_r, __errno_location, __xstat64-family,
  # __assert_fail, __ctype_b_loc, and statically-linked _Unwind_*.

  SHIM_DIR="$HOME/.copilot-versions/shim"
  SHIM_LIB="$SHIM_DIR/libbionic_shim.so"
  SHIM_SRC="$SHIM_DIR/bionic_shim.c"
  STRIP_PY="$SHIM_DIR/strip_verneed.py"
  PATCH_JS_PY="$SHIM_DIR/patch_js.py"
  LIBUNWIND="/data/data/com.termux/files/usr/lib/libunwind.a"

  # ---- Build / refresh the shim ----
  if ! command -v clang >/dev/null 2>&1; then
    echo "⚠ clang missing — skipping shim rebuild"
  elif [ ! -f "$SHIM_LIB" ] || [ "$SHIM_SRC" -nt "$SHIM_LIB" ]; then
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
      echo "✓ Rebuilt bionic shim (with libunwind)"
    else
      clang -O2 -shared -fPIC -fvisibility=default -Wl,--no-as-needed -lm \
        -o "$SHIM_LIB" "$SHIM_SRC" 2>/dev/null
      echo "✓ Rebuilt bionic shim (no libunwind — 1.0.48+ needs it; pkg install ndk-sysroot)"
    fi
  fi

  if ! command -v patchelf >/dev/null 2>&1; then
    echo "✗ patchelf required. Install: pkg install patchelf"
    exit 1
  fi

  # ---- Layout detection + runtime patching ----
  NEW_SRC="$INSTALL_ROOT/prebuilds/linux-arm64/runtime.node"
  OLD_SRC="$INSTALL_ROOT/native/runtime/runtime.linux-arm64-musl.node"

  if [ -f "$NEW_SRC" ]; then
    # 1.0.48+ layout
    if [ ! -f "$STRIP_PY" ]; then
      echo "✗ strip_verneed.py missing at $STRIP_PY — run full setup first"
      exit 1
    fi
    DST_DIR="$INSTALL_ROOT/prebuilds/$ANDROID_ARCH"
    DST="$DST_DIR/runtime.node"
    mkdir -p "$DST_DIR"
    cp -f "$NEW_SRC" "$DST"
    python3 "$STRIP_PY" "$DST" >/dev/null
    patchelf --remove-needed libgcc_s.so.1 "$DST" 2>/dev/null
    patchelf --remove-needed libpthread.so.0 "$DST" 2>/dev/null
    patchelf --remove-needed libdl.so.2 "$DST" 2>/dev/null
    patchelf --replace-needed libc.so.6 libc.so "$DST" 2>/dev/null
    patchelf --replace-needed libm.so.6 libm.so "$DST" 2>/dev/null
    echo "✓ Patched runtime.node ($ANDROID_ARCH, 1.0.48+ layout)"

    if [ -f "$PATCH_JS_PY" ]; then
      python3 "$PATCH_JS_PY" "$INSTALL_ROOT" >/dev/null
      echo "✓ Patched index.js + app.js Unsupported-platform throw"
    else
      echo "⚠ patch_js.py missing — copilot will throw 'Unsupported platform: android/arm64' until you create it"
    fi
  elif [ -f "$OLD_SRC" ]; then
    # 1.0.46–1.0.47 layout
    DST="$INSTALL_ROOT/native/runtime/runtime.android-arm64.node"
    cp -f "$OLD_SRC" "$DST"
    patchelf --add-needed libm.so "$DST"
    echo "✓ Patched runtime.android-arm64.node (1.0.46/47 layout)"
  else
    echo "ℹ No native runtime to patch (pre-1.0.46 or future layout — check $INSTALL_ROOT)"
  fi

  # Warn if wrapper is missing
  if [ ! -x "$HOME/.local/bin/copilot" ]; then
    echo "⚠ Copilot wrapper missing at ~/.local/bin/copilot — native runtime needs LD_PRELOAD"
  fi

  # Step 5: Verify
  NEW_VERSION=$("$HOME/.local/bin/copilot" --version 2>&1 | grep -oP '[\d.]+' | head -1 || echo "unknown")
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  ✓ Updated: $OLD_VERSION → $NEW_VERSION"
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  exit 0
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Module status tracking
MODULES_FIXED=0
MODULES_FAILED=0

################################################################################
# HELPER FUNCTIONS
################################################################################

# Print colored status messages
print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
    MODULES_FIXED=$((MODULES_FIXED+1))
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
    MODULES_FAILED=$((MODULES_FAILED+1))
}

print_step() {
    echo ""
    echo -e "${GREEN}▶${NC} ${BLUE}$1${NC}"
    echo ""
}

# Ensure a pkg package is installed only if missing; can check by command or pkg list-installed
ensure_pkg() {
  local pkgname="$1"
  local check_cmd="${2:-}"

  if [ -n "$check_cmd" ]; then
    if command -v "$check_cmd" >/dev/null 2>&1; then
      print_info "$pkgname (command $check_cmd) already available at $(command -v $check_cmd)"
      return 0
    fi
  else
    if pkg list-installed "$pkgname" >/dev/null 2>&1; then
      print_info "$pkgname already installed according to pkg"
      return 0
    fi
  fi

  print_info "Installing $pkgname"
  if pkg install -y "$pkgname"; then
    print_success "$pkgname installed"
  else
    print_error "Failed to install $pkgname"
    return 1
  fi
}

################################################################################
# MAIN INSTALLATION SCRIPT
################################################################################

print_header "GitHub Copilot CLI on Termux"

echo "This script will install Github Copilot CLI and 4 native modules:"
echo ""
echo "  1. node-pty     - Pseudo-terminal for command execution"
echo "  2. sharp        - Image processing library"
echo "  3. keytar       - Secure credential storage"
echo "  4. clipboard    - System clipboard access (Termux API wrapper)"
echo ""
echo "Termux ${TERMUX_VERSION:-unknown} ($ANDROID_ARCH)"
echo ""

if [ -t 0 ]; then
    read -p "Press Enter to continue or Ctrl+C to abort..."
fi

################################################################################
# STEP 0: Update package repositories and install Node.js
################################################################################

print_header "Updating Termux packages and installing Node.js"

print_info "Running pkg update"
pkg update -y || print_warning "pkg update failed, continuing anyway"

print_info "Installing core build dependencies"
ensure_pkg nodejs node
ensure_pkg clang clang
ensure_pkg make make
ensure_pkg python python

# Create .gyp configuration for node-gyp (fixes android ndk path issues)
# Non-destructive: only create if missing
GYP_FILE="$HOME/.gyp/include.gypi"
if [ ! -f "$GYP_FILE" ]; then
    print_info "Creating ~/.gyp/include.gypi for node-gyp compatibility"
    mkdir -p ~/.gyp
    echo "{'variables':{'android_ndk_path':''}}" > "$GYP_FILE"
    print_info "Created gyp configuration"
else
    print_info "~/.gyp/include.gypi already exists, skipping"
fi

################################################################################
# STEP 1: Ensure GitHub Copilot CLI installed globally
################################################################################

print_step "Step 1/13: Installing GitHub Copilot CLI globally"

print_info "Running npm install -g @github/copilot to ensure CLI is present"
if npm install -g @github/copilot; then
    print_info "GitHub Copilot CLI installed globally"
else
    print_error "Failed to install GitHub Copilot CLI globally"
    exit 1
fi

if [ ! -d "$INSTALL_ROOT" ]; then
    print_error "Install root not found at $INSTALL_ROOT after global install"
    exit 1
fi

cd "$INSTALL_ROOT"

print_step "Step 2/13: Installing system dependencies"

ensure_pkg glib
ensure_pkg xorgproto
ensure_pkg rust rustc
ensure_pkg libvips
ensure_pkg pkg-config pkg-config
ensure_pkg ripgrep rg

print_success "System dependencies installed successfully"

# Ensure packaged ripgrep is available system-wide if no system 'rg' exists.
# Idempotent: only creates a symlink when needed and won't overwrite existing files.
RIPGREP_SRC="$(find "$INSTALL_ROOT/ripgrep" -type f -name 'rg' -perm /111 2>/dev/null | head -n1 || true)"
if [ -z "$RIPGREP_SRC" ]; then
    print_warning "No packaged ripgrep binary found; skipping rg symlink"
else
    # Use PREFIX for proper Termux bin directory, fallback to hardcoded path
    TARGET_RG="${PREFIX:-/data/data/com.termux/files/usr}/bin/rg"
    if command -v rg >/dev/null 2>&1; then
        print_info "System 'rg' already available at $(command -v rg); leaving system ripgrep intact"
    else
        mkdir -p "$(dirname "$TARGET_RG")"
        if [ -L "$TARGET_RG" ]; then
            if [ "$(readlink -f "$TARGET_RG")" = "$RIPGREP_SRC" ]; then
                print_info "rg symlink already points to packaged ripgrep"
            else
                print_warning "rg symlink exists and points elsewhere; skipping to avoid overwrite"
            fi
        elif [ -e "$TARGET_RG" ]; then
            print_warning "An executable named 'rg' exists at $TARGET_RG; skipping symlink"
        else
            ln -sf "$RIPGREP_SRC" "$TARGET_RG" && print_success "Linked packaged ripgrep to $TARGET_RG"
        fi
    fi
fi

# Link system ripgrep to the Copilot expected path
COPILOT_RG_DIR="$INSTALL_ROOT/ripgrep/bin/$ANDROID_ARCH"
COPILOT_RG_PATH="$COPILOT_RG_DIR/rg"
SYSTEM_RG="$(command -v rg 2>/dev/null || true)"

if [ -n "$SYSTEM_RG" ]; then
    mkdir -p "$COPILOT_RG_DIR"
    if [ ! -e "$COPILOT_RG_PATH" ]; then
        ln -sf "$SYSTEM_RG" "$COPILOT_RG_PATH" && print_success "Linked system rg to Copilot expected path"
    elif [ -L "$COPILOT_RG_PATH" ] && [ "$(readlink -f "$COPILOT_RG_PATH")" = "$SYSTEM_RG" ]; then
        print_info "Copilot rg symlink already correct"
    else
        print_warning "Copilot rg path exists; skipping"
    fi
else
    print_warning "No system rg found; Copilot may fail to use ripgrep"
fi

print_step "Step 3/13: Installing node-pty"

if npm install node-pty; then
    print_success "node-pty installed successfully"
    
    # Verify the build
    if [ -f "node_modules/node-pty/build/Release/pty.node" ]; then
        print_success "pty.node binary found"
    else
        print_error "pty.node binary not found after installation"
        exit 1
    fi
else
    print_error "Failed to install node-pty"
    exit 1
fi

print_step "Step 4/13: Installing node-addon-api and keytar"

npm install node-addon-api@latest --save-dev
if npm install keytar --ignore-scripts; then
    print_success "keytar package downloaded"
else
    print_error "Failed to install keytar package"
    exit 1
fi


print_step "Step 5/13: Patching node-addon-api enum handling"
find node_modules -name "napi.h" | while read -r NAPI_HEADER; do
    if grep -q "static_cast<napi_typedarray_type>(-1)" "$NAPI_HEADER"; then
        cp "$NAPI_HEADER" "$NAPI_HEADER.backup"
        if sed -i 's/static_cast<napi_typedarray_type>(-1)/napi_uint8_array/' "$NAPI_HEADER"; then
            print_success "Patched $NAPI_HEADER"
        else
            print_error "Failed to patch $NAPI_HEADER"
        fi
    fi
done

print_step "Step 6/13: Installing sharp"
if npm install sharp; then
    print_success "sharp installed and compiled successfully"
else
    print_error "Failed to install sharp"
    print_warning "Copilot CLI will work but without image processing features"
fi

print_step "Step 7/13: Building keytar with patched dependencies"

cd node_modules/keytar

if npm run build; then
    print_success "keytar compiled successfully"
else
    print_error "Failed to compile keytar"
    cd ../..
    exit 1
fi

cd ../..

print_step "Step 8/13: Installing termux-api for clipboard support"
ensure_pkg termux-api termux-clipboard-get

print_step "Step 9/13: Setting up clipboard (Termux API wrapper)"
if [ ! -f "clipboard/index.cjs" ] || [ ! -f "clipboard/android-impl.cjs" ]; then
    mkdir -p clipboard
    if [ ! -f "clipboard/index.cjs" ]; then
        cat > clipboard/index.cjs <<'IDX'
const os = require('os');

if (os.platform() === 'android' || process.env.PREFIX?.includes('com.termux')) {
  module.exports = require('./android-impl.cjs');
} else {
  try {
    module.exports = require('../@teddyzhu/clipboard');
  } catch (e) {
    console.error('Native clipboard module not available, falling back to Android implementation');
    module.exports = require('./android-impl.cjs');
  }
}
IDX
    fi
    if [ ! -f "clipboard/android-impl.cjs" ]; then
        cat > clipboard/android-impl.cjs <<'AIDX'
const { execSync, exec } = require('child_process');
const { promisify } = require('util');
const execAsync = promisify(exec);

class ClipboardManager {
  constructor() {
    try {
      execSync('which termux-clipboard-get', { stdio: 'ignore' });
      execSync('which termux-clipboard-set', { stdio: 'ignore' });
    } catch (e) {
      throw new Error('Termux API not installed. Run: pkg install termux-api');
    }
  }

  getText() {
    try {
      return execSync('termux-clipboard-get').toString();
    } catch (e) {
      throw new Error(`Failed to get text: ${e.message}`);
    }
  }

  setText(text) {
    try {
      execSync(`termux-clipboard-set`, { input: text });
    } catch (e) {
      throw new Error(`Failed to set text: ${e.message}`);
    }
  }

  async getTextAsync() {
    try {
      const { stdout } = await execAsync('termux-clipboard-get');
      return stdout;
    } catch (e) {
      throw new Error(`Failed to get text: ${e.message}`);
    }
  }

  async setTextAsync(text) {
    try {
      await execAsync('termux-clipboard-set', { input: text });
    } catch (e) {
      throw new Error(`Failed to set text: ${e.message}`);
    }
  }

  getHtml() {
    throw new Error('HTML clipboard not supported on Android/Termux');
  }

  setHtml() {
    throw new Error('HTML clipboard not supported on Android/Termux');
  }

  getRichText() {
    throw new Error('Rich text clipboard not supported on Android/Termux');
  }

  setRichText() {
    throw new Error('Rich text clipboard not supported on Android/Termux');
  }

  getImageBase64() {
    throw new Error('Image clipboard not supported on Android/Termux');
  }

  getImageData() {
    throw new Error('Image clipboard not supported on Android/Termux');
  }

  setImageBase64() {
    throw new Error('Image clipboard not supported on Android/Termux');
  }

  setImageRaw() {
    throw new Error('Image clipboard not supported on Android/Termux');
  }

  getImageRaw() {
    throw new Error('Image clipboard not supported on Android/Termux');
  }

  getFiles() {
    throw new Error('Files clipboard not supported on Android/Termux');
  }

  setFiles() {
    throw new Error('Files clipboard not supported on Android/Termux');
  }

  setBuffer() {
    throw new Error('Custom buffer clipboard not supported on Android/Termux');
  }

  getBuffer() {
    throw new Error('Custom buffer clipboard not supported on Android/Termux');
  }

  setContents(contents) {
    if (contents.text) {
      return this.setText(contents.text);
    }
    throw new Error('Only text content is supported on Android/Termux');
  }

  hasFormat(format) {
    return format === 'text';
  }

  getAvailableFormats() {
    return ['text'];
  }

  clear() {
    try {
      execSync('termux-clipboard-set', { input: '' });
    } catch (e) {
      throw new Error(`Failed to clear clipboard: ${e.message}`);
    }
  }
}

class ClipboardListener {
  constructor() {
    this.watchProcess = null;
    this.lastContent = '';
    this.callbacks = [];
  }

  watch(callback) {
    if (this.watchProcess) {
      this.stop();
    }

    this.callbacks.push(callback);
    
    this.lastContent = '';
    try {
      this.lastContent = execSync('termux-clipboard-get').toString();
    } catch (e) {
      // Ignore initial read errors
    }

    this.watchProcess = setInterval(() => {
      try {
        const currentContent = execSync('termux-clipboard-get').toString();
        if (currentContent !== this.lastContent) {
          this.lastContent = currentContent;
          const clipboardData = {
            availableFormats: ['text'],
            text: currentContent,
            rtf: null,
            html: null,
            image: null,
            files: null,
            files: null
          };
          this.callbacks.forEach(cb => {
            try {
              cb(clipboardData);
            } catch (e) {
              console.error('Clipboard callback error:', e);
            }
          });
        }
      } catch (e) {
        // Ignore polling errors
      }
    }, 500);
  }

  stop() {
    if (this.watchProcess) {
      clearInterval(this.watchProcess);
      this.watchProcess = null;
    }
    this.callbacks = [];
  }

  isWatching() {
    return this.watchProcess !== null;
  }

  getListenerType() {
    return 'android-termux-api';
  }
}

function getClipboardText() {
  try {
    return execSync('termux-clipboard-get').toString();
  } catch (e) {
    throw new Error(`Failed to get text: ${e.message}`);
  }
}

function setClipboardText(text) {
  try {
    execSync('termux-clipboard-set', { input: text });
  } catch (e) {
    throw new Error(`Failed to set text: ${e.message}`);
  }
}

function clearClipboard() {
  try {
    execSync('termux-clipboard-set', { input: '' });
  } catch (e) {
    throw new Error(`Failed to clear clipboard: ${e.message}`);
  }
}

function isWaylandClipboardAvailable() {
  return false;
}

module.exports = {
  ClipboardManager,
  ClipboardListener,
  getClipboardText,
  setClipboardText,
  clearClipboard,
  isWaylandClipboardAvailable
};
AIDX
    fi
fi

npm install @teddyzhu/clipboard --ignore-scripts 2>/dev/null || true
[ -f "clipboard/index.cjs" ] && print_success "Clipboard wrapper installed" || print_warning "Clipboard wrapper not found"

print_step "Step 10/13: Symlinking compiled binaries to prebuilds directory"

mkdir -p "prebuilds/$ANDROID_ARCH"
KEYTAR_PATH="$INSTALL_ROOT/node_modules/keytar/build/Release/keytar.node"
PTY_PATH="$INSTALL_ROOT/node_modules/node-pty/build/Release/pty.node"

[ -f "$KEYTAR_PATH" ] && ln -sf "$KEYTAR_PATH" "prebuilds/$ANDROID_ARCH/keytar.node" && print_success "keytar.node symlinked" || { print_error "keytar.node not found"; exit 1; }
[ -f "$PTY_PATH" ] && ln -sf "$PTY_PATH" "prebuilds/$ANDROID_ARCH/pty.node" && print_success "pty.node symlinked" || { print_error "pty.node not found"; exit 1; }

# Save permanent backups so future --update can restore without rebuilding
mkdir -p "$BACKUP_DIR"
[ -f "$KEYTAR_PATH" ] && cp "$KEYTAR_PATH" "$BACKUP_DIR/keytar.node.$ANDROID_ARCH" && print_success "keytar.node permanent backup saved"
[ -f "$PTY_PATH" ] && cp "$PTY_PATH" "$BACKUP_DIR/pty.node.$ANDROID_ARCH" && print_success "pty.node permanent backup saved"
print_info "Permanent backups at $BACKUP_DIR (survive npm updates)"

print_step "Step 11/13: Installing native runtime patch (1.0.46+ compat)"

# @github/copilot 1.0.46 introduced native/runtime/ (Rust napi-rs binding) with no Android target.
# We create a bionic compatibility shim and patch the musl binary to work on Android.
ensure_pkg patchelf patchelf

SHIM_DIR="$HOME/.copilot-versions/shim"
SHIM_SRC="$SHIM_DIR/bionic_shim.c"
SHIM_LIB="$SHIM_DIR/libbionic_shim.so"
RT_DIR="$INSTALL_ROOT/native/runtime"
RT_MUSL="$RT_DIR/runtime.linux-arm64-musl.node"
RT_TARGET="$RT_DIR/runtime.android-arm64.node"

mkdir -p "$SHIM_DIR"

# Write bionic shim source if not present
if [ ! -f "$SHIM_SRC" ]; then
  cat > "$SHIM_SRC" << 'SHIMEOF'
#include <string.h>
#include <stddef.h>
#include <errno.h>

/* bcmp: deprecated POSIX function. musl libc still uses it; bionic doesn't export it. */
int bcmp(const void *s1, const void *s2, size_t n) {
    return memcmp(s1, s2, n);
}

/* __xpg_strerror_r: glibc/musl's XPG-compliant int-returning strerror_r alias.
 * Bionic only exports the POSIX strerror_r (int return), so forward to it. */
extern int strerror_r(int, char *, size_t);
int __xpg_strerror_r(int errnum, char *buf, size_t buflen) {
    return strerror_r(errnum, buf, buflen);
}

/* __errno_location: glibc/musl use this name; bionic exports __errno() returning the same. */
extern int *__errno(void);
int *__errno_location(void) {
    return __errno();
}
SHIMEOF
  print_success "Created bionic shim source"
fi

# Compile shim
if [ ! -f "$SHIM_LIB" ] || [ "$SHIM_SRC" -nt "$SHIM_LIB" ]; then
  if clang -O2 -shared -fPIC -fvisibility=default -Wl,--no-as-needed -lm \
      -o "$SHIM_LIB" "$SHIM_SRC"; then
    print_success "Compiled bionic shim → $SHIM_LIB"
  else
    print_error "Failed to compile bionic shim"
  fi
else
  print_info "Bionic shim already compiled"
fi

# Patch native runtime
if [ -d "$RT_DIR" ] && [ -f "$RT_MUSL" ]; then
  cp -f "$RT_MUSL" "$RT_TARGET"
  if patchelf --add-needed libm.so "$RT_TARGET"; then
    print_success "Patched native runtime → runtime.android-arm64.node"
  else
    print_error "Failed to patchelf native runtime"
  fi
else
  print_warning "native/runtime/ not found — may not be needed for this version"
fi

print_step "Step 12/13: Installing copilot wrapper (LD_PRELOAD launcher)"

# The wrapper ensures LD_PRELOAD is set for the bionic shim and self-heals if
# npm update wipes the patched runtime. Must be in PATH before ~/.npm-global/bin.
WRAPPER_DIR="$HOME/.local/bin"
WRAPPER_PATH="$WRAPPER_DIR/copilot"
mkdir -p "$WRAPPER_DIR"

cat > "$WRAPPER_PATH" << 'WRAPEOF'
#!/usr/bin/env bash
# GitHub Copilot CLI launcher with Termux/bionic compat patches.
# Background: 1.0.46 introduced @copilot/runtime-native (Rust napi-rs binding) used by
# MCP config + session FS. Its build matrix has no Android target. Two patches restore it:
#   1. LD_PRELOAD libbionic_shim.so — shims bcmp/__xpg_strerror_r/__errno_location.
#   2. native/runtime/runtime.android-arm64.node — a patchelf'd copy of the musl variant
#      with libm.so added as NEEDED (bionic separates libc/libm; musl bundles them).
# If npm reinstalls @github/copilot, runtime.android-arm64.node is wiped — this wrapper
# self-heals on launch.

SHIM_DIR="$HOME/.copilot-versions/shim"
SHIM_LIB="$SHIM_DIR/libbionic_shim.so"
COPILOT_PKG="$HOME/.npm-global/lib/node_modules/@github/copilot"
RT_DIR="$COPILOT_PKG/native/runtime"
RT_TARGET="$RT_DIR/runtime.android-arm64.node"
RT_SRC="$RT_DIR/runtime.linux-arm64-musl.node"
NPM_LOADER="$COPILOT_PKG/npm-loader.js"

# Self-heal: rebuild patched runtime if missing or stale.
if [ ! -f "$RT_TARGET" ] || [ "$RT_SRC" -nt "$RT_TARGET" ]; then
    if [ -f "$RT_SRC" ]; then
        cp -f "$RT_SRC" "$RT_TARGET"
        patchelf --add-needed libm.so "$RT_TARGET" 2>/dev/null
    else
        echo "[copilot-wrapper] runtime musl source missing: $RT_SRC" >&2
        echo "[copilot-wrapper] You likely have an incompatible copilot version." >&2
    fi
fi

# Self-heal: rebuild shim if missing.
if [ ! -f "$SHIM_LIB" ]; then
    if [ -f "$SHIM_DIR/bionic_shim.c" ] && command -v clang >/dev/null 2>&1; then
        clang -O2 -shared -fPIC -fvisibility=default -Wl,--no-as-needed -lm \
            -o "$SHIM_LIB" "$SHIM_DIR/bionic_shim.c" 2>/dev/null
    fi
fi

# Compose LD_PRELOAD without nuking caller's value.
if [ -f "$SHIM_LIB" ]; then
    if [ -n "${LD_PRELOAD:-}" ]; then
        export LD_PRELOAD="$SHIM_LIB:$LD_PRELOAD"
    else
        export LD_PRELOAD="$SHIM_LIB"
    fi
fi

exec /data/data/com.termux/files/usr/bin/node "$NPM_LOADER" "$@"
WRAPEOF

chmod +x "$WRAPPER_PATH"
print_success "Installed copilot wrapper → $WRAPPER_PATH"

# Ensure ~/.local/bin is in PATH (add to .bashrc if not already there)
if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
  if ! grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    print_info "Added ~/.local/bin to PATH in .bashrc"
  fi
  export PATH="$HOME/.local/bin:$PATH"
fi

print_step "Step 13/13: Verifying installation"

cat > test-native-modules-install.mjs << 'TESTEOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);

let passed = 0;
let failed = 0;

console.log("\nTesting native modules...\n");

// Test keytar
try {
  const keytar = require('keytar');
  console.log("✓ keytar loaded successfully");
  passed++;
} catch (e) {
  console.log("✗ keytar failed:", e.message);
  failed++;
}

// Test node-pty
try {
  const pty = require('node-pty');
  console.log("✓ node-pty loaded successfully");
  passed++;
} catch (e) {
  console.log("✗ node-pty failed:", e.message);
  failed++;
}

// Test sharp
try {
  const sharp = require('sharp');
  console.log("✓ sharp loaded successfully");
  passed++;
} catch (e) {
  console.log("✗ sharp failed:", e.message);
  failed++;
}

// Test clipboard (check if wrapper exists)
try {
  const fs = require('fs');
  if (fs.existsSync('./clipboard/index.cjs')) {
    console.log("✓ clipboard wrapper available");
    passed++;
  } else {
    console.log("⚠ clipboard wrapper not found");
    failed++;
  }
} catch (e) {
  console.log("✗ clipboard check failed:", e.message);
  failed++;
}

console.log(`\nResults: ${passed} passed, ${failed} failed\n`);
process.exit(failed > 0 ? 1 : 0);
TESTEOF

node test-native-modules-install.mjs && print_success "All module tests passed!" || print_warning "Some modules failed to load"
rm -f test-native-modules-install.mjs

print_header "Installation Summary"

echo "Installed Packages:"
echo "  • nodejs, clang, make, python"
echo "  • glib, xorgproto, rust, libvips, pkg-config"
echo "  • ripgrep, termux-api, patchelf"
echo ""
echo "Native Modules Built:"
echo "  • keytar (credential storage)"
echo "  • node-pty (terminal/command execution)"
echo "  • sharp (image processing)"
echo "  • clipboard wrapper (Termux API integration)"
echo ""
echo "Runtime Patches Applied:"
echo "  • Bionic shim (bcmp/__xpg_strerror_r/__errno_location)"
echo "  • native/runtime/runtime.android-arm64.node (patchelf'd musl → bionic)"
echo "  • Self-healing wrapper at ~/.local/bin/copilot"
echo ""
echo "Modified Files:"
echo "  • ~/.gyp/include.gypi (node-gyp config)"
echo "  • ~/.copilot-versions/shim/ (bionic compat shim)"
echo "  • ~/.local/bin/copilot (launcher wrapper)"
echo "  • Patched node-addon-api enum handling"
echo "  • Created clipboard/index.cjs and clipboard/android-impl.cjs"
echo "  • Symlinked prebuilds/$ANDROID_ARCH/keytar.node"
echo "  • Symlinked prebuilds/$ANDROID_ARCH/pty.node"
echo "  • Symlinked ripgrep to Copilot expected path"
echo ""

print_header "Installation Complete!"
echo "Run 'copilot' to start (uses wrapper at ~/.local/bin/copilot)"
echo "Run './setup.sh --update' anytime to update to the latest version"
echo ""

echo "GitHub Copilot CLI is ready on Android/Termux ($ANDROID_ARCH)"
echo ""
echo "Next steps:"
echo "  1. Launch Copilot: copilot"
echo "  2. Sign in: /login"
echo "  3. Start coding with AI assistance!"
echo ""

print_success "Setup completed successfully!"

exit 0
