import test from 'node:test';
import assert from 'node:assert/strict';
import { nativeEvidence, validateBank } from '../scripts/validate-private-formats.mjs';

function fixture() {
  const identity = { sourceFingerprint: 'a'.repeat(64), source: 'Santander', accountKey: 'santander:1234', period: '2026-01' };
  const summary = { previousBalance: 100, cashBalance: 90, extractedDepositTotal: 0, extractedWithdrawalTotal: 10 };
  const file = { ...identity, file: 'sample.pdf', kind: 'bank', status: 'valid', rows: 1, summary };
  return {
    readerVersion: 'test-reader',
    manifest: { schemaVersion: 1, readerVersion: 'test-reader', tolerance: 0, files: [file] },
    inventory: [{ file: 'sample.pdf', sourceFingerprint: identity.sourceFingerprint, pdf: true }],
    native: { summary: { readerVersion: 'test-reader', files: 1, accepted: 1, expectedValid: 1, goldenAutoAccepted: 1,
      blocked: 0, expectedPending: 0, goldenFalseAccepted: 0, unresolvedOCR: 0, automaticAcceptancePrecision: 1, certified: false },
      files: [{ ...identity, kind: 'bank', status: 'valid', sourceStatus: 'verified', requiresReview: 'false', mode: 'vision-ocr',
        ocrColumnsCalibrated: 'true', rows: '1', extractedPreviousBalance: '100', extractedCashBalance: '90', extractedDeposits: '0', extractedWithdrawals: '10' }] },
    rows: { schemaVersion: 1, readerVersion: 'test-reader', files: [{ ...identity, status: 'valid', mode: 'vision-ocr',
      rows: [{ accepted: true, rawText: 'sample' }], candidateRows: [{ date: '2026-01-02', page: 1, title: 'sample store', signedAmount: '-10' }] }] },
    reference: { schemaVersion: 1, referenceMethod: 'visual-independent', files: [{ ...identity,
      rows: [{ date: '2026-01-02', page: 1, titleContains: 'sample', signedAmount: '-10' }] }] },
  };
}

test('exact scope passes without pretending it certifies the full app', () => {
  assert.equal(validateBank(fixture()).passed, true);
});
test('originals and expected totals alone cannot pass', () => {
  const f = fixture(); delete f.native; delete f.rows;
  const r = validateBank(f);
  assert.equal(r.passed, false);
  assert.ok(r.documents[0].errors.includes('native-evidence-missing'));
});
test('one cent mismatch fails with exact integer comparison', () => {
  const f = fixture(); f.native.files[0].extractedWithdrawals = '10.01';
  assert.ok(validateBank(f).documents[0].errors.includes('control:extractedWithdrawalTotal'));
});
test('malformed decimals are not rounded into acceptance', () => {
  for (const amount of [null, '', '10.001', '1e1', true]) {
    const f = fixture(); f.native.files[0].extractedWithdrawals = amount;
    assert.equal(validateBank(f).passed, false);
  }
});
test('altered originals, duplicated originals and unrelated documents fail', () => {
  const f = fixture(); f.inventory[0].sourceFingerprint = 'b'.repeat(64);
  assert.equal(validateBank(f).passed, false);
  f.inventory.push(f.inventory[0]);
  assert.ok(validateBank(f).errors.includes('unexpected-originals'));
});
test('missing independent reference remains blocked', () => {
  const f = fixture(); f.reference.files = [];
  assert.ok(validateBank(f).documents[0].errors.includes('independent-reference-missing'));
});
test('row errors cannot be hidden by a valid statement status', () => {
  const f = fixture(); f.rows.files[0].rows[0].accepted = false;
  assert.equal(validateBank(f).passed, false);
});
test('compensating row errors cannot pass equal totals', () => {
  const f = fixture(); f.manifest.files[0].rows = 2; f.native.files[0].rows = '2';
  f.reference.files[0].rows = [1, 2].map(page => ({ date: '2026-01-02', page, titleContains: 'sample', signedAmount: '-5' }));
  f.rows.files[0].rows.push({ accepted: true, rawText: 'sample' });
  f.rows.files[0].candidateRows = [1, 2].map(page => ({ date: '2026-01-02', page, title: 'sample', signedAmount: page === 1 ? '-4' : '-6' }));
  const r = validateBank(f);
  assert.equal(r.passed, false);
  assert.ok(r.documents[0].errors.some(x => x.endsWith('signedAmount')));
  assert.ok(!r.documents[0].errors.includes('bank-row-totals'));
});
test('stale native logs or row exports cannot pass', () => {
  for (const key of ['native', 'rows']) {
    const f = fixture(); (key === 'native' ? f.native.summary : f.rows).readerVersion = 'old';
    assert.equal(validateBank(f).passed, false);
  }
});
test('native summary counters and document coverage must agree', () => {
  const f = fixture(); f.native.summary.accepted = 0;
  assert.equal(validateBank(f).passed, false);
  f.native.files.push(f.native.files[0]);
  assert.ok(validateBank(f).errors.includes('unexpected-native-documents'));
});
test('row export must not contain unrelated documents', () => {
  const f = fixture(); f.rows.files.push({ sourceFingerprint: 'b'.repeat(64) });
  assert.equal(validateBank(f).passed, false);
});
test('Amex OCR and missing controls are blocked', () => {
  const f = fixture(); f.manifest.files[0].source = 'Amex'; f.native.files[0].source = 'Amex';
  const r = validateBank(f);
  assert.ok(r.documents[0].errors.includes('native-wrong-pipeline'));
  assert.ok(r.documents[0].errors.includes('missing-control:extractedChargeTotal'));
});
test('Amex text evidence checks debt and payment controls as well as charges', () => {
  const f = fixture();
  for (const file of [f.manifest.files[0], f.native.files[0], f.rows.files[0], f.reference.files[0]]) {
    file.source = 'Amex'; file.accountKey = 'amex:1234'; file.kind = 'card'; file.mode = 'pdf-text';
  }
  f.manifest.files[0].summary = { extractedChargeTotal: 10, extractedPaymentTotal: 0,
    creditLimit: 100, creditAvailable: 90, debtBalance: 10, paymentForNoInterest: 10, minimumPlusMsi: 5, msiPending: 0 };
  Object.assign(f.native.files[0], { extractedCharges: '10', extractedPayments: '0', extractedCreditLimit: '100',
    extractedCreditAvailable: '90', extractedDebtBalance: '10', extractedPaymentForNoInterest: '10', extractedMinimumPlusMsi: '5', extractedMsiPending: '0' });
  assert.equal(validateBank(f).passed, true);
  f.native.files[0].extractedPaymentForNoInterest = '10.01';
  assert.equal(validateBank(f).passed, false);
});
test('reference opening plus movements must equal closing', () => {
  const f = fixture(); f.manifest.files[0].summary.cashBalance = 91;
  assert.ok(validateBank(f).documents[0].errors.includes('reference-balance-equation'));
});
test('native log needs exactly one result and summary, not cherry-picked runs', () => {
  const log = 'NATIVE_CORPUS_REPORT []\nNATIVE_CORPUS_SUMMARY {}\n';
  assert.deepEqual(nativeEvidence(log), { files: [], summary: {} });
  assert.throws(() => nativeEvidence(log + log));
  assert.throws(() => nativeEvidence('** TEST SUCCEEDED **'));
});
