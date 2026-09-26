#!/usr/bin/env python3
"""Install supplied Ad Hoc profiles without using or modifying App Store profiles."""
import base64
import datetime
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    team = os.environ['DEVELOPMENT_TEAM'].strip()
    root = Path(os.environ['RUNNER_TEMP'])
    keychain = root / 'finsy-adhoc.keychain-db'
    pem = subprocess.check_output(['security', 'find-certificate', '-c', 'Apple Distribution', '-p', str(keychain)])
    certificate = subprocess.check_output(['openssl', 'x509', '-outform', 'DER'], input=pem)
    destination = Path.home() / 'Library/MobileDevice/Provisioning Profiles'
    destination.mkdir(parents=True, exist_ok=True)
    profiles = []
    for secret, bundle, prefix in (
        ('IOS_ADHOC_PROFILE_APP', 'com.finsy.app', 'APP'),
        ('IOS_ADHOC_PROFILE_WIDGET', 'com.finsy.app.Widget', 'WIDGET'),
    ):
        raw = base64.b64decode(''.join(os.environ[secret].split()), validate=True)
        with tempfile.NamedTemporaryFile(dir=root, suffix='.mobileprovision') as file:
            file.write(raw)
            file.flush()
            profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', file.name]))
        entitlements = profile.get('Entitlements', {})
        devices = set(profile.get('ProvisionedDevices', []))
        require(devices, f'{bundle}: Ad Hoc profile must include registered devices')
        require(not profile.get('ProvisionsAllDevices'), f'{bundle}: enterprise profiles are not accepted')
        require(entitlements.get('get-task-allow') is not True, f'{bundle}: development profiles are not accepted')
        require(team in profile.get('TeamIdentifier', []), f'{bundle}: wrong signing team')
        require(entitlements.get('application-identifier') == f'{team}.{bundle}', f'{bundle}: wrong application identifier')
        require(profile.get('ExpirationDate', datetime.datetime.min) > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), f'{bundle}: profile expired')
        require(certificate in profile.get('DeveloperCertificates', []), f'{bundle}: profile does not include the imported distribution certificate')
        require('group.com.finsy.app' in entitlements.get('com.apple.security.application-groups', []), f'{bundle}: App Group not authorized')
        if prefix == 'APP':
            require('iCloud.com.finsy.app' in entitlements.get('com.apple.developer.icloud-container-identifiers', []), 'iCloud container not authorized')
            services = entitlements.get('com.apple.developer.icloud-services', [])
            require(services == '*' or '*' in services or {'CloudKit', 'CloudDocuments'} <= set(services), 'CloudKit/iCloud Drive not authorized')
            passes = set(entitlements.get('com.apple.developer.pass-type-identifiers', []))
            required = {f'{team}.pass.com.finsy.{kind}' for kind in ('account', 'receipt')}
            require(required <= passes or f'{team}.*' in passes, 'Wallet pass types not authorized')
            require(entitlements.get('aps-environment') == 'production', 'Ad Hoc profile must authorize production APNs')
        name, uuid = profile.get('Name', ''), profile.get('UUID', '')
        require(name and uuid and '\n' not in name and '\r' not in name, f'{bundle}: invalid profile name/UUID')
        require(all(c.isalnum() or c == '-' for c in uuid), f'{bundle}: invalid profile UUID')
        (destination / f'{uuid}.mobileprovision').write_bytes(raw)
        profiles.append((prefix, name, uuid, devices))
        print(f'Installed {bundle}: {name}; {len(devices)} registered device(s)')
    common = profiles[0][3] & profiles[1][3]
    require(common, 'App and widget profiles have no registered devices in common')
    with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as file:
        for prefix, name, uuid, _ in profiles:
            file.write(f'{prefix}_PROFILE_NAME={name}\n{prefix}_PROFILE_UUID={uuid}\n')
    print(f'App and widget authorize {len(common)} common registered device(s)')


if __name__ == '__main__':
    main()
