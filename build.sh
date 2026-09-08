#!/usr/bin/env bash
# Builds GRASP and packages it into a minimal .app bundle.
# A bare loose Mach-O executable gets silently reaped by RunningBoardServices
# shortly after launch on modern macOS -- it needs a real bundle for the
# system to treat it as a legitimate long-lived app process.
set -euo pipefail
cd "$(dirname "$0")"

# Both slices in one binary via lipo under the hood, so the app runs
# unmodified on Intel Macs too -- not just the Apple Silicon this is built
# on. SwiftPM puts a universal build under .build/apple/... rather than the
# plain .build/release used for a single-arch build, so the output path is
# asked for rather than assumed.
ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH_FLAGS[@]}"
BIN_PATH="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP_DIR="build/GRASP.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH/GRASP" "$APP_DIR/Contents/MacOS/GRASP"
cp Info.plist "$APP_DIR/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# This project lives on iCloud Drive: Finder/Spotlight sometimes re-stamps
# AppleDouble/resource-fork extended attributes on freshly-created files
# within moments of the cp above (a real race, not just a one-time cleanup),
# and codesign refuses to sign a bundle containing those ("resource fork,
# Finder information, or similar detritus not allowed"). Retry the
# strip+sign a few times to absorb that race rather than failing on it.
SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
SIGN_OK=0
for attempt in 1 2 3 4 5; do
  xattr -cr "$APP_DIR"
  if [ -n "$SIGNING_IDENTITY" ]; then
    if codesign --force --options runtime -s "$SIGNING_IDENTITY" "$APP_DIR" 2>/tmp/grasp-codesign-err; then
      echo "Signed with: $SIGNING_IDENTITY (attempt $attempt)"
      SIGN_OK=1
      break
    fi
  else
    if codesign --force -s - "$APP_DIR" 2>/tmp/grasp-codesign-err; then
      echo "No local signing identity found -- signed ad-hoc"
      SIGN_OK=1
      break
    fi
  fi
  sleep 0.3
done
if [ "$SIGN_OK" -ne 1 ]; then
  cat /tmp/grasp-codesign-err >&2
  echo "codesign failed after retries" >&2
  exit 1
fi
rm -f /tmp/grasp-codesign-err

echo "Built: $APP_DIR"
