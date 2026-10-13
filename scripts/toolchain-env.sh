#!/bin/bash
# Sets up a usable Swift 6.2 environment on a machine that has only the Xcode
# Command Line Tools (no full Xcode). Source it: `source scripts/toolchain-env.sh`
#
# Why this exists: the CLT-default `swift` (5.10) is rejected by the CLT SDK's
# Swift 6.0 module interfaces, so no Swift build works out of the box. We
# download the official Swift 6.2 toolchain, expand it WITHOUT sudo, pair it with
# the CLT SDK, and shim `ld` because the stock linker predates a flag Swift 6.2
# passes (-no_warn_duplicate_libraries).
set -euo pipefail

SWIFT_VERSION="${SWIFT_VERSION:-6.2}"
SWIFT_RELEASE="${SWIFT_RELEASE:-swift-6.2-RELEASE}"
ROOT="${DISKTRACE_TOOLCHAIN_DIR:-$HOME/.cache/disktrace-toolchain}"
PKG="$ROOT/$SWIFT_RELEASE-osx.pkg"
EXPANDED="$ROOT/expanded"
TC="$EXPANDED/swifttc/swift-${SWIFT_VERSION}-RELEASE-osx-package.pkg/Payload"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.0.sdk}"
URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/xcode/${SWIFT_RELEASE}/${SWIFT_RELEASE}-osx.pkg"

mkdir -p "$ROOT"

if [ -n "${DISKTRACE_SWIFT_TC:-}" ] && [ -x "${DISKTRACE_SWIFT_TC}/usr/bin/swift-frontend" ]; then
  # Reuse an already-expanded toolchain payload (path to the `.../Payload` dir).
  TC="$DISKTRACE_SWIFT_TC"
else
  if [ ! -f "$PKG" ]; then
    echo "Downloading $URL (~1.7 GB) ..." >&2
    curl -L --fail -o "$PKG" "$URL"
  fi

  if [ ! -x "$TC/usr/bin/swift-frontend" ]; then
    echo "Expanding toolchain into $EXPANDED (no sudo) ..." >&2
    rm -rf "$EXPANDED"
    mkdir -p "$EXPANDED"
    pkgutil --expand-full "$PKG" "$EXPANDED/swifttc"
  fi
fi

[ -e "$TC/usr/bin/swift" ] || ln -sf swift-frontend "$TC/usr/bin/swift"
[ -e "$TC/usr/bin/swiftc" ] || ln -sf swift-frontend "$TC/usr/bin/swiftc"

# ld wrapper: strip the flag the stock linker does not understand.
LD_SHIM="$ROOT/bin"
mkdir -p "$LD_SHIM"
cat > "$LD_SHIM/ld" <<'SHIM'
#!/bin/bash
args=()
for a in "$@"; do
  [ "$a" = "-no_warn_duplicate_libraries" ] && continue
  args+=("$a")
done
exec /usr/bin/ld "${args[@]}"
SHIM
chmod +x "$LD_SHIM/ld"

export PATH="$LD_SHIM:$TC/usr/bin:$PATH"
export SDKROOT="$SDK"
echo "Swift: $(swift --version | head -1)" >&2
echo "SDK:   $SDKROOT" >&2
