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
codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$widget"

python3 - "$app" "$widget" "$team" "$build" "$environment" <<'PY'
import datetime
import os
import pathlib
import plistlib
import subprocess
import sys
import time

app, widget = map(pathlib.Path, sys.argv[1:3])
team, build, environment = sys.argv[3:]
group = "group.com.finsy.app"
cloud = "iCloud.com.finsy.app"
runner_temp = pathlib.Path(os.environ.get("RUNNER_TEMP", "/tmp"))

def require(ok, message):
    if not ok:
        raise SystemExit(f"::error::{message}")

def extract_signed_entitlements(path: pathlib.Path) -> dict:
    temp_plist = runner_temp / f"ent_{int(time.time() * 1000)}.plist"
    try:
        subprocess.run(["codesign", "-d", "--entitlements", str(temp_plist), str(path)],
                       capture_output=True, check=True)
        if temp_plist.is_file() and temp_plist.stat().st_size > 0:
            return plistlib.loads(temp_plist.read_bytes())
    except Exception:
        pass
    finally:
        if temp_plist.exists():
            temp_plist.unlink()

    out = subprocess.run(["codesign", "-d", "--entitlements", "-", str(path)],
                         capture_output=True).stdout
    idx = out.find(b"<?xml")
    if idx == -1:
        idx = out.find(b"<plist")
    if idx != -1:
        return plistlib.loads(out[idx:])
    return {}

def decode_profile(profile_path: pathlib.Path) -> dict:
    out = subprocess.check_output(["security", "cms", "-D", "-i", str(profile_path)])
    idx = out.find(b"<?xml")
    if idx == -1:
        idx = out.find(b"<plist")
    if idx != -1:
        return plistlib.loads(out[idx:])
    return plistlib.loads(out)

for path, bundle, is_app in ((app, "com.finsy.app", True),
                             (widget, "com.finsy.app.Widget", False)):
    label = "main app" if is_app else "widget"
    info = plistlib.loads((path / "Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == bundle, f"{label}: wrong bundle ID")
    require(str(info.get("CFBundleVersion")) == build, f"{label}: wrong build number")

    signature = extract_signed_entitlements(path)
    details = subprocess.run(["codesign", "-d", "--verbose=4", str(path)], capture_output=True, text=True).stderr
    authorities = [line.strip() for line in details.splitlines() if line.strip().startswith("Authority=")]
    if authorities:
        print(f"{label} signing authorities: {authorities}")

    profile_path = path / "embedded.mobileprovision"
    require(profile_path.is_file(), f"{label}: embedded provisioning profile missing")
    profile = decode_profile(profile_path)
    authorized = profile.get("Entitlements", {})

    require(bool(profile.get("Name")), f"{label}: profile missing Name")
    require(bool(profile.get("UUID")), f"{label}: profile missing UUID")
    require(team in profile.get("TeamIdentifier", []), f"{label}: profile has wrong team")
    expires = profile.get("ExpirationDate")
    require(expires and expires > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
            f"{label}: profile expired")

    # Invariant: App Store distribution profile must NOT have ProvisionedDevices and must not allow debugging
    require("ProvisionedDevices" not in profile,
            f"{label}: profile contains ProvisionedDevices (not an App Store distribution profile)")
    require(authorized.get("get-task-allow") is not True,
            f"{label}: profile get-task-allow is True (not a distribution profile)")

    expected_app_id = f"{team}.{bundle}"
    if signature.get("com.apple.developer.team-identifier"):
        require(signature.get("com.apple.developer.team-identifier") == team,
                f"{label}: signed team identifier differs")
    if signature.get("application-identifier"):
        require(signature.get("application-identifier") == expected_app_id or
                signature.get("application-identifier", "").endswith(f".{bundle}"),
                f"{label}: signed application identifier differs")

    prof_app_id = authorized.get("application-identifier", "")
    require(prof_app_id == expected_app_id or prof_app_id.endswith(f".{bundle}"),
            f"{label}: profile does not authorize bundle ID")
    require(prof_app_id.endswith(f".{bundle}"),
            f"{label}: profile application-identifier does not end with .{bundle}")

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
        if signature.get("aps-environment"):
            require(signature.get("aps-environment") == "production",
                    "main app: signed APNs environment is not production")
        if authorized.get("aps-environment"):
            require(authorized.get("aps-environment") == "production",
                    "main app: profile APNs environment is not production")
    print(f"OK {label}: bundle {bundle}; build {build}; App Store distribution profile and signed capabilities verified")
PY
