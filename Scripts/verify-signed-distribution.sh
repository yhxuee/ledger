#!/usr/bin/env bash
# Inspect the real signatures and embedded profiles of an archive or exported IPA.
set -euo pipefail

app="${1:?Pass Finsy.app path}"
team="${2:?Pass Apple team ID}"
build="${3:?Pass expected build number}"
environment="${4:-archive}"
widget="$app/PlugIns/FinsyWidget.appex"

test -d "$widget" || { echo '::error::FinsyWidget.appex is missing from Finsy.app'; exit 1; }
bash Scripts/verify-app-group-entitlements.sh "$app"
codesign --verify --strict --deep "$app"

python3 - "$app" "$widget" "$team" "$build" "$environment" <<'PY'
import datetime
import pathlib
import plistlib
import subprocess
import sys

app, widget = map(pathlib.Path, sys.argv[1:3])
team, build, environment = sys.argv[3:]
group = "group.com.finsy.app"
cloud = "iCloud.com.finsy.app"

def require(ok, message):
    if not ok:
        raise SystemExit(f"::error::{message}")

def plist_command(*args):
    return plistlib.loads(subprocess.check_output(args))

for path, bundle, is_app in ((app, "com.finsy.app", True),
                             (widget, "com.finsy.app.Widget", False)):
    label = "main app" if is_app else "widget"
    info = plistlib.loads((path / "Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == bundle, f"{label}: wrong bundle ID")
    require(str(info.get("CFBundleVersion")) == build, f"{label}: wrong build number")
    signature = plist_command("codesign", "-d", "--entitlements", ":-", str(path))
    details = subprocess.run(["codesign", "-dv", str(path)], capture_output=True, text=True, check=True).stderr
    require("Authority=Apple Distribution:" in details, f"{label}: Apple Distribution identity missing")
    profile_path = path / "embedded.mobileprovision"
    require(profile_path.is_file(), f"{label}: embedded provisioning profile missing")
    profile = plist_command("security", "cms", "-D", "-i", str(profile_path))
    authorized = profile.get("Entitlements", {})
    require(team in profile.get("TeamIdentifier", []), f"{label}: profile has wrong team")
    expires = profile.get("ExpirationDate")
    require(expires and expires > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
            f"{label}: profile expired")
    require(signature.get("com.apple.developer.team-identifier") == team,
            f"{label}: signed team identifier differs")
    require(signature.get("application-identifier") == f"{team}.{bundle}",
            f"{label}: signed application identifier differs")
    require(authorized.get("application-identifier") == f"{team}.{bundle}",
            f"{label}: profile does not authorize bundle ID")
    for source, name in ((signature, "signature"), (authorized, "profile")):
        require(group in source.get("com.apple.security.application-groups", []),
                f"{label}: {name} does not authorize App Group")
        if is_app:
            require(cloud in source.get("com.apple.developer.icloud-container-identifiers", []),
                    f"{label}: {name} does not authorize iCloud container")
            services = source.get("com.apple.developer.icloud-services", [])
            has_icloud = (services == "*") or ("*" in services) or ("CloudKit" in services and "CloudDocuments" in services)
            require(has_icloud,
                    f"{label}: {name} lacks CloudKit or iCloud Documents")
    if is_app and environment == "production":
        require(signature.get("aps-environment") == "production",
                "main app: signed APNs environment is not production")
        require(authorized.get("aps-environment") == "production",
                "main app: profile APNs environment is not production")
    print(f"OK {label}: Apple Distribution; bundle {bundle}; build {build}; profile and signed capabilities verified")
PY
