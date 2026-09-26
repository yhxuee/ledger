#!/bin/bash
set -euo pipefail
task_dir="$(mktemp -d)"
trap 'rm -rf "$task_dir"' EXIT
python3 - "$task_dir" <<'PY'
import pathlib, sys, uuid
target = pathlib.Path(sys.argv[1])
source = pathlib.Path('Finsy/Domain/LedgerCrypto.swift').read_text()
source = source.replace('com.finsy.app.', 'com.finsy.storage-verification.' + uuid.uuid4().hex + '.')
(target / 'LedgerCrypto.swift').write_text(source)
PY
xcrun swiftc -parse-as-library \
  FinsyShared/FinanceIdentifiers.swift FinsyShared/PurchaseModels.swift \
  Finsy/Domain/Models.swift Finsy/Domain/SeedData.swift Finsy/Domain/TaxCalculations.swift \
  Finsy/Domain/LinkedTransactions.swift Finsy/Domain/LedgerIndex.swift \
  Finsy/Domain/LedgerCalculations.swift Finsy/Domain/CurrencyRates.swift \
  Finsy/Data/LedgerDiskDatabase.swift Finsy/Data/LedgerTransactionRepository.swift \
  Finsy/Data/IncrementalLedgerRepository.swift "$task_dir/LedgerCrypto.swift" \
  Scripts/verify-encrypted-storage.swift -o "$task_dir/verify"
"$task_dir/verify" "$task_dir"
