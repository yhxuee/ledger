"""Issue signed, static Finsy Wallet passes on a loopback-only HTTP service."""

from __future__ import annotations

import hashlib
import io
import json
import math
import os
import re
import subprocess
import tempfile
import threading
import time
import zipfile
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parent
CERT_DIR = Path(os.environ.get("FINSY_CERT_DIR", "/etc/finsy-wallet"))
TEAM_ID = os.environ["FINSY_TEAM_ID"]
PORT = int(os.environ.get("FINSY_ISSUER_PORT", "8765"))
KINDS = {
    "/account": ("account", "pass.com.finsy.account"),
    "/purchase-receipt": ("receipt", "pass.com.finsy.receipt"),
    "/tax-receipt": ("tax", "pass.com.finsy.tax"),
}
SERIAL = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
RATE_LOCK = threading.Lock()
REQUEST_TIMES: dict[str, list[float]] = {}


def short(value: object, limit: int = 120) -> str:
    if not isinstance(value, str) or len(value) > limit:
        raise ValueError("Invalid text field")
    return value


def number(value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError("Invalid number field")
    return float(value)


def apple_date(value: object) -> str:
    # Foundation JSONEncoder encodes Date as seconds from 2001-01-01 by default.
    if isinstance(value, (int, float)):
        result = datetime(2001, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=number(value))
    elif isinstance(value, str):
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    else:
        raise ValueError("Invalid date")
    return result.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def field(key: str, label: str, value: object) -> dict:
    return {"key": key, "label": label, "value": value}


def allow_request(client: str) -> bool:
    now = time.monotonic()
    with RATE_LOCK:
        recent = [stamp for stamp in REQUEST_TIMES.get(client, []) if now - stamp < 60]
        if len(recent) >= 30:
            REQUEST_TIMES[client] = recent
            return False
        recent.append(now)
        REQUEST_TIMES[client] = recent
        if len(REQUEST_TIMES) > 1000:
            for key, stamps in list(REQUEST_TIMES.items()):
                if not stamps or now - stamps[-1] >= 60:
                    del REQUEST_TIMES[key]
        return True


def make_pass(kind: str, expected_id: str, payload: dict) -> dict:
    if payload.get("passTypeIdentifier") != expected_id:
        raise ValueError("Pass type does not match endpoint")
    serial = short(payload.get("serialNumber"), 100)
    if not SERIAL.fullmatch(serial):
        raise ValueError("Invalid serial number")

    body = {
        "formatVersion": 1,
        "passTypeIdentifier": expected_id,
        "serialNumber": serial,
        "teamIdentifier": TEAM_ID,
        "organizationName": "Finsy",
        "description": "Finsy financial record",
        "logoText": "Finsy",
        "backgroundColor": "rgb(32, 32, 32)",
        "foregroundColor": "rgb(255, 255, 255)",
        "labelColor": "rgb(205, 205, 205)",
    }

    if kind == "account":
        title = short(payload.get("title"))
        balance = short(payload.get("formattedBalance"))
        count = int(number(payload.get("accountCount")))
        body["description"] = "Finsy account balance"
        body["generic"] = {
            "primaryFields": [field("balance", title.upper()[:30], balance)],
            "secondaryFields": [field("accounts", "ACCOUNTS", str(count))],
        }
        locations = payload.get("locations", [])
        if not isinstance(locations, list) or len(locations) > 10:
            raise ValueError("Invalid locations")
        if locations:
            body["locations"] = [
                {
                    "latitude": number(item["latitude"]),
                    "longitude": number(item["longitude"]),
                    "relevantText": short(item.get("relevantText", "")),
                }
                for item in locations
            ]
    elif kind == "receipt":
        store = short(payload.get("storeName"))
        total = short(payload.get("formattedTotal"))
        tax = short(payload.get("formattedTax"))
        count = int(number(payload.get("itemCount")))
        date = apple_date(payload.get("finalizedAt"))
        items = payload.get("items", [])
        if not isinstance(items, list) or len(items) > 100:
            raise ValueError("Invalid items")
        back = []
        for index, item in enumerate(items):
            back.append(field(f"item-{index}", short(item.get("name"), 80), short(item.get("formattedAmount"), 40)))
        if not back:
            back.append(field("itemsSummary", "ITEMS", short(payload.get("itemsSummary", ""), 300)))
        body["description"] = "Finsy purchase receipt"
        body["generic"] = {
            "headerFields": [field("store", "STORE", store)],
            "primaryFields": [field("total", "TOTAL", total)],
            "secondaryFields": [field("tax", "TAX", tax), field("itemCount", "ITEMS", str(count))],
            "auxiliaryFields": [{**field("date", "DATE", date), "dateStyle": "PKDateStyleShort"}],
            "backFields": back,
        }
    else:
        month = short(payload.get("monthName"))
        tax = short(payload.get("formattedExpenseTax"))
        expense = short(payload.get("formattedTaxableExpense"))
        body["description"] = "Finsy monthly expense tax summary"
        body["generic"] = {
            "headerFields": [field("month", "MONTH", month)],
            "primaryFields": [field("tax", "EXPENSE TAX", tax)],
            "secondaryFields": [field("expense", "TAXABLE EXPENSE", expense)],
        }
    return body


def signed_pass(kind: str, body: dict) -> bytes:
    with tempfile.TemporaryDirectory(prefix="finsy-pass-") as temp:
        folder = Path(temp)
        files = {
            "pass.json": json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
            "icon.png": (ROOT / "assets" / "icon.png").read_bytes(),
            "icon@2x.png": (ROOT / "assets" / "icon@2x.png").read_bytes(),
        }
        manifest = {name: hashlib.sha1(contents).hexdigest() for name, contents in files.items()}
        files["manifest.json"] = json.dumps(manifest, separators=(",", ":")).encode("utf-8")
        (folder / "manifest.json").write_bytes(files["manifest.json"])
        signature = folder / "signature"
        subprocess.run(
            ["openssl", "cms", "-sign", "-binary", "-in", str(folder / "manifest.json"),
             "-signer", str(CERT_DIR / f"{kind}.crt.pem"),
             "-inkey", str(CERT_DIR / f"{kind}.key.pem"),
             "-certfile", str(CERT_DIR / "wwdr.pem"),
             "-outform", "DER", "-out", str(signature)],
            check=True, capture_output=True, timeout=15,
        )
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
            for name, contents in files.items():
                bundle.writestr(name, contents)
            bundle.writestr("signature", signature.read_bytes())
        return archive.getvalue()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/health":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")

    def do_POST(self) -> None:
        entry = KINDS.get(self.path)
        if entry is None:
            self.send_error(404)
            return
        if self.headers.get_content_type() != "application/json":
            self.send_error(415)
            return
        client = self.headers.get("X-Forwarded-For", self.client_address[0]).split(",", 1)[0].strip()
        if not allow_request(client):
            self.send_error(429, "Rate limit exceeded")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 65536:
                raise ValueError("Invalid body length")
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict):
                raise ValueError("Invalid JSON payload")
            kind, expected_id = entry
            data = signed_pass(kind, make_pass(kind, expected_id, payload))
        except (ValueError, KeyError, TypeError, OverflowError, json.JSONDecodeError):
            self.send_error(400, "Invalid pass request")
            return
        except (OSError, subprocess.SubprocessError):
            self.send_error(503, "Pass signing unavailable")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/vnd.apple.pkpass")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
