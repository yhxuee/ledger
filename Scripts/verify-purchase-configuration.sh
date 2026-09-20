#!/usr/bin/env bash
# Source-level audit of the Purchase Mode cross-process configuration.
#
# This checks what the REPOSITORY configures. It cannot prove what a signed build will
# receive at runtime: use Scripts/verify-app-group-entitlements.sh on a built product for that.
set -euo pipefail

failures=0
note() { printf '  %s\n' "$1"; }
ok()   { printf 'OK    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }

APP_GROUP="group.com.finsy.app"
APP_ID="com.finsy.app"
WIDGET_ID="com.finsy.app.Widget"
PBX="Finsy.xcodeproj/project.pbxproj"

echo "== Entitlement files =="
for pair in "Finsy/Finsy.entitlements:$APP_GROUP" "FinsyWidget/FinsyWidget.entitlements:$APP_GROUP"; do
  file="${pair%%:*}"
  group="${pair##*:}"
  if [[ -f "$file" ]]; then
    if grep -q "com.apple.security.application-groups" "$file" && grep -q "$group" "$file"; then
      ok "$file contains com.apple.security.application-groups $group"
    else
      bad "$file is missing the $group App Group entitlement"
    fi
  else
    bad "$file does not exist"
  fi
done

echo "== Xcode project wiring =="
if [[ -f "$PBX" ]]; then
  for expected in \
      "CODE_SIGN_ENTITLEMENTS = Finsy/Finsy.entitlements" \
      "CODE_SIGN_ENTITLEMENTS = FinsyWidget/FinsyWidget.entitlements" \
      "PRODUCT_BUNDLE_IDENTIFIER = $APP_ID;" \
      "PRODUCT_BUNDLE_IDENTIFIER = $WIDGET_ID;" \
      "com.apple.ApplicationGroups.iOS = {enabled = 1; }" \
      "Embed App Extensions"; do
    if grep -qF "$expected" "$PBX"; then ok "$expected"; else bad "missing in project.pbxproj: $expected"; fi
  done
else
  bad "$PBX not found"
fi

echo "== Live Activity support =="
for pair in "Finsy/Info.plist" "FinsyWidget/Info.plist"; do
  if grep -q "NSSupportsLiveActivities" "$pair"; then ok "$pair declares NSSupportsLiveActivities"; else bad "$pair is missing NSSupportsLiveActivities"; fi
done

echo "== App Group identifier consistency =="
declared="$(grep -rho "$APP_GROUP" Finsy FinsyShared 2>/dev/null | head -n 1 || true)"
if [[ -n "${declared:-}" ]]; then ok "identifier used in code: $declared"; else bad "App Group identifier not found in app sources"; fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "Source configuration audit found $failures problem(s)."
  exit 1
fi
echo "Source configuration audit passed. Runtime signed entitlements still need device verification."