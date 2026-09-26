#!/bin/bash
set -euo pipefail
task_dir="$(mktemp -d)"
trap 'rm -rf "$task_dir"' EXIT
# Compile the actual implementation, using a disposable Keychain service namespace.
python3 - "$task_dir" <<'PY'
import pathlib, sys, uuid
target = pathlib.Path(sys.argv[1])
source = pathlib.Path('Finsy/Domain/LedgerCrypto.swift').read_text()
source = source.replace('com.finsy.app.', 'com.finsy.verification.' + uuid.uuid4().hex + '.')
(target / 'LedgerCrypto.swift').write_text(source)
(target / 'Models.swift').write_text('import Foundation\nstruct LedgerBackupEnvelope: Codable, Sendable {}\n')
PY
xcrun swiftc -parse-as-library "$task_dir/Models.swift" "$task_dir/LedgerCrypto.swift" Scripts/verify-ledger-crypto.swift -o "$task_dir/verify"
"$task_dir/verify"

# New processes with no ledger files must retain the same Keychain identity/key.
"$task_dir/verify" --seed-reinstall "$task_dir/probe.json"
"$task_dir/verify" --verify-reinstall "$task_dir/probe.json"
