"""Exercise all three local issuer endpoints and verify their pass signatures."""

import hashlib
import io
import json
import os
import subprocess
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path


SAMPLES = {
    "account": {
        "passTypeIdentifier": "pass.com.finsy.account",
        "serialNumber": "finsy-primary-account-pass",
        "title": "Net Worth",
        "formattedBalance": "HK$123.45",
        "accountCount": 2,
        "locations": [],
    },
    "purchase-receipt": {
        "passTypeIdentifier": "pass.com.finsy.receipt",
        "serialNumber": "purchase-00000000-0000-0000-0000-000000000001",
        "storeName": "Test Shop",
        "formattedTotal": "HK$10.00",
        "formattedTax": "HK$0.00",
        "itemCount": 1,
        "items": [{"name": "Item", "formattedAmount": "HK$10.00"}],
        "finalizedAt": 812345678.0,
    },
    "tax-receipt": {
        "passTypeIdentifier": "pass.com.finsy.tax",
        "serialNumber": "tax-expense-2026-09",
        "monthName": "September 2026",
        "formattedExpenseTax": "HK$1.00",
        "formattedTaxableExpense": "HK$10.00",
    },
}
BASE_URL = os.environ.get("FINSY_ISSUER_URL", "http://127.0.0.1:8765").rstrip("/")


for endpoint, sample in SAMPLES.items():
    request = urllib.request.Request(
        f"{BASE_URL}/{endpoint}",
        data=json.dumps(sample).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/vnd.apple.pkpass", "User-Agent": "Finsy/2.0 CFNetwork"},
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            assert response.headers.get_content_type() == "application/vnd.apple.pkpass"
            contents = response.read()
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"{endpoint}: HTTP {error.code}; headers={dict(error.headers)}; body={error.read()[:500]!r}") from error
    with zipfile.ZipFile(io.BytesIO(contents)) as bundle:
        manifest = json.loads(bundle.read("manifest.json"))
        for name, digest in manifest.items():
            assert hashlib.sha1(bundle.read(name)).hexdigest() == digest
        assert json.loads(bundle.read("pass.json"))["passTypeIdentifier"] == sample["passTypeIdentifier"]
        style = json.loads(bundle.read("pass.json"))
        if endpoint == "account":
            assert "generic" in style and "strip.png" not in bundle.namelist()
        else:
            assert "coupon" in style and "strip.png" in bundle.namelist()
        with tempfile.TemporaryDirectory() as temp:
            manifest_path = Path(temp) / "manifest.json"
            signature_path = Path(temp) / "signature"
            manifest_path.write_bytes(bundle.read("manifest.json"))
            signature_path.write_bytes(bundle.read("signature"))
            subprocess.run(
                ["openssl", "cms", "-verify", "-binary", "-inform", "DER", "-in", str(signature_path),
                 "-content", str(manifest_path), "-noverify", "-out", "/dev/null"],
                check=True, capture_output=True,
            )
    print(f"OK {endpoint}: manifest and detached signature verified")
