"""Validate pass fields and generated artwork without network or signing keys."""
import io
import os
import unittest
os.environ.setdefault('FINSY_TEAM_ID', 'TESTTEAM')
import server
from PIL import Image

class LayoutTests(unittest.TestCase):
    def receipt(self, **extra):
        payload = dict(passTypeIdentifier='pass.com.finsy.receipt', serialNumber='purchase-test',
            storeName='Shop', formattedTotal='HK$ 128.50', formattedTax='HK$ 0.00', itemCount=2,
            finalizedAt=812345678.0, formattedDate='26/09/2026', payment='VISA',
            invoiceNumber='P-000001', transactionStatus='Partially Refunded',
            items=[dict(name='Tea', category='Food', formattedAmount='HK$ 128.50')], themeColorHex='CC3355')
        payload.update(extra)
        return server.make_pass('receipt', 'pass.com.finsy.receipt', payload)

    def test_receipt_fields(self):
        body = self.receipt(barcode=dict(message='12345', format='PKBarcodeFormatCode128'))
        coupon = body['coupon']
        self.assertEqual(coupon['headerFields'][0]['value'], '26/09/2026')
        self.assertEqual(coupon['primaryFields'], [])
        self.assertEqual(body['_artwork'], ('TOTAL', 'HK$ 128.50'))
        self.assertEqual(coupon['backFields'][0]['value'], 'HK$ 128.50')
        self.assertEqual([f['value'] for f in coupon['secondaryFields']], ['2', 'VISA'])
        self.assertEqual([f['value'] for f in coupon['auxiliaryFields']], ['P-000001', 'Partially Refunded'])
        self.assertEqual(body['barcodes'][0]['format'], 'PKBarcodeFormatCode128')
        self.assertNotIn('barcodes', self.receipt())

    def test_account_store_card(self):
        body = server.make_pass('account', 'pass.com.finsy.account', dict(
            passTypeIdentifier='pass.com.finsy.account', serialNumber='finsy-primary-account-pass',
            title='Net Worth', formattedBalance='HK$12,480.00', accountCount=2,
            monthTitle='SEP 2026', formattedExpenses='HK$128.50', formattedIncome='HK$200.00',
            entries=42, remainingLabel='BUDGET LEFT', formattedRemaining='HK$1,180.00', recentEntries='26/09/2026\nTea\nHK$128.50'))
        card = body['storeCard']
        self.assertEqual(card['headerFields'][0]['value'], 'SEP 2026')
        self.assertEqual(card['auxiliaryFields'][0]['value'], '42 recs')
        self.assertEqual(len(card['secondaryFields']) + len(card['auxiliaryFields']), 4)
        self.assertNotIn('generic', body)
        self.assertEqual(card['primaryFields'], [])
        self.assertEqual(body['_artwork'], ('NET WORTH', 'HK$12,480.00'))
        self.assertEqual(card['backFields'][0]['value'], 'HK$12,480.00')

    def test_validation(self):
        self.assertNotIn('/tax-receipt', server.KINDS)
        for barcode in [dict(message='中文', format='PKBarcodeFormatCode128'), dict(message='abc', format='bad')]:
            with self.assertRaises(ValueError): self.receipt(barcode=barcode)
        with self.assertRaises(ValueError): self.receipt(themeColorHex='oops')

    def test_theme_artwork(self):
        for scale in (1, 2, 3):
            im = Image.open(io.BytesIO(server.ticket_strip('CC3355', scale)))
            self.assertEqual(im.size, (375 * scale, 144 * scale))
            self.assertEqual(im.getpixel((0, 0))[3], 0)
            self.assertEqual(im.getpixel((100 * scale, 70 * scale))[3], 255)

if __name__ == '__main__': unittest.main()
