#!/usr/bin/env bash
# install-nodejs.sh - Install Node.js linux-arm64 with grun wrapper (L2 conditional)
# Extracted from install-glibc-env.sh — Node.js only, assumes glibc already installed.
# Called by orchestrator when config.env PLATFORM_NEEDS_NODEJS=true.
#
# What it does:
#   1. Download Node.js linux-arm64 LTS
#   2. Create grun-style wrapper scripts (ld.so direct execution)
#   3. Configure npm
#   4. Verify everything works
#
# patchelf is NOT used — Android seccomp causes SIGSEGV on patchelf'd binaries.
# All glibc binaries are executed via: exec ld.so binary "$@"
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

OPENCLAW_DIR="$HOME/.openclaw-android"
NODE_DIR="$OPENCLAW_DIR/node"
GLIBC_LDSO="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"

# Node.js LTS version to install (22.x LTS)
NODE_VERSION="22.14.0"
NODE_TARBALL="node-v${NODE_VERSION}-linux-arm64.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"

echo "=== Installing Node.js (glibc) ==="
echo ""

# ── Pre-checks ───────────────────────────────

if [ -z "${PREFIX:-}" ]; then
    echo -e "${RED}[FAIL]${NC} Not running in Termux (\$PREFIX not set)"
    exit 1
fi

if [ ! -x "$GLIBC_LDSO" ]; then
    echo -e "${RED}[FAIL]${NC} glibc dynamic linker not found — run install-glibc.sh first"
    exit 1
fi

# Check if already installed
if [ -x "$NODE_DIR/bin/node" ]; then
    if "$NODE_DIR/bin/node" --version &>/dev/null; then
        INSTALLED_VER=$("$NODE_DIR/bin/node" --version 2>/dev/null | sed 's/^v//')
        if [ "$INSTALLED_VER" = "$NODE_VERSION" ]; then
            echo -e "${GREEN}[SKIP]${NC} Node.js already installed (v${INSTALLED_VER})"
            exit 0
        fi
        LOWEST=$(printf '%s\n%s\n' "$INSTALLED_VER" "$NODE_VERSION" | sort -V | head -1)
        if [ "$LOWEST" = "$INSTALLED_VER" ] && [ "$INSTALLED_VER" != "$NODE_VERSION" ]; then
            echo -e "${YELLOW}[INFO]${NC} Node.js v${INSTALLED_VER} -> v${NODE_VERSION} (upgrading)"
        else
            echo -e "${GREEN}[SKIP]${NC} Node.js v${INSTALLED_VER} is newer than target v${NODE_VERSION}"
            exit 0
        fi
    else
        echo -e "${YELLOW}[INFO]${NC} Node.js exists but broken — reinstalling"
    fi
fi

# ── Step 1: Install Node.js ───────────────────

DOWNLOAD_REQUIRED=true
echo "Attempting to install Node.js via pacman (for 16KB alignment support)..."
if pacman -Sy nodejs --noconfirm --assume-installed bash,patchelf,resolv-conf 2>&1; then
    echo -e "${GREEN}[OK]${NC}   Node.js installed via pacman"
    GLIBC_BIN_DIR="$PREFIX/glibc/usr/bin"
    if [ -f "$GLIBC_BIN_DIR/node" ]; then
        mkdir -p "$NODE_DIR/bin"
        cp "$GLIBC_BIN_DIR/node" "$NODE_DIR/bin/node.real"
        echo -e "${GREEN}[OK]${NC}   Targeted pacman node binary"
        DOWNLOAD_REQUIRED=false
    fi
fi

if [ "$DOWNLOAD_REQUIRED" = true ]; then
    echo "Downloading Node.js v${NODE_VERSION} (linux-arm64)..."
    echo "  (File size ~25MB — may take a few minutes depending on network speed)"
    mkdir -p "$NODE_DIR"
    TMP_DIR=$(mktemp -d "$PREFIX/tmp/node-install.XXXXXX")
    trap 'rm -rf "$TMP_DIR"' EXIT
    if ! curl -fL --max-time 300 "$NODE_URL" -o "$TMP_DIR/$NODE_TARBALL"; then
        echo -e "${RED}[FAIL]${NC} Failed to download Node.js"
        exit 1
    fi
    tar -xJf "$TMP_DIR/$NODE_TARBALL" -C "$NODE_DIR" --strip-components=1
    mv "$NODE_DIR/bin/node" "$NODE_DIR/bin/node.real"
fi

# ── Step 2: Create wrapper scripts ────────────

echo ""
echo "Creating wrapper scripts (grun-style, no patchelf)..."

# Create node wrapper script
echo "Creating robust node wrapper..."

cat > "$NODE_DIR/bin/node" << 'WRAPPER'
#!/usr/bin/env bash
# Clear Bionic/Android variables to prevent crashes
unset LD_PRELOAD
unset LD_LIBRARY_PATH

_OA_COMPAT="$HOME/.openclaw-android/patches/glibc-compat.js"
if [ -f "$_OA_COMPAT" ]; then
    case "${NODE_OPTIONS:-}" in
        *"$_OA_COMPAT"*) ;;
        *) export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }-r $_OA_COMPAT" ;;
    esac
fi

# Fix leading options for glibc ld.so
_LEADING_OPTS=""
_COUNT=0
for _arg in "$@"; do
    case "$_arg" in --*) _COUNT=$((_COUNT + 1)) ;; *) break ;; esac
done
if [ $_COUNT -gt 0 ] && [ $_COUNT -lt $# ]; then
    while [ $# -gt 0 ]; do
        case "$1" in
            --*) _LEADING_OPTS="${_LEADING_OPTS:+$_LEADING_OPTS }$1"; shift ;;
            *) break ;;
        esac
    done
    export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }$_LEADING_OPTS"
fi

# Try grun first (official Termux-glibc runner), fallback to ld.so
LDSO="@@LDSO_PATH@@"
REAL_BINARY="$(dirname "$0")/node.real"

if command -v grun &>/dev/null; then
    exec grun "$REAL_BINARY" "$@"
elif [ -x "$LDSO" ]; then
    exec "$LDSO" "$REAL_BINARY" "$@"
else
    echo "ERROR: No glibc runner (grun or ld.so) found!" >&2
    exit 1
fi
WRAPPER

sed -i "s|@@LDSO_PATH@@|$GLIBC_LDSO|g" "$NODE_DIR/bin/node"
chmod +x "$NODE_DIR/bin/node"
chmod +x "$NODE_DIR/bin/node.real"
echo -e "${GREEN}[OK]${NC}   Node wrapper updated with grun support"

# npm is a JS script that uses the node from its own directory,
# so it automatically inherits the wrapper. No additional wrapping needed.
# Same for npx.

# ── Step 3: Configure npm ─────────────────────

echo ""
echo "Configuring npm..."

# Set script-shell to ensure npm lifecycle scripts use the correct shell
# On Android 9+, /bin/sh exists. On 7-8 it doesn't.
# Using $PREFIX/bin/sh is always safe.
export PATH="$NODE_DIR/bin:$PATH"
"$NODE_DIR/bin/npm" config set script-shell "$PREFIX/bin/sh" 2>/dev/null || true
echo -e "${GREEN}[OK]${NC}   npm script-shell set to $PREFIX/bin/sh"

# ── Step 4: Verify ────────────────────────────

echo ""
echo "Verifying glibc Node.js..."
echo "Files in $NODE_DIR/bin/:"
ls -l "$NODE_DIR/bin/"

echo "Architecture check:"
echo "  System: $(uname -m)"
echo "  Node Binary Info:"
# Check if readelf or file is available for more info
if command -v readelf &>/dev/null; then
    readelf -h "$NODE_DIR/bin/node.real" | grep -E 'Class|Machine' || echo "  (readelf failed)"
elif command -v file &>/dev/null; then
    file "$NODE_DIR/bin/node.real" || echo "  (file failed)"
else
    echo "  (No readelf/file command to check binary info)"
fi

echo "Linker check:"
if [ -x "$GLIBC_LDSO" ]; then
    echo -e "  ${GREEN}[OK]${NC} Linker exists: $GLIBC_LDSO"
else
    echo -e "  ${RED}[FAIL]${NC} Linker NOT FOUND or NOT EXECUTABLE at $GLIBC_LDSO"
fi

echo "Attempting to run node wrapper..."
# Run with explicit error output
if ! "$NODE_DIR/bin/node" --version; then
    echo ""
    echo -e "${RED}[FAIL]${NC} Node.js verification failed."
    # Specific check for common failures
    _ERR=$("$NODE_DIR/bin/node" --version 2>&1 || true)
    if echo "$_ERR" | grep -q "Exec format error"; then
        echo "--------------------------------------------------------"
        echo -e "${RED}ARCHITECTURE MISMATCH!${NC}"
        echo "The binary is likely 64-bit but you are on a 32-bit"
        echo "userland/system. Use 'uname -a' to check."
        echo "--------------------------------------------------------"
    elif echo "$_ERR" | grep -q "No such file or directory"; then
        echo "Possible missing shared library or broken linker path."
    fi
    exit 1
fi

NODE_VER=$("$NODE_DIR/bin/node" --version)
echo -e "${GREEN}[OK]${NC}   Node.js $NODE_VER (glibc, grun wrapper)"

NPM_VER=$("$NODE_DIR/bin/npm" --version 2>/dev/null || echo "unknown")
echo -e "${GREEN}[OK]${NC}   npm $NPM_VER"

# Quick platform check
PLATFORM=$("$NODE_DIR/bin/node" -e "console.log(process.platform)" 2>/dev/null || echo "unknown")
if [ "$PLATFORM" = "linux" ]; then
    echo -e "${GREEN}[OK]${NC}   platform: linux (correct)"
else
    echo -e "${YELLOW}[WARN]${NC} platform: ${PLATFORM:-unknown} (expected: linux)"
fi

echo ""
echo -e "${GREEN}Node.js installed successfully.${NC}"
echo "  Node.js: $NODE_VER ($NODE_DIR/bin/node)"
