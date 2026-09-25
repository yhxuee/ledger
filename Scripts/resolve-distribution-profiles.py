#!/usr/bin/env python3
"""
Resolve App Store distribution provisioning profiles for Finsy and FinsyWidget.
1. Checks for manual base64 profile secrets (IOS_APPSTORE_PROFILE_APP, IOS_APPSTORE_PROFILE_WIDGET).
2. Otherwise, uses App Store Connect API (JWT with ES256) to query or create active IOS_APP_STORE profiles.
3. Installs profiles to ~/Library/MobileDevice/Provisioning Profiles/<UUID>.mobileprovision.
4. Verifies profiles authorize required capabilities and contain NO ProvisionedDevices list.
5. Exports profile names and UUIDs to $GITHUB_ENV.
"""

import base64
import datetime
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.request

try:
    import jwt
    from cryptography import x509
except ImportError:
    print("Installing required python packages: pyjwt, cryptography...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "pyjwt", "cryptography"])
    import jwt
    from cryptography import x509

PROFILES_DIR = pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles"
PROFILES_DIR.mkdir(parents=True, exist_ok=True)

team_id = os.environ.get("DEVELOPMENT_TEAM", "").strip()
if not team_id:
    print("::error::DEVELOPMENT_TEAM environment variable is missing.")
    sys.exit(1)

asc_key_id = os.environ.get("ASC_KEY_ID", "").strip()
asc_issuer_id = os.environ.get("ASC_ISSUER_ID", "").strip()
asc_key_p8 = os.environ.get("ASC_KEY_P8", "").strip()

runner_temp = pathlib.Path(os.environ.get("RUNNER_TEMP", "/tmp"))
keychain_path = runner_temp / "finsy-signing.keychain-db"


def generate_asc_token() -> str:
    now = int(time.time())
    payload = {
        "iss": asc_issuer_id,
        "iat": now,
        "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    }
    headers = {"kid": asc_key_id, "typ": "JWT", "alg": "ES256"}
    return jwt.encode(payload, asc_key_p8, algorithm="ES256", headers=headers)


def asc_request(token: str, method: str, path: str, body: dict = None) -> dict:
    url = f"https://api.appstoreconnect.apple.com/v1{path}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    data = json.dumps(body).encode("utf-8") if body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_content = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"App Store Connect API {method} {path} error ({e.code}): {error_content}") from e


def get_imported_cert_serial() -> str:
    """Extract serial number of the Apple Distribution certificate imported in the keychain."""
    if not keychain_path.exists():
        return ""
    try:
        pem = subprocess.check_output(
            ["security", "find-certificate", "-a", "-c", "Apple Distribution", "-p", str(keychain_path)]
        )
        certs = x509.load_pem_x509_certificates(pem)
        if certs:
            return format(certs[0].serial_number, "x").lower().lstrip("0")
        return ""
    except Exception as e:
        print(f"Warning: Could not extract certificate serial from keychain: {e}")
        return ""


def decode_mobileprovision(data: bytes) -> dict:
    """Decode signed CMS mobileprovision using security cms."""
    temp_file = runner_temp / f"temp_{int(time.time())}.mobileprovision"
    temp_file.write_bytes(data)
    try:
        proc = subprocess.run(
            ["security", "cms", "-D", "-i", str(temp_file)],
            capture_output=True,
            check=True,
        )
        return plistlib.loads(proc.stdout)
    finally:
        if temp_file.exists():
            temp_file.unlink()


def verify_and_install_profile(data: bytes, bundle_id: str, is_app: bool, expected_cert_serial: str = "") -> tuple[str, str]:
    """Verify profile correctness and install into Provisioning Profiles directory."""
    plist = decode_mobileprovision(data)

    name = plist.get("Name", "")
    uuid = plist.get("UUID", "")
    if not name or not uuid:
        raise ValueError(f"Profile for {bundle_id} is missing Name or UUID.")

    # 1. Must NOT contain ProvisionedDevices (distribution profile invariant)
    if "ProvisionedDevices" in plist:
        raise ValueError(
            f"{bundle_id}: Profile '{name}' is NOT an App Store distribution profile! "
            f"It contains a ProvisionedDevices list with {len(plist['ProvisionedDevices'])} device(s)."
        )

    # 2. Team verification
    team_list = plist.get("TeamIdentifier", [])
    if team_id not in team_list:
        raise ValueError(f"{bundle_id}: Profile team {team_list} does not contain expected team {team_id}.")

    # 3. Expiration date
    expiration = plist.get("ExpirationDate")
    now_utc = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    if not expiration or expiration <= now_utc:
        raise ValueError(f"{bundle_id}: Profile '{name}' is expired ({expiration}).")

    # 4. Entitlements verification
    entitlements = plist.get("Entitlements", {})
    expected_app_id = f"{team_id}.{bundle_id}"
    if entitlements.get("application-identifier") != expected_app_id:
        raise ValueError(
            f"{bundle_id}: Profile application-identifier '{entitlements.get('application-identifier')}' "
            f"differs from expected '{expected_app_id}'."
        )

    prof_team = entitlements.get("com.apple.developer.team-identifier")
    if prof_team and prof_team != team_id:
        raise ValueError(f"{bundle_id}: Profile team-identifier '{prof_team}' differs from '{team_id}'.")

    groups = entitlements.get("com.apple.security.application-groups", [])
    if "group.com.finsy.app" not in groups:
        raise ValueError(f"{bundle_id}: Profile does not authorize group.com.finsy.app (found {groups}).")

    if is_app:
        icloud_ids = entitlements.get("com.apple.developer.icloud-container-identifiers", [])
        if "iCloud.com.finsy.app" not in icloud_ids:
            raise ValueError(f"Main app profile does not authorize iCloud.com.finsy.app (found {icloud_ids}).")
        services = entitlements.get("com.apple.developer.icloud-services", [])
        if "CloudKit" not in services or "CloudDocuments" not in services:
            raise ValueError(f"Main app profile lacks CloudKit/CloudDocuments (found {services}).")

    # 5. Certificate inclusion verification
    if expected_cert_serial:
        dev_certs = plist.get("DeveloperCertificates", [])
        serials = []
        for raw_cert in dev_certs:
            try:
                c = x509.load_der_x509_certificate(raw_cert)
                serials.append(format(c.serial_number, "x").lower().lstrip("0"))
            except Exception:
                pass
        if serials and expected_cert_serial not in serials:
            raise ValueError(
                f"{bundle_id}: Profile '{name}' does not include imported distribution certificate "
                f"(expected serial: {expected_cert_serial}, found in profile: {serials})"
            )

    # Install profile
    target_path = PROFILES_DIR / f"{uuid}.mobileprovision"
    target_path.write_bytes(data)
    print(f"Verified & Installed {bundle_id} profile: '{name}' (UUID: {uuid}) -> {target_path}")
    return name, uuid


def resolve_profiles_via_asc(token: str) -> dict[str, tuple[str, str]]:
    """Query or create App Store Connect distribution profiles for both targets."""
    print("Connecting to App Store Connect API...")

    # 1. Find the Apple Distribution certificate ID
    imported_serial = get_imported_cert_serial()
    certs_resp = asc_request(token, "GET", "/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=100")
    certs = certs_resp.get("data", [])
    if not certs:
        raise RuntimeError("No DISTRIBUTION certificates found on this Apple Developer account.")

    selected_cert_id = None
    for c in certs:
        c_serial = c.get("attributes", {}).get("serialNumber", "").lower().lstrip("0")
        if imported_serial and c_serial == imported_serial:
            selected_cert_id = c["id"]
            print(f"Matched imported distribution certificate in App Store Connect: {c['id']} (serial: {c_serial})")
            break

    if not selected_cert_id:
        selected_cert_id = certs[0]["id"]
        print(f"Using distribution certificate ID: {selected_cert_id} ({certs[0]['attributes'].get('displayName')})")

    # 2. Get bundle ID resource IDs for com.finsy.app and com.finsy.app.Widget
    targets = [
        ("com.finsy.app", True, "Finsy App Store Profile"),
        ("com.finsy.app.Widget", False, "Finsy Widget App Store Profile"),
    ]

    # Pre-fetch all IOS_APP_STORE profiles to avoid multiple queries
    all_profiles_resp = asc_request(token, "GET", "/profiles?filter[profileType]=IOS_APP_STORE&include=bundleId&limit=100")
    all_profiles = all_profiles_resp.get("data", [])

    resolved = {}

    for bundle_id, is_app, default_name in targets:
        b_resp = asc_request(token, "GET", f"/bundleIds?filter[identifier]={bundle_id}")
        b_data = b_resp.get("data", [])
        if not b_data:
            raise RuntimeError(f"Bundle ID '{bundle_id}' not found in Apple Developer Portal.")
        bundle_resource_id = b_data[0]["id"]
        print(f"Found Bundle ID resource '{bundle_id}': {bundle_resource_id}")

        # Check existing active profiles matching this bundle ID resource
        matched_profiles = [
            p for p in all_profiles
            if p.get("relationships", {}).get("bundleId", {}).get("data", {}).get("id") == bundle_resource_id
            and p.get("attributes", {}).get("profileState") == "ACTIVE"
        ]

        if not matched_profiles:
            try:
                b_prof_resp = asc_request(token, "GET", f"/bundleIds/{bundle_resource_id}/profiles?filter[profileType]=IOS_APP_STORE&limit=100")
                matched_profiles = [
                    p for p in b_prof_resp.get("data", [])
                    if p.get("attributes", {}).get("profileState") == "ACTIVE"
                ]
            except Exception as e:
                print(f"Could not query bundleId profiles: {e}")

        profile_bytes = None
        for p in matched_profiles:
            attrs = p.get("attributes", {})
            content_b64 = attrs.get("profileContent")
            if not content_b64:
                # Fetch full profile resource if profileContent was omitted in list
                single = asc_request(token, "GET", f"/profiles/{p['id']}")
                content_b64 = single.get("data", {}).get("attributes", {}).get("profileContent")
            if content_b64:
                raw_data = base64.b64decode(content_b64)
                try:
                    name, uuid = verify_and_install_profile(raw_data, bundle_id, is_app, imported_serial)
                    resolved[bundle_id] = (name, uuid)
                    profile_bytes = raw_data
                    break
                except Exception as e:
                    print(f"Skipping profile '{attrs.get('name')}': {e}")

        if profile_bytes:
            continue

        # Create new profile
        print(f"No valid active App Store profile found for '{bundle_id}'. Creating via App Store Connect API...")
        profile_create_name = f"{default_name} {int(time.time())}"
        create_body = {
            "data": {
                "type": "profiles",
                "attributes": {
                    "name": profile_create_name,
                    "profileType": "IOS_APP_STORE",
                },
                "relationships": {
                    "bundleId": {
                        "data": {
                            "type": "bundleIds",
                            "id": bundle_resource_id,
                        }
                    },
                    "certificates": {
                        "data": [
                            {
                                "type": "certificates",
                                "id": selected_cert_id,
                            }
                        ]
                    },
                },
            }
        }

        created = asc_request(token, "POST", "/profiles", create_body)
        created_data = created.get("data", {})
        content_b64 = created_data.get("attributes", {}).get("profileContent")
        if not content_b64:
            raise RuntimeError(f"Failed to create profile for '{bundle_id}': no profileContent returned.")

        raw_data = base64.b64decode(content_b64)
        name, uuid = verify_and_install_profile(raw_data, bundle_id, is_app, imported_serial)
        resolved[bundle_id] = (name, uuid)

    return resolved


def main():
    app_secret_b64 = os.environ.get("IOS_APPSTORE_PROFILE_APP", "").strip()
    widget_secret_b64 = os.environ.get("IOS_APPSTORE_PROFILE_WIDGET", "").strip()
    imported_serial = get_imported_cert_serial()

    resolved = {}

    if app_secret_b64 and widget_secret_b64:
        print("Using provided GitHub Secrets IOS_APPSTORE_PROFILE_APP and IOS_APPSTORE_PROFILE_WIDGET...")
        app_data = base64.b64decode(app_secret_b64)
        app_name, app_uuid = verify_and_install_profile(app_data, "com.finsy.app", True, imported_serial)
        resolved["com.finsy.app"] = (app_name, app_uuid)

        widget_data = base64.b64decode(widget_secret_b64)
        widget_name, widget_uuid = verify_and_install_profile(widget_data, "com.finsy.app.Widget", False, imported_serial)
        resolved["com.finsy.app.Widget"] = (widget_name, widget_uuid)
    else:
        if not (asc_key_id and asc_issuer_id and asc_key_p8):
            print("::error::Missing App Store Connect API credentials and no manual profile secrets provided.")
            sys.exit(1)
        try:
            token = generate_asc_token()
            resolved = resolve_profiles_via_asc(token)
        except Exception as e:
            print(f"::error::Automatic App Store profile resolution failed: {e}")
            print(
                "\n"
                "If the App Store Connect API Key lacks Profile permissions, create the two required App Store Connect\n"
                "distribution profiles manually in the Apple Developer Portal:\n"
                "  1. Finsy App Store (Bundle ID: com.finsy.app, Type: App Store Connect)\n"
                "  2. Finsy Widget App Store (Bundle ID: com.finsy.app.Widget, Type: App Store Connect)\n"
                "Then add them as base64-encoded GitHub repository secrets:\n"
                "  - IOS_APPSTORE_PROFILE_APP\n"
                "  - IOS_APPSTORE_PROFILE_WIDGET\n"
            )
            sys.exit(1)

    app_name, app_uuid = resolved["com.finsy.app"]
    widget_name, widget_uuid = resolved["com.finsy.app.Widget"]

    # Export variables to GITHUB_ENV
    github_env = os.environ.get("GITHUB_ENV")
    if github_env:
        with open(github_env, "a", encoding="utf-8") as f:
            f.write(f"APP_PROFILE_NAME={app_name}\n")
            f.write(f"APP_PROFILE_UUID={app_uuid}\n")
            f.write(f"WIDGET_PROFILE_NAME={widget_name}\n")
            f.write(f"WIDGET_PROFILE_UUID={widget_uuid}\n")

    # Generate manual_signing.xcconfig for xcodebuild archive
    xcconfig_path = runner_temp / "manual_signing.xcconfig"
    xcconfig_content = (
        f"CODE_SIGN_STYLE = Manual\n"
        f"CODE_SIGN_IDENTITY = Apple Distribution\n"
        f"DEVELOPMENT_TEAM = {team_id}\n"
        f"APP_PROFILE_SPECIFIER = {app_name}\n"
        f"WIDGET_PROFILE_SPECIFIER = {widget_name}\n"
        f"PROVISIONING_PROFILE_SPECIFIER_com_finsy_app = {app_name}\n"
        f"PROVISIONING_PROFILE_SPECIFIER_com_finsy_app_Widget = {widget_name}\n"
    )
    xcconfig_path.write_text(xcconfig_content, encoding="utf-8")
    print(f"Generated signing xcconfig: {xcconfig_path}\n{xcconfig_content}")


if __name__ == "__main__":
    main()
