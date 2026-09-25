import test from 'node:test';
import assert from 'node:assert/strict';
import { auditNativeRows, cents } from '../scripts/audit-native-rows.mjs';

function fixture() {
  const identity = { sourceFingerprint: 'a'.repeat(64), source: 'Sample', accountKey: 'sample:1234', period: '2026-01' };
  const rows = [1, 2].map(page => ({ date: '2026-01-02', page, signedAmount: '10.00', titleContains: 'sample', kind: 'Ingreso' }));
  const reference = { schemaVersion: 1, referenceMethod: 'visual-independent', files: [{ ...identity, rows }] };
  const report = { schemaVersion: 1, readerVersion: 'test', files: [{ ...identity,
    candidateRows: rows.map(row => ({ ...row, title: 'sample deposit' })) }] };
  return { reference, report };
}
test('exact private rows match without claiming certification', () => {
  const { reference, report } = fixture();
  const result = auditNativeRows(reference, report, 'test');
  assert.equal(result.passed, true);
  assert.equal(result.corpusCertified, false);
});
test('compensating errors, missing duplicates and stale reader fail', () => {
  const { reference, report } = fixture();
  report.files[0].candidateRows[0].signedAmount = '9';
  report.files[0].candidateRows[1].signedAmount = '11';
  assert.equal(auditNativeRows(reference, report, 'test').passed, false);
  report.files[0].candidateRows.pop();
  assert.ok(auditNativeRows(reference, report, 'test').errors.includes('document-1:row-count'));
  assert.ok(auditNativeRows(reference, report, 'new').errors.includes('reader-version'));
});
test('classification mismatch fails even when row values match', () => {
  const { reference, report } = fixture();
  report.files[0].candidateRows[0].kind = 'Compra';
  const result = auditNativeRows(reference, report, 'test');
  assert.ok(result.errors.includes('document-1:row-1:kind'));
});
test('legacy exports, unknown documents and invalid controls fail closed', () => {
  const { reference, report } = fixture();
  reference.files[0].controls = { openingBalance: '0', closingBalance: '21', deposits: '20', withdrawals: '0', depositCount: 2, withdrawalCount: 0 };
  assert.ok(auditNativeRows(reference, report, 'test').errors.includes('document-1:reference-controls'));
  delete report.files[0].sourceFingerprint;
  assert.equal(auditNativeRows(reference, report, 'test').passed, false);
});
test('amount parser preserves cents and refuses rounding or coercion', () => {
  assert.equal(cents('-0.01'), -1n);
  assert.equal(cents('9007199254740993.01'), 900719925474099301n);
  for (const value of [1, null, '', '1.001', '1,000', '1e2']) assert.equal(cents(value), null);
});

test('description comparison ignores OCR punctuation while keeping the text anchor', () => {
  const { reference, report } = fixture();
  reference.files[0].rows[0].titleContains = 'sample*';
  report.files[0].candidateRows[0].title = 'sample deposit';
  assert.equal(auditNativeRows(reference, report, 'test').passed, true);
});
