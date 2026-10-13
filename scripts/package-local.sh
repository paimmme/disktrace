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

# Validate before touching an existing output. Build only in a unique staging.
OUTPUT="$(python3 - "$OUTPUT" <<'PYVALIDATE'
import sys, pathlib, plistlib
p=pathlib.Path(sys.argv[1]).absolute()
if p.suffix != '.app' or any(x.is_symlink() for x in [p,*p.parents]):
    raise SystemExit('Refusing non-.app output or symlink path')
repo=pathlib.Path.cwd().resolve()
if p == repo or p in repo.parents or p == pathlib.Path.home():
    raise SystemExit('Refusing repository/home/ancestor output')
if p.exists():
    try:
        info=plistlib.loads((p/'Contents/Info.plist').read_bytes())
        assert info.get('CFBundleIdentifier')=='local.disktrace.app'
    except Exception: raise SystemExit('Existing output is not the DiskTrace app; preserving it')
print(p)
PYVALIDATE
)"
if [ "${DISKTRACE_VALIDATE_OUTPUT_ONLY:-0}" = "1" ]; then echo "$OUTPUT"; exit 0; fi
source scripts/toolchain-env.sh >/dev/null 2>&1
echo "== building ($CONFIG) =="
swift build -c "$CONFIG"
BIN=".build/$CONFIG"

PARENT="$(dirname "$OUTPUT")"
mkdir -p "$PARENT"
STAGING="$(mktemp -d "$PARENT/.disktrace-package.XXXXXX")"
trap 'if [[ "$STAGING" == "$PARENT"/.disktrace-package.* ]]; then rm -rf -- "$STAGING"; fi' EXIT
APP="$STAGING/DiskTrace Local.app"
AGENT_APP="$APP/Contents/Library/LoginItems/DiskTraceAgent.app"
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
  <key>CFBundleShortVersionString</key><string>0.2.1</string>
  <key>CFBundleVersion</key><string>2</string>
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
  <key>CFBundleShortVersionString</key><string>0.2.1</string>
  <key>CFBundleVersion</key><string>2</string>
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
AGENT_SIGN=$?
codesign --force --sign "$IDENTITY" "$APP"
APP_SIGN=$?
echo "codesign exit codes: agent=$AGENT_SIGN app=$APP_SIGN"
if [ "$AGENT_SIGN" -ne 0 ] || [ "$APP_SIGN" -ne 0 ]; then
  echo "ERROR: codesign failed (agent=$AGENT_SIGN app=$APP_SIGN)" >&2
  exit 1
fi

echo "== verifying (strict) =="
if ! codesign --verify --deep --strict --verbose=2 "$APP"; then
  echo "ERROR: codesign --verify --deep --strict FAILED — bundle is not validly signed" >&2
  exit 1
fi
codesign -dvvv "$APP" 2>&1 | sed -n '1,12p'
if [ -e "$OUTPUT" ]; then
  BACKUP="${OUTPUT%.app}.previous-$(date -u +%Y%m%dT%H%M%SZ)-$$.app"
  mv -- "$OUTPUT" "$BACKUP"
  if ! mv -- "$APP" "$OUTPUT"; then mv -- "$BACKUP" "$OUTPUT"; exit 1; fi
  echo "previous app preserved: $BACKUP"
else
  mv -- "$APP" "$OUTPUT"
fi
echo "packaged: $OUTPUT"
echo "NOTE: ad-hoc ('-') signature is for LOCAL use only; distribution requires a"
echo "      Developer ID identity, hardened runtime and notarization."
