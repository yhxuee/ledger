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
from urllib.parse import urlparse

app, widget = map(pathlib.Path, sys.argv[1:3])
team, build, environment = sys.argv[3:]
group = "group.com.finsy.app"
cloud = "iCloud.com.finsy.app"
runner_temp = pathlib.Path(os.environ.get("RUNNER_TEMP", "/tmp"))

def require(ok, message):
    if not ok:
        raise SystemExit(f"::error::{message}")

def extract_signed_entitlements(path: pathlib.Path) -> dict:
    for cmd in (
        ["codesign", "-d", "--entitlements", "--xml", "-", str(path)],
        ["codesign", "-d", "--entitlements", ":-", str(path)],
        ["codesign", "-d", "--entitlements", "-", str(path)],
    ):
        try:
            res = subprocess.run(cmd, capture_output=True)
            for out in (res.stdout, res.stderr):
                idx = out.find(b"<?xml")
                if idx == -1:
                    idx = out.find(b"<plist")
                if idx != -1:
                    end_idx = out.find(b"</plist>")
                    if end_idx != -1:
                        data = out[idx:end_idx + 8]
                    else:
                        data = out[idx:]
                    return plistlib.loads(data)
        except Exception:
            pass
    return {}

def decode_profile(profile_path: pathlib.Path) -> dict:
    out = subprocess.check_output(["security", "cms", "-D", "-i", str(profile_path)])
    idx = out.find(b"<?xml")
    if idx == -1:
        idx = out.find(b"<plist")
    if idx != -1:
        end_idx = out.find(b"</plist>")
        if end_idx != -1:
            return plistlib.loads(out[idx:end_idx + 8])
        return plistlib.loads(out[idx:])
    return plistlib.loads(out)

for path, bundle, is_app in ((app, "com.finsy.app", True),
                             (widget, "com.finsy.app.Widget", False)):
    label = "main app" if is_app else "widget"
    info = plistlib.loads((path / "Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == bundle, f"{label}: wrong bundle ID")
    require(str(info.get("CFBundleVersion")) == build, f"{label}: wrong build number")
    if is_app:
        issuer_url = info.get("FINSY_WALLET_PASS_ISSUER_URL", "")
        parsed_issuer = urlparse(issuer_url)
        require(parsed_issuer.scheme == "https" and bool(parsed_issuer.hostname),
                "main app: Wallet pass issuer URL is missing or invalid")

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

    # App Group authorization
    require(group in authorized.get("com.apple.security.application-groups", []),
            f"{label}: profile does not authorize App Group")
    if signature and "com.apple.security.application-groups" in signature:
        require(group in signature.get("com.apple.security.application-groups", []),
                f"{label}: signature does not authorize App Group")

    # iCloud authorization (for main app)
    if is_app:
        pass_types = {f"{team}.pass.com.finsy.{kind}" for kind in ("account", "receipt")}
        signed_pass_types = set(signature.get("com.apple.developer.pass-type-identifiers", []))
        profile_pass_types = set(authorized.get("com.apple.developer.pass-type-identifiers", []))
        require(pass_types <= signed_pass_types,
                "main app: signed Wallet pass type entitlements are missing")
        require(pass_types <= profile_pass_types or f"{team}.*" in profile_pass_types,
                "main app: distribution profile does not authorize Wallet pass types")
        require(cloud in authorized.get("com.apple.developer.icloud-container-identifiers", []),
                f"{label}: profile does not authorize iCloud container")
        services = authorized.get("com.apple.developer.icloud-services", [])
        has_icloud = (services == "*") or ("*" in services) or ("CloudKit" in services and "CloudDocuments" in services)
        require(has_icloud,
                f"{label}: profile lacks CloudKit or iCloud Documents")

        if signature and "com.apple.developer.icloud-container-identifiers" in signature:
            require(cloud in signature.get("com.apple.developer.icloud-container-identifiers", []),
                    f"{label}: signature does not authorize iCloud container")
        if signature and "com.apple.developer.icloud-services" in signature:
            sig_services = signature.get("com.apple.developer.icloud-services", [])
            sig_has_icloud = (sig_services == "*") or ("*" in sig_services) or ("CloudKit" in sig_services and "CloudDocuments" in sig_services)
            require(sig_has_icloud,
                    f"{label}: signature lacks CloudKit or iCloud Documents")

    if is_app and environment == "production":
        if signature.get("aps-environment"):
            require(signature.get("aps-environment") == "production",
                    "main app: signed APNs environment is not production")
        if authorized.get("aps-environment"):
            require(authorized.get("aps-environment") == "production",
                    "main app: profile APNs environment is not production")
    print(f"OK {label}: bundle {bundle}; build {build}; App Store distribution profile and signed capabilities verified")
PY
