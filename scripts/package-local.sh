#!/bin/bash
# Builds a local, ad-hoc-signed DiskTrace bundle with an embedded agent app.
#
#   scripts/package-local.sh --output <path> [--configuration debug|release] [--sign-identity -]
#
# Ad-hoc signing (`-`) is a LOCAL build only; it is NOT a distributable,
# notarized signature. Real distribution requires a Developer ID identity,
# hardened runtime and notarization (see docs/ORIGINAL_NEED_ACCEPTANCE.md).
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT="build/DiskTrace Local.app"
CONFIG="release"
IDENTITY="-"
while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT="$2"; shift 2;;
    --configuration) CONFIG="$2"; shift 2;;
    --sign-identity) IDENTITY="$2"; shift 2;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

source scripts/toolchain-env.sh >/dev/null 2>&1
echo "== building ($CONFIG) =="
swift build -c "$CONFIG"
BIN=".build/$CONFIG"

APP="$OUTPUT"
AGENT_APP="$APP/Contents/Library/LoginItems/DiskTraceAgent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$AGENT_APP/Contents/MacOS"
mkdir -p "$APP/Contents/Library/LaunchAgents"

cp "$BIN/DiskTraceApp" "$APP/Contents/MacOS/DiskTraceApp"
cp "$BIN/DiskTraceAgentApp" "$AGENT_APP/Contents/MacOS/DiskTraceAgent"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.disktrace.app</string>
  <key>CFBundleName</key><string>DiskTrace</string>
  <key>CFBundleExecutable</key><string>DiskTraceApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>local.disktrace.event</string>
    <key>CFBundleURLSchemes</key><array><string>disktrace</string></array>
  </dict></array>
</dict></plist>
PLIST

cat > "$AGENT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.disktrace.agent</string>
  <key>CFBundleName</key><string>DiskTraceAgent</string>
  <key>CFBundleExecutable</key><string>DiskTraceAgent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

cat > "$APP/Contents/Library/LaunchAgents/local.disktrace.agent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.disktrace.agent</string>
  <key>BundleProgram</key>
  <string>Contents/Library/LoginItems/DiskTraceAgent.app/Contents/MacOS/DiskTraceAgent</string>
  <key>ProgramArguments</key><array><string>DiskTraceAgent</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST

echo "== signing (identity: $IDENTITY) =="
codesign --force --sign "$IDENTITY" "$AGENT_APP"
codesign --force --sign "$IDENTITY" "$APP"
echo "== verifying =="
codesign --verify --deep --strict --verbose=1 "$APP" || true
echo "packaged: $APP"
