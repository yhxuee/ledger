"""Inspect signed layouts returned by a deployed issuer using synthetic records."""
import io
import argparse
import json
import os
import urllib.request
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--preview-dir')
args = parser.parse_args()

base = os.environ.get('FINSY_ISSUER_URL', 'https://finsy.yhxue.com').rstrip('/')
samples = {
    'account': dict(passTypeIdentifier='pass.com.finsy.account', serialNumber='layout-check-account', title='Net Worth', formattedBalance='HK$12,480.00', accountCount=1, locations=[], monthTitle='SEP 2026', formattedExpenses='HK$128.50', formattedIncome='HK$200.00', entries=42, remainingLabel='TODAY', formattedRemaining='HK$128.50', recentEntries='09/26/2026\nTest entry\nHK$128.50', themeColorHex='3A78C2'),
    'purchase-receipt': dict(passTypeIdentifier='pass.com.finsy.receipt', serialNumber='layout-check-receipt', storeName='Layout Check', formattedTotal='HK$ 128.50', formattedTax='HK$ 0.00', itemCount=1, finalizedAt=812345678.0, formattedDate='09/26/2026', payment='VISA', invoiceNumber='P-000001', transactionStatus='Paid', items=[dict(name='Test item', category='Shopping', formattedAmount='HK$ 128.50')], themeColorHex='3A78C2')
}
for endpoint, payload in samples.items():
    request = urllib.request.Request(base + '/' + endpoint, data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json', 'Accept': 'application/vnd.apple.pkpass', 'User-Agent': 'Finsy/2.0 CFNetwork'})
    with urllib.request.urlopen(request, timeout=20) as response:
        with zipfile.ZipFile(io.BytesIO(response.read())) as bundle:
            body = json.loads(bundle.read('pass.json'))
            styles = {key: body[key] for key in ('storeCard', 'generic', 'coupon') if key in body}
            print(json.dumps({'endpoint': endpoint, 'layout': styles, 'logo': 'logo.png' in bundle.namelist()}, ensure_ascii=True))
            style = body['storeCard' if endpoint == 'account' else 'coupon']
            assert style['primaryFields'] == []
            assert 'logo.png' in bundle.namelist()
            assert style['backFields'][0]['key'] == ('balance' if endpoint == 'account' else 'total')
            if args.preview_dir:
                folder = Path(args.preview_dir)
                folder.mkdir(parents=True, exist_ok=True)
                (folder / f'{endpoint}.png').write_bytes(bundle.read('strip@2x.png'))
