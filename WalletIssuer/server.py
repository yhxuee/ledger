"""Issue signed, static Finsy Wallet passes on a loopback-only HTTP service."""

from __future__ import annotations

import hashlib
import io
import json
import math
import os
import re
import struct
import zlib
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
        "backgroundColor": "rgb(250, 250, 250)",
        "foregroundColor": "rgb(20, 20, 20)",
        "labelColor": "rgb(65, 65, 65)",
        "suppressStripShine": True,
    }

    if kind == "account":
        title = short(payload.get("title"))
        balance = short(payload.get("formattedBalance"))
        count = int(number(payload.get("accountCount")))
        body["description"] = "Finsy account balance"
        body["storeCard"] = {
            "headerFields": [field("month", "MONTH", short(payload.get("monthTitle") or datetime.now().strftime("%b %Y").upper()))],
            "primaryFields": [],
            "secondaryFields": [field("expenses", "EXPENSES", short(payload.get("formattedExpenses") or "—")), field("income", "INCOME", short(payload.get("formattedIncome") or "—"))],
            "auxiliaryFields": [field("entries", "ENTRIES", f'{int(number(payload.get("entries") or 0))} recs'), field("remaining", short(payload.get("remainingLabel") or "TODAY"), short(payload.get("formattedRemaining") or "—"))],
            "backFields": [field("balance", "NET WORTH", balance), field("source", "ACCOUNT", title), field("recent", "RECENT ENTRIES", short(payload.get("recentEntries") or "No entries", 4000))],
        }
        body["_artwork"] = ("NET WORTH", balance)
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
        date = short(payload.get("formattedDate") or apple_date(payload.get("finalizedAt")))
        items = payload.get("items", [])
        if not isinstance(items, list) or len(items) > 100:
            raise ValueError("Invalid items")
        back = [field("total", "TOTAL", total), field("store", "STORE", store), field("tax", "TAX", tax)]
        for index, item in enumerate(items):
            back.append(field(f"item-{index}", f'{index + 1:02d} · {short(item.get("name"), 80)}', f'{short(item.get("category", ""), 80)}\n{short(item.get("formattedAmount"), 40)}'))
        if not back:
            back.append(field("itemsSummary", "ITEMS", short(payload.get("itemsSummary", ""), 300)))
        body["description"] = "Finsy purchase receipt"
        body["coupon"] = {
            "headerFields": [field("date", "DATE", date)],
            "primaryFields": [],
            "secondaryFields": [field("itemCount", "ITEMS", str(count)), field("payment", "PAYMENT", short(payload.get("payment") or "Unavailable"))],
            "auxiliaryFields": [field("invoice", "INVOICE", short(payload.get("invoiceNumber") or serial)), field("status", "STATUS", short(payload.get("transactionStatus") or "Paid"))],
            "backFields": back,
        }
        body["_artwork"] = ("TOTAL", total)
        barcode = payload.get("barcode")
        if barcode is not None:
            message = short(barcode.get("message"), 1024)
            format_name = barcode.get("format")
            if not message or format_name not in ("PKBarcodeFormatQR", "PKBarcodeFormatCode128"):
                raise ValueError("Invalid barcode")
            if format_name == "PKBarcodeFormatCode128" and not all(32 <= ord(char) <= 126 for char in message):
                raise ValueError("Code 128 requires printable ASCII")
            body["barcodes"] = [{"message": message, "format": format_name, "messageEncoding": "utf-8"}]
    else:
        raise ValueError("Unsupported pass kind")
    theme = short(payload.get("themeColorHex") or "3A78C2", 6)
    if not re.fullmatch(r"[0-9A-Fa-f]{6}", theme):
        raise ValueError("Invalid theme color")
    # Used by the artwork generator only; never emitted in pass.json.
    body["_theme"] = theme
    return body


def signed_pass(kind: str, body: dict) -> bytes:
    theme = body.pop("_theme", "3A78C2")
    title, amount = body.pop("_artwork")
    with tempfile.TemporaryDirectory(prefix="finsy-pass-") as temp:
        folder = Path(temp)
        files = {
            "pass.json": json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
            "icon.png": (ROOT / "assets" / "icon.png").read_bytes(),
            "icon@2x.png": (ROOT / "assets" / "icon@2x.png").read_bytes(),
        }
        for scale in (1, 2, 3):
            suffix = "" if scale == 1 else f"@{scale}x"
            files[f"logo{suffix}.png"] = (ROOT / "assets" / f"logo{suffix}.png").read_bytes()
            files[f"strip{suffix}.png"] = ticket_strip(theme, scale, title, amount, serrated=kind == "receipt")
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


def ticket_strip(theme: str, scale: int, title: str = "", amount: str = "", serrated: bool = True) -> bytes:
    """Theme paper with an upper label and one bold currency-and-amount line."""
    rgb = tuple(int(theme[index:index + 2], 16) for index in (0, 2, 4))
    paper = tuple(round(255 * .9 + channel * .1) for channel in rgb)
    width, height = 375 * scale, 144 * scale
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            phase = (x % (15 * scale)) / (15 * scale)
            edge = int(abs(phase - .5) * 2 * 7 * scale) if serrated else 0
            if y < edge or y >= height - edge:
                pixel = (*paper, 0)
            elif y < edge + 2 * scale or y >= height - edge - 2 * scale:
                pixel = (*rgb, 255)
            else:
                delta = 2 if (x + y * 3) % (11 * scale) == 0 else 0
                pixel = (*(max(0, channel - delta) for channel in paper), 255)
            row.extend(pixel)
        rows.append(bytes(row))
    def chunk(name: bytes, value: bytes) -> bytes:
        return struct.pack(">I", len(value)) + name + value + struct.pack(">I", zlib.crc32(name + value))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")
    if not title:
        return png
    from PIL import Image, ImageDraw, ImageFont
    image = Image.open(io.BytesIO(png)).convert("RGBA")
    # Fine contour lines stay in opposing corners, away from the amount.
    # Preserve the ticket's transparent teeth when clipping the decoration.
    alpha = image.getchannel("A")
    texture = tuple(round(base * .82 + color * .18) for base, color in zip(paper, rgb))
    draw = ImageDraw.Draw(image)
    for radius in (34, 45, 56, 67, 78):
        for cx, cy in ((365, 8), (8, 143)):
            draw.ellipse(tuple(round(value * scale) for value in
                (cx - radius, cy - radius, cx + radius, cy + radius)),
                outline=(*texture, 255), width=scale)
    # A quiet perforation detail along the lower edge suggests receipt paper.
    for x in range(104, 272, 7):
        draw.line((x * scale, 123 * scale, (x + 2) * scale, 123 * scale),
            fill=(*texture, 255), width=scale)
    image.putalpha(alpha)
    font_path = os.environ.get("FINSY_WALLET_BOLD_FONT", "/opt/finsy-wallet/fonts/SF-Pro-Display-Bold.otf")
    label_font = ImageFont.truetype(os.environ.get("FINSY_WALLET_LABEL_FONT", "/opt/finsy-wallet/fonts/SF-Pro-Text-Semibold.otf"), 13 * scale)
    amount_size = 36 * scale
    amount_font = ImageFont.truetype(font_path, amount_size)
    available_width = width - 40 * scale
    while draw.textbbox((0, 0), amount, font=amount_font)[2] > available_width and amount_size > 8 * scale:
        amount_size -= scale
        amount_font = ImageFont.truetype(font_path, amount_size)
    # Separate label and amount baselines, independent of Wallet's native primary layout.
    draw.text((20 * scale, 26 * scale), title, font=label_font, fill=(45, 45, 45), anchor="lt")
    draw.text((width / 2, 62 * scale), amount, font=amount_font, fill=(15, 15, 15), anchor="mt")
    output = io.BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


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
