#!/usr/bin/env bash
# Verifies the SIGNED products actually carry the App Group entitlement at runtime.
#
# Usage: Scripts/verify-app-group-entitlements.sh path/to/Finsy.app
# Source files looking correct is not enough: this inspects the built binaries.
set -euo pipefail

APP_PATH="${1:-}"
APP_GROUP="group.com.finsy.app"
APP_ID="com.finsy.app"
WIDGET_ID="com.finsy.app.Widget"

failures=0
ok()  { printf 'OK    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }

if [[ -z "$APP_PATH" ]]; then
  echo "usage: $0 path/to/Finsy.app" >&2
  exit 2
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: $APP_PATH is not a directory" >&2
  exit 2
fi

entitlements_of() {
  # Prints the entitlements embedded in the signature of a Mach-O product.
  codesign -d --entitlements :- "$1" 2>/dev/null || true
}

check_target() {
  local product="$1" identifier="$2" label="$3"
  if [[ ! -e "$product" ]]; then
    bad "$label product not found at $product"
    return
  fi
  local plist
  plist="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$product/Info.plist" 2>/dev/null || true)"
  if [[ "$plist" == "$identifier" ]]; then
    ok "$label bundle identifier is $identifier"
  else
    bad "$label bundle identifier is '${plist:-<unreadable>}', expected $identifier"
  fi
  local entitlements
  entitlements="$(entitlements_of "$product")"
  if [[ -z "${entitlements//[[:space:]]/}" ]]; then
    bad "$label has NO signed entitlements (unsigned or stripped build): runtime App Group access will fail"
    return
  fi
  if grep -q "com.apple.security.application-groups" <<<"$entitlements"; then
    ok "$label signature declares com.apple.security.application-groups"
  else
    bad "$label signature lacks com.apple.security.application-groups"
  fi
  if grep -q "$APP_GROUP" <<<"$entitlements"; then
    ok "$label signature contains $APP_GROUP"
  else
    bad "$label signature does not contain $APP_GROUP"
  fi
}

echo "== Inspecting $APP_PATH =="
check_target "$APP_PATH" "$APP_ID" "app"

WIDGET_PATH="$APP_PATH/PlugIns/FinsyWidget.appex"
check_target "$WIDGET_PATH" "$WIDGET_ID" "widget extension"

if [[ -d "$WIDGET_PATH" ]]; then
  ok "widget extension is embedded in the app's PlugIns directory"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "$failures entitlement problem(s) found. A signed build with the App Group capability"
  echo "enabled for BOTH bundle IDs (and provisioning profiles including $APP_GROUP) is required."
  exit 1
fi
echo "Both products declare the App Group entitlement with $APP_GROUP."