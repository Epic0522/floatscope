#!/usr/bin/env bash
set -euo pipefail

APP_NAME="FloatScope"
BUNDLE_ID="local.floatscope.app"
APP_DISPLAY_NAME="$APP_NAME"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
EXECUTABLE_PATH="$ROOT_DIR/.build/$BUILD_CONFIG/$APP_NAME"
BUNDLE_PATH="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_PATH="$BUNDLE_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"

VERIFY=0
LAUNCH=1
PREVIEW=0

for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY=1 ;;
    --no-launch) LAUNCH=0 ;;
    --debug) BUILD_CONFIG="debug" ;;
    --preview) PREVIEW=1 ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

if ((PREVIEW == 1)); then
  BUNDLE_ID="local.floatscope.preview"
  APP_DISPLAY_NAME="FloatScope Preview"
  BUNDLE_PATH="$ROOT_DIR/dist/$APP_DISPLAY_NAME.app"
  CONTENTS_PATH="$BUNDLE_PATH/Contents"
  MACOS_PATH="$CONTENTS_PATH/MacOS"
  RESOURCES_PATH="$CONTENTS_PATH/Resources"
fi

EXECUTABLE_PATH="$ROOT_DIR/.build/$BUILD_CONFIG/$APP_NAME"

cd "$ROOT_DIR"

if ((LAUNCH == 1 && PREVIEW == 0)); then
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_NAME" || true
    sleep 0.5
  fi

  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -9 -x "$APP_NAME" || true
    sleep 0.2
  fi
fi

swift build -c "$BUILD_CONFIG"

rm -rf "$BUNDLE_PATH"
mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"
cp "$EXECUTABLE_PATH" "$MACOS_PATH/$APP_NAME"

cat > "$CONTENTS_PATH/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 FloatScope contributors.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --sign - "$BUNDLE_PATH" >/dev/null

if [[ "$LAUNCH" == "1" ]]; then
  /usr/bin/open -n "$BUNDLE_PATH"
fi

if [[ "$VERIFY" == "1" ]]; then
  sleep 1
  if pgrep -f "$BUNDLE_PATH/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "$BUNDLE_PATH"
  else
    echo "Launch verification failed: $BUNDLE_PATH is not running." >&2
    exit 1
  fi
else
  echo "$BUNDLE_PATH"
fi
