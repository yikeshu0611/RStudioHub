#!/usr/bin/env bash
set -euo pipefail

APP_NAME="RStudioHub"
INSTALL_PATH="/Applications/$APP_NAME.app"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing $APP_DIR — run ./build.sh first" >&2
  exit 1
fi

pkill -x RStudioHub 2>/dev/null || true
rm -rf "$INSTALL_PATH"
ditto "$APP_DIR" "$INSTALL_PATH"
xattr -cr "$INSTALL_PATH" 2>/dev/null || true
echo "Installed $INSTALL_PATH"
